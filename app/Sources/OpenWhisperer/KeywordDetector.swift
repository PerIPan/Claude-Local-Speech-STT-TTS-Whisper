import Foundation
import Speech
import AVFoundation

private let kwFormatter = ISO8601DateFormatter()

private func kwLog(_ msg: String) {
    let ts = kwFormatter.string(from: Date())
    let line = "[\(ts)] [Keyword] \(msg)\n"
    let path = NSHomeDirectory() + "/Library/Application Support/OpenWhisperer/paste_debug.log"
    guard let data = line.data(using: .utf8) else { return }
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile()
        fh.write(data)
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: data)
    }
}

/// Lightweight on-device keyword detection using Apple SFSpeechRecognizer.
/// Used in hands-free mode to detect "initiate" (start recording) and "hold on" (barge-in).
class KeywordDetector: ObservableObject {
    enum DetectedKeyword {
        case initiate
        case holdOn
    }

    @Published var isRunning = false
    @Published var permissionGranted = false
    /// If start() is called before permission arrives, retry when permission is granted.
    private var pendingStart = false

    /// Called on main thread when a keyword is detected.
    var onKeywordDetected: ((DetectedKeyword) -> Void)?

    /// Configurable trigger word for starting recording (default: "initiate")
    var triggerWord: String = "initiate"

    /// Barge-in keyword (always "hold on")
    private let bargeInKeyword = "hold on"

    private var recognizer: SFSpeechRecognizer?
    /// Protects `recognitionRequest` which is written on main thread and read on
    /// CoreAudio tap thread via `appendAudioBuffer` (C-2 / H-6).
    private let requestLock = NSLock()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var lastProcessedText = ""
    /// Proactive session recycling timer (Apple ~60s limit) (#10)
    private var recycleTimer: Timer?

    init() {
        // Always use en-US — trigger words ("initiate", "hold on") are English
        // regardless of the user's Whisper STT language setting
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        checkPermission()
    }

    // MARK: - Permission

    func checkPermission() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                self.permissionGranted = status == .authorized
                kwLog("Permission status: \(status.rawValue) (authorized=\(status == .authorized))")
                if status == .authorized && self.pendingStart {
                    kwLog("Permission arrived — executing deferred start()")
                    self.pendingStart = false
                    self.start()
                }
            }
        }
    }

    // MARK: - Start/Stop

    /// Start listening for keywords. Feed audio buffers via `appendAudioBuffer(_:)`.
    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard permissionGranted else {
            kwLog("start() deferred — waiting for permission callback")
            pendingStart = true
            return
        }
        guard !isRunning else {
            kwLog("start() skipped — already running")
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            kwLog("start() BLOCKED — recognizer unavailable")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Don't require on-device — falls back to server if model not downloaded.
        // This fixes "initiate" not working when on-device models are unavailable.
        request.requiresOnDeviceRecognition = false
        if #available(macOS 15.0, *) {
            request.addsPunctuation = false
        }

        // Protect write: appendAudioBuffer reads recognitionRequest on CoreAudio thread (C-2 / H-6)
        requestLock.lock()
        recognitionRequest = request
        requestLock.unlock()
        lastProcessedText = ""

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            // SFSpeech callback runs on arbitrary thread — dispatch all state access to main (C-4)
            DispatchQueue.main.async {
                guard self.isRunning else { return }  // Guard against firing after stop() (Mi-6)

                if let result {
                    let text = result.bestTranscription.formattedString.lowercased()
                    kwLog("Heard: \"\(text)\"")
                    // Strip punctuation before matching (#11-minor)
                    let cleaned = text.components(separatedBy: .punctuationCharacters).joined()
                    // Always check full text — incremental dropFirst can split keywords
                    // across partial results (e.g. "in" + "itiate" never matches "initiate")
                    if cleaned != self.lastProcessedText {
                        self.lastProcessedText = cleaned
                        self.checkForKeywords(in: cleaned)
                    }
                }

                if let error {
                    let nsError = error as NSError
                    kwLog("Error: \(nsError.domain) code=\(nsError.code) \(error.localizedDescription)")
                    // Ignore cancellation errors (normal during stop/restart)
                    if nsError.domain != "kAFAssistantErrorDomain" || nsError.code != 216 {
                        kwLog("Recognition error: \(error.localizedDescription)")
                    }
                    if self.isRunning {
                        self.restart()
                    }
                }
            }
        }

        isRunning = true
        kwLog("Started listening (triggerWord=\(triggerWord))")

        // Proactive session recycling every 45s to avoid Apple's ~60s limit (#10)
        // Use .common RunLoop mode so timer fires even when menubar popover is open (L-6)
        recycleTimer?.invalidate()
        let timer = Timer(timeInterval: 45, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.isRunning else { return }
                kwLog("Proactive session recycle (45s)")
                self.restart()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        recycleTimer = timer
    }

    /// Stop keyword detection.
    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        recycleTimer?.invalidate()
        recycleTimer = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        // Protect write: appendAudioBuffer reads recognitionRequest on CoreAudio thread (C-2 / H-6)
        requestLock.lock()
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        requestLock.unlock()
        isRunning = false
        lastProcessedText = ""
        kwLog("Stopped")
    }

    /// Restart recognition (e.g. after timeout or error).
    private func restart() {
        stop()
        // Brief delay before restarting to avoid rapid cycling
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.start()
        }
    }

    // MARK: - Audio Feed

    /// Feed an audio buffer from the shared AVAudioEngine tap.
    /// Call from any thread — guards recognitionRequest read under requestLock (C-2 / H-6).
    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        requestLock.lock()
        let request = recognitionRequest
        requestLock.unlock()
        request?.append(buffer)
    }

    // MARK: - Keyword Matching

    private func checkForKeywords(in text: String) {
        // text is already lowercased from the caller
        // Word boundary matching to avoid false positives on "initiating", "reinitiate" (#9)
        if matchesWholeWord(text, keyword: triggerWord.lowercased()) {
            kwLog("Detected trigger: '\(triggerWord)'")
            onKeywordDetected?(.initiate)
            // Don't restart here — DictationManager controls lifecycle after trigger (#5)
        } else if matchesWholeWord(text, keyword: bargeInKeyword) {
            kwLog("Detected barge-in: 'hold on'")
            onKeywordDetected?(.holdOn)
            restart()
        }
    }

    /// Check if text contains keyword as a whole word (not substring of larger word) (#9)
    private func matchesWholeWord(_ text: String, keyword: String) -> Bool {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: keyword))\\b"
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}
