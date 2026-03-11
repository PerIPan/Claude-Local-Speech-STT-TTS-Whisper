import Foundation
import AppKit
import Combine
import os.log

private let dictLog = OSLog(subsystem: "com.openwhisperer.app", category: "dictation")

/// Orchestrates the record → upload → type cycle for all interaction modes.
/// Sends audio to the local Whisper server and types the result into the focused app.
class DictationManager: ObservableObject {
    let recorder = AudioRecorder()
    let keywordDetector = KeywordDetector()

    @Published var lastTranscription: String = ""
    @Published var error: String?
    /// Mirrors recorder.state as a direct @Published so SwiftUI views reliably update.
    @Published var recorderState: AudioRecorder.State = .idle
    /// Current interaction mode
    @Published var interactionMode: InteractionMode = .pressToTalk {
        didSet {
            if interactionMode != oldValue {
                handleModeChange(from: oldValue, to: interactionMode)
                TranscriptionOverlay.shared.interactionMode = interactionMode
            }
        }
    }
    /// Whether TTS is currently playing (tracked via lock file)
    @Published var ttsPlaying = false
    /// Whether hands-free is calibrating ambient noise
    @Published var isCalibrating = false

    private var port: Int = 8000
    private var isTyping = false  // prevent concurrent typeText

    /// The PID of the app that was frontmost when the user pressed the hotkey.
    /// Captured on the main thread at press-time, before any focus shifts.
    private var targetPID: pid_t = 0
    /// The PID of the app the user was in before auto-focus switched away.
    /// Used by "with return" to re-activate the origin app after text insertion.
    private var originPID: pid_t = 0

    private var recorderSink: AnyCancellable?
    private var uploadWatchdog: DispatchWorkItem?
    private var activeUploadTask: URLSessionDataTask?
    /// Monitors the TTS lock file for barge-in / mic muting
    private var ttsLockMonitor: DispatchSourceFileSystemObject?
    private var ttsLockTimer: Timer?

    init() {
        recorderSink = recorder.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] newState in
                self?.recorderState = newState
            }

        // Wire keyword detector
        keywordDetector.onKeywordDetected = { [weak self] keyword in
            guard let self else { return }
            switch keyword {
            case .initiate:
                self.handleInitiateKeyword()
            case .holdOn:
                self.handleBargeIn()
            }
        }

        // Wire audio buffer feed from recorder to keyword detector
        recorder.onRawAudioBuffer = { [weak self] buffer in
            self?.keywordDetector.appendAudioBuffer(buffer)
        }

        // Wire silence detection callback
        recorder.onSilenceTimeout = { [weak self] in
            self?.handleSilenceTimeout()
        }

        // Load silence threshold from preferences
        if let saved = try? String(contentsOf: Paths.silenceThreshold, encoding: .utf8),
           let seconds = TimeInterval(saved.trimmingCharacters(in: .whitespacesAndNewlines)) {
            recorder.silenceThresholdSeconds = seconds
        }
    }

    func updatePort(_ port: Int) {
        self.port = port
    }

    // MARK: - Capture Target App (call on main thread at hotkey PRESS, not release)

    /// Called when the user presses the hotkey. Captures the PID of the current
    /// frontmost app before any UI appears that could steal focus.
    /// Must be called on the main thread.
    func captureTargetApp() {
        dispatchPrecondition(condition: .onQueue(.main))
        // Skip our own app — if we somehow are frontmost, keep the previous target
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            targetPID = front.processIdentifier
            os_log(.default, log: dictLog, "Captured target PID %d (%{public}@)", targetPID, front.localizedName ?? "?")
        }
    }

    // MARK: - Mode Change Handling

    private func handleModeChange(from oldMode: InteractionMode, to newMode: InteractionMode) {
        dispatchPrecondition(condition: .onQueue(.main))
        os_log(.default, log: dictLog, "Mode changed: %{public}@ → %{public}@", oldMode.rawValue, newMode.rawValue)

        // Tear down old mode
        switch oldMode {
        case .handsFree:
            deactivateHandsFree()
        case .pressToTalk, .holdToTalk:
            break
        }

        // Set up new mode
        switch newMode {
        case .handsFree:
            activateHandsFree()
        case .pressToTalk, .holdToTalk:
            // Ensure recorder is idle if switching away from hands-free
            if recorder.state == .listening || recorder.state == .recording || recorder.state == .uploading {
                uploadWatchdog?.cancel()
                uploadWatchdog = nil
                recorder.stopEngine()
            }
        }
    }

    // MARK: - Press-to-Talk (existing toggle behavior)

    func toggle() {
        dispatchPrecondition(condition: .onQueue(.main))

        if interactionMode == .handsFree {
            // In hands-free: PTT tap = instant submit if recording
            if recorder.state == .recording {
                playClick()
                handsFreeFlushAndTranscribe()
            }
            return
        }

        switch recorder.state {
        case .idle:
            guard !isTyping else { return }
            killTTS()
            playClick()
            // captureTargetApp() already called by HotkeyManager.onKeyDown (L-4)
            recorder.startRecording()
        case .recording:
            playClick()
            finishAndTranscribe()
        case .uploading, .listening:
            break
        }
    }

    // MARK: - Hold-to-Talk

    /// Called on hotkey press-down for hold-to-talk mode.
    func holdToTalkDown() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard interactionMode == .holdToTalk else { return }
        guard recorder.state == .idle, !isTyping else { return }
        killTTS()
        playClick()
        captureTargetApp()
        recorder.startRecording()
    }

    /// Called on hotkey release for hold-to-talk mode.
    func holdToTalkUp() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard interactionMode == .holdToTalk else { return }
        guard recorder.state == .recording else { return }
        playClick()
        finishAndTranscribe()
    }

    // MARK: - Hands-Free Mode

    private func activateHandsFree() {
        dispatchPrecondition(condition: .onQueue(.main))
        isCalibrating = true
        recorder.silenceDetectionEnabled = true

        // Start mic for calibration
        recorder.startListening()

        // Calibrate ambient noise
        recorder.calibrateAmbient { [weak self] in
            guard let self else { return }
            self.isCalibrating = false
            // Start keyword detection
            self.keywordDetector.start()
            // Start TTS lock monitoring
            self.startTTSLockMonitoring()
            os_log(.default, log: dictLog, "Hands-free activated, ambient: %.4f", self.recorder.ambientNoiseFloor)
        }
    }

    private func deactivateHandsFree() {
        dispatchPrecondition(condition: .onQueue(.main))
        uploadWatchdog?.cancel()
        uploadWatchdog = nil
        recorder.silenceDetectionEnabled = false
        keywordDetector.stop()
        stopTTSLockMonitoring()
        if recorder.state == .listening || recorder.state == .recording || recorder.state == .uploading {
            recorder.stopEngine()
        }
        isCalibrating = false
        os_log(.default, log: dictLog, "Hands-free deactivated")
    }

    /// "Initiate" keyword detected — transition from listening to recording.
    private func handleInitiateKeyword() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard interactionMode == .handsFree else { return }
        guard recorder.state == .listening else { return }
        os_log(.default, log: dictLog, "Keyword 'initiate' detected, starting STT recording")
        // Stop keyword detector — it no longer auto-restarts on initiate (#5).
        // It will be restarted after the STT cycle completes (resumeListening path).
        keywordDetector.stop()
        playClick()
        captureTargetApp()
        recorder.startBuffering()
    }

    /// 3s silence detected — flush buffer and transcribe.
    private func handleSilenceTimeout() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard interactionMode == .handsFree else { return }
        guard recorder.state == .recording else { return }
        os_log(.default, log: dictLog, "Silence timeout, flushing for transcription")
        playClick()
        handsFreeFlushAndTranscribe()
    }

    /// Flush current audio buffer and transcribe (hands-free — engine stays running).
    private func handsFreeFlushAndTranscribe() {
        let language = readLanguage()
        let currentPort = port
        let pid = targetPID

        guard let wavData = recorder.flushAndContinue() else {
            recorder.resumeListening()
            keywordDetector.start()
            return
        }

        // Skip very short recordings
        if wavData.count < 9700 {
            recorder.resumeListening()
            keywordDetector.start()
            return
        }

        os_log(.default, log: dictLog, "Hands-free WAV: %d bytes", wavData.count)

        uploadWatchdog?.cancel()
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, self.recorder.state == .uploading else { return }
            os_log(.default, log: dictLog, "Watchdog: hands-free upload exceeded 35s")
            self.activeUploadTask?.cancel()
            self.activeUploadTask = nil
            self.isTyping = false
            self.recorder.resumeListening()
            self.keywordDetector.start()
            self.error = "Transcription timed out"
        }
        uploadWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 35, execute: watchdog)

        activeUploadTask = uploadToWhisper(wavData: wavData, language: language, port: currentPort, handsFree: true) { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                self.uploadWatchdog?.cancel()
                self.uploadWatchdog = nil

                switch result {
                case .success(let text):
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        os_log(.default, log: dictLog, "HF transcribed: %{public}@", trimmed)
                        self.lastTranscription = trimmed
                        self.error = nil
                        self.isTyping = true
                        self.insertText(trimmed, intoPID: pid, forceSubmit: true) { [weak self] in
                            guard let self else { return }
                            self.isTyping = false
                            // Resume listening after typing completes
                            self.recorder.resumeListening()
                            self.keywordDetector.start()
                        }
                        return
                    }
                case .failure(let err):
                    os_log(.default, log: dictLog, "HF upload failed: %{public}@", err.localizedDescription)
                    self.error = err.localizedDescription
                }

                // Resume listening on empty result or failure
                self.recorder.resumeListening()
                self.keywordDetector.start()
            }
        }
    }

    // MARK: - Barge-in

    /// "Hold on" detected during TTS — kill TTS and start recording.
    private func handleBargeIn() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard interactionMode == .handsFree, ttsPlaying else { return }
        // Only barge-in when recorder is in a state that can transition to recording (L-1)
        guard recorder.state == .listening || recorder.state == .idle else { return }
        os_log(.default, log: dictLog, "Barge-in: 'hold on' detected, killing TTS")
        // Stop keyword detector before recording — matches handleInitiateKeyword pattern
        keywordDetector.stop()
        killTTS()
        playClick()
        captureTargetApp()
        recorder.startBuffering()
    }

    // MARK: - TTS Lock File Monitoring

    private func startTTSLockMonitoring() {
        // Poll for lock file every 0.5s (simpler and more reliable than DispatchSource)
        // Use .common RunLoop mode so timer fires even when menubar popover is open (L-6)
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let lockPath = Paths.appSupport.appendingPathComponent("tts_playing.lock").path
            let playing = FileManager.default.fileExists(atPath: lockPath)
            if playing != self.ttsPlaying {
                self.ttsPlaying = playing
                self.handleTTSStateChange(playing: playing)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ttsLockTimer = timer
    }

    private func stopTTSLockMonitoring() {
        ttsLockTimer?.invalidate()
        ttsLockTimer = nil
        ttsPlaying = false
    }

    private func handleTTSStateChange(playing: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard interactionMode == .handsFree else { return }

        if playing {
            // TTS started — stop STT buffering, keep keyword detection for barge-in
            os_log(.default, log: dictLog, "TTS started — muting STT, listening for barge-in")
            if recorder.state == .recording {
                // Discard any buffered audio during TTS transition
                recorder.resumeListening()
            }
            // Ensure keyword detector is running for "hold on" barge-in (L-2)
            if !keywordDetector.isRunning {
                keywordDetector.start()
            }
        } else {
            // TTS finished — resume listening for "initiate"
            os_log(.default, log: dictLog, "TTS ended — resuming keyword listening")
            if recorder.state != .uploading {
                recorder.resumeListening()
                keywordDetector.start()
            }
        }
    }

    // MARK: - Press-to-Talk Finish Recording & Transcribe

    private func finishAndTranscribe() {
        recorder.stopRecording()

        let language = readLanguage()
        let currentPort = port
        let pid = targetPID  // capture on main thread right now

        // Cancel any previous watchdog before creating a new one (C-5)
        uploadWatchdog?.cancel()
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, self.recorder.state == .uploading else { return }
            os_log(.default, log: dictLog, "Watchdog: upload exceeded 35s, forcing reset")
            self.activeUploadTask?.cancel()
            self.activeUploadTask = nil
            self.isTyping = false  // Clear isTyping so dictation isn't bricked (C-1)
            self.recorder.reset()
            self.error = "Transcription timed out"
        }
        uploadWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 35, execute: watchdog)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard let wavData = self.recorder.exportWAV() else {
                DispatchQueue.main.async {
                    self.uploadWatchdog?.cancel()
                    self.uploadWatchdog = nil
                    self.recorder.reset()
                }
                return
            }

            os_log(.default, log: dictLog, "WAV data: %d bytes, uploading to port %d", wavData.count, currentPort)

            // Skip very short recordings (< 0.3s at 16kHz 16-bit mono)
            if wavData.count < 9700 {
                DispatchQueue.main.async {
                    self.uploadWatchdog?.cancel()
                    self.uploadWatchdog = nil
                    self.recorder.reset()
                }
                return
            }

            self.uploadToWhisper(wavData: wavData, language: language, port: currentPort) { [weak self] result in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.uploadWatchdog?.cancel()
                    self.uploadWatchdog = nil
                    self.recorder.reset()
                    os_log(.default, log: dictLog, "Upload completed, state reset to idle")
                    switch result {
                    case .success(let text):
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        os_log(.default, log: dictLog, "Transcribed: %{public}@, inserting into PID %d", trimmed, pid)
                        self.lastTranscription = trimmed
                        self.error = nil
                        self.isTyping = true
                        self.insertText(trimmed, intoPID: pid) { [weak self] in
                            self?.isTyping = false
                        }
                    case .failure(let err):
                        os_log(.default, log: dictLog, "Upload failed: %{public}@", err.localizedDescription)
                        self.error = err.localizedDescription
                    }
                }
            }
        }
    }

    /// Play a subtle click sound on record start/stop (like Voquill's switch sound).
    private func playClick() {
        NSSound(named: "Tink")?.play()
    }

    /// Barge-in: kill any currently playing TTS audio when recording starts.
    /// Runs on a background queue to avoid blocking the main thread.
    func killTTS() {
        DispatchQueue.global(qos: .userInitiated).async {
            let pidFile = Paths.appSupport.appendingPathComponent("tts_hook.pid")
            let lockFile = Paths.appSupport.appendingPathComponent("tts_playing.lock")

            // Kill via PID file (matches tts-hook.sh behaviour)
            if let pidStr = try? String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               let pid = Int32(pidStr), pid > 0 {
                // Send SIGINT to afplay children, then SIGTERM to parent bash
                let pkill = Process()
                pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
                pkill.arguments = ["-INT", "-P", "\(pid)"]
                try? pkill.run()
                pkill.waitUntilExit()

                kill(pid, SIGTERM)
                try? FileManager.default.removeItem(at: pidFile)
            }

            try? FileManager.default.removeItem(at: lockFile)
        }
    }

    // MARK: - Upload to Whisper

    @discardableResult
    private func uploadToWhisper(
        wavData: Data,
        language: String?,
        port: Int,
        handsFree: Bool = false,
        completion: @escaping (Result<String, Error>) -> Void
    ) -> URLSessionDataTask? {
        guard let url = URL(string: "http://localhost:\(port)/v1/audio/transcriptions") else {
            completion(.failure(NSError(domain: "DictationManager", code: -1,
                                       userInfo: [NSLocalizedDescriptionKey: "Invalid server URL"])))
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        var body = Data()
        body.appendField(name: "model", value: "whisper", boundary: boundary)

        if let lang = language, !lang.isEmpty, lang != "auto" {
            body.appendField(name: "language", value: lang, boundary: boundary)
        }

        if handsFree {
            body.appendField(name: "hands_free", value: "true", boundary: boundary)
        }
        body.appendField(name: "response_format", value: "json", boundary: boundary)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n"
                .data(using: .utf8)!
        )
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            os_log(.default, log: dictLog, "Upload response: HTTP %d, data=%db, error=%{public}@",
                   statusCode, data?.count ?? 0, error?.localizedDescription ?? "nil")

            if let error {
                completion(.failure(error))
                return
            }
            guard
                let data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let text = json["text"] as? String
            else {
                completion(
                    .failure(
                        NSError(
                            domain: "DictationManager",
                            code: statusCode,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Whisper returned invalid response (HTTP \(statusCode))"
                            ]
                        )
                    )
                )
                return
            }
            completion(.success(text))
        }
        task.resume()
        return task
    }

    // MARK: - Insert Text (main thread orchestrator)

    /// Inserts `text` into the application identified by `pid`.
    /// Must be called on the main thread. `completion` is called on the main thread.
    private func insertText(_ text: String, intoPID pid: pid_t, forceSubmit: Bool = false, completion: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))

        // Resolve which app to focus: Auto-Focus target overrides captured PID
        let focusPID = resolveAutoFocusPID() ?? pid
        let targetPID = focusPID != 0 ? focusPID : pid

        // Capture current frontmost app as origin (for "with return")
        let currentFront = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let shouldReturn = autoFocusReturnEnabled && targetPID != 0 && currentFront != targetPID && currentFront != 0
        let returnPID = shouldReturn ? currentFront : 0

        // Wrap completion: auto-submit (Enter) first, then return to origin app
        let autoSubmitEnabled = FileManager.default.fileExists(atPath: Paths.autoSubmitFlag.path)
        let wrappedCompletion: () -> Void = {
            let returnBlock = {
                if returnPID != 0, let originApp = NSRunningApplication(processIdentifier: returnPID) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        originApp.activate()
                        os_log(.default, log: dictLog, "Returning to origin app: %{public}@ (PID %d)",
                               originApp.localizedName ?? "?", returnPID)
                    }
                }
                completion()
            }

            if autoSubmitEnabled || forceSubmit {
                // Press Enter after text insertion, before returning
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    if let enterDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x24, keyDown: true),
                       let enterUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x24, keyDown: false) {
                        enterDown.post(tap: .cgSessionEventTap)
                        enterUp.post(tap: .cgSessionEventTap)
                        os_log(.default, log: dictLog, "Auto-submit: Enter pressed")
                    }
                    // Delay return to let Enter propagate
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        returnBlock()
                    }
                }
            } else {
                returnBlock()
            }
        }

        // Check if target app is already frontmost
        let alreadyFocused = currentFront == targetPID

        // Activate the target app BEFORE any text insertion (native activation)
        if !alreadyFocused, targetPID != 0, let app = NSRunningApplication(processIdentifier: targetPID) {
            app.activate()
            os_log(.default, log: dictLog, "Activating app: %{public}@ (PID %d)", app.localizedName ?? "?", targetPID)
            // Delay to let activation complete before inserting text
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.doInsertText(text, pid: targetPID, completion: wrappedCompletion)
            }
            return
        }

        doInsertText(text, pid: targetPID, completion: wrappedCompletion)
    }

    /// Whether "with return" is enabled (return to origin app after auto-focus insertion).
    private var autoFocusReturnEnabled: Bool {
        FileManager.default.fileExists(atPath: Paths.autoFocusReturn.path)
    }

    /// Performs the actual text insertion after the target app is focused.
    private func doInsertText(_ text: String, pid: pid_t, completion: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))

        // Tier 1: AXUIElement — works for native AppKit apps
        if pid != 0 && insertViaAccessibility(text, pid: pid) {
            os_log(.default, log: dictLog, "Inserted via AXUIElement for PID %d", pid)
            completion()
            return
        }

        os_log(.default, log: dictLog, "AX insert failed, falling back to CGEvent Unicode typing")

        // Tier 2: CGEvent keyboardSetUnicodeString — types text without touching clipboard
        typeViaUnicodeEvents(text) {
            completion()
        }
    }

    // MARK: - Auto-Focus Resolution

    /// If Auto-Focus is enabled, find the PID of the configured app.
    /// Returns nil if Auto-Focus is not enabled or app isn't running.
    private func resolveAutoFocusPID() -> pid_t? {
        guard let name = try? String(contentsOf: Paths.autoFocusApp, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        // Find running app by name
        let apps = NSWorkspace.shared.runningApplications
        if let app = apps.first(where: { $0.localizedName == name }) {
            return app.processIdentifier
        }
        // Try matching by bundle name prefix (e.g. "Code" matches "Code - Insiders") (#17)
        if let app = apps.first(where: { ($0.localizedName ?? "").hasPrefix(name) }) {
            return app.processIdentifier
        }
        return nil
    }

    // MARK: - AXUIElement Text Insertion

    /// Attempts to insert `text` at the cursor position in the app with the given PID.
    /// Must be called on the main thread.
    /// Returns true on success.
    private func insertViaAccessibility(_ text: String, pid: pid_t) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))

        // Verify Accessibility permission is actually granted before any AX calls.
        // Pass false so we don't trigger the system prompt here (should already be granted).
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        guard AXIsProcessTrustedWithOptions(opts as CFDictionary) else {
            os_log(.default, log: dictLog, "AX: process not trusted (permission not granted)")
            return false
        }

        let appElement = AXUIElementCreateApplication(pid)

        // Get the focused UI element within that specific app.
        var focusedValue: AnyObject?
        let focusErr = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard focusErr == .success, let focused = focusedValue else {
            os_log(.default, log: dictLog, "AX: no focused element for PID %d (err=%d)", pid, focusErr.rawValue)
            return false
        }
        // CFTypeID check: AXUIElementCopyAttributeValue returns AnyObject (CFTypeRef).
        // Direct `as? AXUIElement` always succeeds for CF types, so compare CFTypeIDs.
        guard CFGetTypeID(focused as CFTypeRef) == AXUIElementGetTypeID() else {
            os_log(.default, log: dictLog, "AX: focused element is not AXUIElement for PID %d", pid)
            return false
        }
        let element = focused as! AXUIElement

        // Strategy A: kAXSelectedTextAttribute — replaces current selection / inserts at cursor.
        // Works for NSTextField, NSTextView, and most native AppKit fields.
        var isSettable: DarwinBoolean = false
        let settableErr = AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &isSettable
        )

        if settableErr == .success && isSettable.boolValue {
            let setErr = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                text as CFString
            )
            if setErr == .success {
                os_log(.default, log: dictLog, "AX: StrategyA success for PID %d", pid)
                return true
            }
            os_log(.default, log: dictLog, "AX: StrategyA set failed (err=%d)", setErr.rawValue)
        } else {
            os_log(.default, log: dictLog, "AX: StrategyA not settable (settableErr=%d, settable=%d)", settableErr.rawValue, isSettable.boolValue ? 1 : 0)
        }

        // Strategy B: kAXValueAttribute — works for some single-line fields that don't
        // expose kAXSelectedTextAttribute as settable but do expose kAXValue.
        var valueSettable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable)

        if valueSettable.boolValue {
            // Read existing value so we can append rather than replace
            var existingValue: AnyObject?
            AXUIElementCopyAttributeValue(
                element,
                kAXValueAttribute as CFString,
                &existingValue
            )
            let existing = (existingValue as? String) ?? ""

            // Get insertion point to insert at cursor position
            var rangeValue: AnyObject?
            var insertionIndex = (existing as NSString).length
            if AXUIElementCopyAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                &rangeValue
            ) == .success, let rv = rangeValue {
                var cfRange = CFRangeMake(0, 0)
                if CFGetTypeID(rv as CFTypeRef) == AXValueGetTypeID(),
                   AXValueGetValue(rv as! AXValue, .cfRange, &cfRange) {
                    insertionIndex = cfRange.location
                }
            }

            let nsExisting = existing as NSString
            let safeIndex = min(insertionIndex, nsExisting.length)
            // Use NSString for insertion to stay in UTF-16 space (matches CFRange)
            let nsNew = nsExisting.replacingCharacters(
                in: NSRange(location: safeIndex, length: 0),
                with: text
            )

            let setErr = AXUIElementSetAttributeValue(
                element,
                kAXValueAttribute as CFString,
                nsNew as CFString
            )
            if setErr == .success {
                // Move cursor to end of inserted text (UTF-16 length)
                var newRange = CFRangeMake(safeIndex + (text as NSString).length, 0)
                if let axRange = AXValueCreate(.cfRange, &newRange) {
                    AXUIElementSetAttributeValue(
                        element,
                        kAXSelectedTextRangeAttribute as CFString,
                        axRange
                    )
                }
                os_log(.default, log: dictLog, "AX: StrategyB success for PID %d", pid)
                return true
            }
            os_log(.default, log: dictLog, "AX: StrategyB set failed (err=%d)", setErr.rawValue)
        }

        return false
    }

    // MARK: - CGEvent Unicode Typing

    /// Types `text` by posting CGEvent keystrokes with `keyboardSetUnicodeString`.
    /// No clipboard involvement — each chunk is sent as a key-down/key-up pair.
    /// macOS limit is ~20 UTF-16 code units per event; we use chunks of 16 for safety.
    private func typeViaUnicodeEvents(_ text: String, completion: @escaping () -> Void) {
        let utf16 = Array(text.utf16)
        let chunkSize = 16
        let chunks = stride(from: 0, to: utf16.count, by: chunkSize).map {
            Array(utf16[$0..<min($0 + chunkSize, utf16.count)])
        }

        func typeChunk(at index: Int) {
            guard index < chunks.count else {
                diagLog("CGEvent Unicode typing done (\(utf16.count) UTF-16 units)")
                completion()
                return
            }

            var chunk = chunks[index]
            guard
                let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            else {
                self.error = "Typing failed — grant Accessibility permission in System Settings"
                diagLog("CGEvent creation failed at chunk \(index)")
                completion()
                return
            }

            keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            keyUp.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)

            keyDown.post(tap: .cgSessionEventTap)
            keyUp.post(tap: .cgSessionEventTap)

            // Small delay between chunks to let the target app process input (#22)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.003) {
                typeChunk(at: index + 1)
            }
        }

        typeChunk(at: 0)
    }

    // MARK: - Diagnostic Log

    private static let diagQueue = DispatchQueue(label: "com.openwhisperer.diaglog", qos: .utility)
    /// Formatter lives on diagQueue — only accessed there to avoid thread-safety issues (M-8)
    private static let diagFormatter = ISO8601DateFormatter()

    private func diagLog(_ msg: String) {
        let date = Date()
        Self.diagQueue.async {
            let timestamp = Self.diagFormatter.string(from: date)
            guard let data = "[\(timestamp)] \(msg)\n".data(using: .utf8) else { return }
            let diagPath = Paths.appSupport.appendingPathComponent("paste_debug.log")
            if FileManager.default.fileExists(atPath: diagPath.path) {
                if let fh = try? FileHandle(forWritingTo: diagPath) {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    try? fh.close()
                }
            } else {
                try? data.write(to: diagPath)
            }
        }
    }

    // MARK: - Language

    private func readLanguage() -> String? {
        let path = Paths.sttLanguage.path
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let lang = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return lang.isEmpty || lang == "auto" ? nil : lang
    }
}

// MARK: - Multipart helpers

private extension Data {
    mutating func appendField(name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }
}
