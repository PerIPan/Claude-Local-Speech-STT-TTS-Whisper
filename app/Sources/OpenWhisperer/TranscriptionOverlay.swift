import Foundation
import SwiftUI

/// Borderless window that accepts keyboard input (enables Cmd+C for text selection).
private class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

class TranscriptionOverlay: NSObject, NSWindowDelegate, ObservableObject {
    static let shared = TranscriptionOverlay()

    private var window: NSWindow?
    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?

    struct Line: Identifiable {
        let id: Int
        let text: String
    }

    @Published var lines: [Line] = []
    @Published var isVisible: Bool = false
    @Published var isTTSPlaying: Bool = false
    private var nextLineId = 0
    private var ttsTimer: Timer?

    /// The current PTT key label shown in the overlay (e.g. "Ctrl", "fn").
    @Published var pttKeyLabel: String = "Ctrl"

    /// Current interaction mode — determines hint text during recording.
    @Published var interactionMode: InteractionMode = .pressToTalk

    /// Reference to dictation manager for waveform display.
    ///
    /// FIX: Use a @Published wrapper so the SwiftUI root view can observe
    /// the recorder reference changing, instead of tearing down NSHostingView.
    /// Tearing down NSHostingView cancels the TimelineView render loop and
    /// creates a new @ObservedObject subscription to a potentially stale instance.
    var dictationManager: DictationManager? {
        didSet {
            // FIX: Rather than recreating the entire NSHostingView (which kills
            // the TimelineView animation loop and risks observing a stale recorder),
            // publish the new recorder reference through a @Published property on
            // the overlay so the live SwiftUI tree picks it up reactively.
            if let dm = dictationManager {
                currentRecorder = dm.recorder
            }
        }
    }

    /// The live recorder reference. Published so the SwiftUI view tree reacts
    /// to recorder swaps without NSHostingView teardown.
    ///
    /// FIX: This is the critical fix. @ObservedObject inside NSHostingView works
    /// correctly, but ONLY if it holds the same instance that is actually recording.
    /// Previously, show() could capture a throwaway AudioRecorder() when
    /// dictationManager was nil, and that dead instance would be observed forever.
    @Published var currentRecorder: AudioRecorder = AudioRecorder(skipPermissionCheck: true)

    func show() {
        if let w = window {
            // FIX: Never recreate NSHostingView on an already-constructed window.
            // Recreating it tears down the entire SwiftUI render tree, cancels
            // TimelineView subscriptions, and forces a new @ObservedObject binding
            // cycle. Instead, update currentRecorder (above) and just re-front the window.
            if let dm = dictationManager {
                currentRecorder = dm.recorder
            }
            w.orderFront(nil)
            isVisible = true
            return
        }

        // Capture the real recorder now, or use the already-initialised placeholder.
        if let dm = dictationManager {
            currentRecorder = dm.recorder
        }

        // FIX: Pass `self` (the overlay) as the single source of truth. The SwiftUI
        // view will derive its recorder from overlay.currentRecorder. This way,
        // when the recorder changes, SwiftUI's normal @ObservedObject diffing handles
        // the update inside the existing live view tree — no NSHostingView rebuild needed.
        let hostingView = NSHostingView(rootView: OverlayView(overlay: self))

        // FIX: sizingOptions ensures the hosting view participates in layout
        // and does not clip the SwiftUI render layer, which can suppress CA commits.
        hostingView.sizingOptions = [.minSize, .intrinsicContentSize, .preferredContentSize]

        let w = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 130),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        w.level = .floating
        w.isReleasedWhenClosed = false
        w.isMovableByWindowBackground = true
        w.delegate = self
        w.contentView = hostingView
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = true
        w.minSize = NSSize(width: 160, height: 70)

        // Round corners
        if let contentView = w.contentView {
            contentView.wantsLayer = true
            contentView.layer?.cornerRadius = 12
            contentView.layer?.masksToBounds = true
            contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        }

        // Position bottom-right of screen
        if let screen = NSScreen.main {
            let x = screen.visibleFrame.maxX - 300
            let y = screen.visibleFrame.minY + 20
            w.setFrameOrigin(NSPoint(x: x, y: y))
        }

        w.orderFront(nil)
        self.window = w
        isVisible = true
        startTailing()
        startTTSPolling()
    }

    func hide() {
        stopTailing()
        stopTTSPolling()
        window?.close()
        window = nil
        isVisible = false
    }

    func windowWillClose(_ notification: Notification) {
        stopTailing()
        stopTTSPolling()
        window = nil
        isVisible = false
    }

    private func startTTSPolling() {
        ttsTimer?.invalidate()
        let lockPath = Paths.appSupport.appendingPathComponent("tts_playing.lock").path
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            let playing = FileManager.default.fileExists(atPath: lockPath)
            if self?.isTTSPlaying != playing {
                self?.isTTSPlaying = playing
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ttsTimer = timer
    }

    private func stopTTSPolling() {
        ttsTimer?.invalidate()
        ttsTimer = nil
        isTTSPlaying = false
    }

    private func startTailing() {
        stopTailing()

        let logPath = Paths.serverLog.path
        guard FileManager.default.fileExists(atPath: logPath) else { return }

        guard let fh = FileHandle(forReadingAtPath: logPath) else { return }
        fh.seekToEndOfFile()
        fileHandle = fh

        let fd = fh.fileDescriptor
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: .global(qos: .utility)
        )

        src.setEventHandler { [weak self] in
            guard let self else { return }
            let data = fh.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else { return }

            let newLines = text.components(separatedBy: "\n")
                .filter { $0.contains("Transcribed:") }
                .compactMap { line -> String? in
                    guard let range = line.range(of: "Transcribed: ") else { return nil }
                    return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .filter { !$0.isEmpty }

            if !newLines.isEmpty {
                DispatchQueue.main.async {
                    let tagged = newLines.map { text -> Line in
                        self.nextLineId += 1
                        return Line(id: self.nextLineId, text: text)
                    }
                    self.lines.append(contentsOf: tagged)
                    if self.lines.count > 3 {
                        self.lines = Array(self.lines.suffix(3))
                    }
                }
            }
        }

        src.setCancelHandler {
            try? fh.close()
        }

        src.resume()
        source = src
    }

    private func stopTailing() {
        // Cancel source first — its cancel handler exclusively closes the file handle (H-4)
        let src = source
        source = nil
        fileHandle = nil
        src?.cancel()
    }
}

// MARK: - Overlay View

struct OverlayView: View {
    /// FIX: Observe the overlay as the single source of truth. The overlay's
    /// @Published currentRecorder is how we get the live recorder reference.
    /// We do NOT take recorder as a direct init parameter anymore — doing so
    /// would freeze the reference at the moment NSHostingView was constructed.
    @ObservedObject var overlay: TranscriptionOverlay

    var body: some View {
        // FIX: Derive recorder from overlay.currentRecorder each time body evaluates.
        // Because overlay is @ObservedObject and currentRecorder is @Published,
        // any assignment to overlay.currentRecorder triggers a body re-evaluation
        // here, giving WaveformBar the new live instance.
        let recorder = overlay.currentRecorder

        VStack(alignment: .leading, spacing: 0) {
            // Close button
            HStack {
                Spacer()
                Button(action: { overlay.hide() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
                .padding(.trailing, 6)
            }
            .frame(height: 14)

            // Waveform always visible — shows status label + bars
            WaveformBar(recorder: recorder, isTTSPlaying: overlay.isTTSPlaying, pttKeyLabel: overlay.pttKeyLabel, interactionMode: overlay.interactionMode)
                .frame(height: 36)
                .padding(.horizontal, 8)

            // Silence progress bar — always visible in hands-free mode
            if overlay.interactionMode == .handsFree {
                SilenceProgressBar(recorder: recorder)
                    .frame(height: 1.5)
                    .padding(.horizontal, 8)
                    .padding(.top, 3)
            }

            Divider().padding(.horizontal, 8).padding(.vertical, 4)

            if overlay.lines.isEmpty && recorder.state == .idle {
                Text("Listening for transcriptions...")
                    .font(.custom("Outfit", size: 10))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(overlay.lines.reversed().enumerated()), id: \.element.id) { index, line in
                            if index > 0 {
                                Divider()
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 4)
                            }
                            Text(line.text)
                                .font(.custom("Outfit", size: 11))
                                .textSelection(.enabled)
                                .id(line.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Waveform Bar

struct WaveformBar: View {
    @ObservedObject var recorder: AudioRecorder
    var isTTSPlaying: Bool = false
    var pttKeyLabel: String = "Ctrl"
    var interactionMode: InteractionMode = .pressToTalk

    /// Active waveform gradient: cyan → blue → purple → magenta
    private static let waveGradient = LinearGradient(
        colors: [
            Color(red: 0.0, green: 0.78, blue: 0.95),
            Color(red: 0.35, green: 0.60, blue: 0.90),
            Color(red: 0.55, green: 0.45, blue: 0.80),
            Color(red: 0.72, green: 0.30, blue: 0.68),
            Color(red: 0.82, green: 0.22, blue: 0.55),
        ],
        startPoint: .leading,
        endPoint: .trailing
    )

    /// Idle/standby waveform gradient: green tones
    private static let idleGradient = LinearGradient(
        colors: [
            Color(red: 0.2, green: 0.75, blue: 0.4),
            Color(red: 0.3, green: 0.8, blue: 0.5),
            Color(red: 0.2, green: 0.7, blue: 0.45),
        ],
        startPoint: .leading,
        endPoint: .trailing
    )

    /// Listening gradient: cyan/blue tones
    private static let listeningGradient = LinearGradient(
        colors: [
            Color(red: 0.0, green: 0.75, blue: 0.9),
            Color(red: 0.1, green: 0.8, blue: 1.0),
            Color(red: 0.0, green: 0.7, blue: 0.85),
        ],
        startPoint: .leading,
        endPoint: .trailing
    )

    /// TTS-mode gradient: warm orange tones
    private static let ttsGradient = LinearGradient(
        colors: [
            Color(red: 1.0, green: 0.6, blue: 0.2),
            Color(red: 1.0, green: 0.45, blue: 0.3),
            Color(red: 0.95, green: 0.35, blue: 0.45),
        ],
        startPoint: .leading,
        endPoint: .trailing
    )

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.custom("Outfit", size: 10))
                    .foregroundColor(statusColor)
                Spacer()
                if recorder.state == .recording {
                    let hint: String = {
                        switch interactionMode {
                        case .holdToTalk: return "Release \(pttKeyLabel) to stop"
                        case .handsFree: return "silence submits"
                        case .pressToTalk: return "Press \(pttKeyLabel) to stop"
                        }
                    }()
                    Text(hint)
                        .font(.custom("Outfit", size: 9))
                        .foregroundColor(.secondary)
                }
            }

            // Mirrored line waveform
            GeometryReader { geo in
                if isTTSPlaying && recorder.state == .idle {
                    TimelineView(.animation(minimumInterval: 0.03)) { timeline in
                        let time = timeline.date.timeIntervalSinceReferenceDate
                        let levels = Self.ttsLevels(count: 50, time: time)
                        Self.mirroredLines(levels: levels, size: geo.size)
                            .fill(Self.ttsGradient)
                    }
                } else {
                    let gradient = recorder.state == .listening ? Self.listeningGradient : Self.idleGradient
                    Self.mirroredLines(levels: recorder.levelHistory.map { CGFloat($0) }, size: geo.size)
                        .fill(gradient)
                        .opacity(recorder.state == .uploading ? 0.5 : recorder.state == .idle ? 0.25 : 1.0)
                }
            }
        }
    }

    // MARK: - Mirrored Lines

    /// Vertical bars mirrored around center line, tapered at edges.
    private static func mirroredLines(levels: [CGFloat], size: CGSize) -> Path {
        guard !levels.isEmpty else { return Path() }

        let n = levels.count
        let barWidth: CGFloat = 2
        let gap: CGFloat = max(1, (size.width - barWidth * CGFloat(n)) / CGFloat(n - 1))
        let step = barWidth + gap
        let midY = size.height / 2
        let maxHalf = midY - 1  // leave 1pt breathing room

        var path = Path()
        for (i, level) in levels.enumerated() {
            let t = CGFloat(i) / CGFloat(max(n - 1, 1))
            let taper = min(t * 5, (1 - t) * 5, 1.0)
            let h = max(1, level * taper * maxHalf)
            let x = CGFloat(i) * step
            let rect = CGRect(x: x, y: midY - h, width: barWidth, height: h * 2)
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: 1, height: 1))
        }
        return path
    }

    /// Generate sine-wave levels for TTS animation.
    private static func ttsLevels(count: Int, time: Double) -> [CGFloat] {
        (0..<count).map { i in
            let t = Double(i) / Double(count - 1)
            let wave1 = sin(time * 3.0 + t * .pi * 4) * 0.35
            let wave2 = sin(time * 1.8 + t * .pi * 2.5) * 0.25
            let wave3 = sin(time * 5.0 + t * .pi * 7) * 0.1
            return CGFloat(max(0.05, (wave1 + wave2 + wave3 + 0.5) * 0.8))
        }
    }

    private var statusColor: Color {
        if isTTSPlaying && recorder.state == .idle { return .orange }
        switch recorder.state {
        case .recording: return .red
        case .uploading: return .orange
        case .listening: return .cyan
        case .idle: return .green
        }
    }

    private var statusText: String {
        if isTTSPlaying && recorder.state == .idle { return "Speaking..." }
        switch recorder.state {
        case .recording: return "Recording..."
        case .uploading: return "Transcribing..."
        case .listening: return "Listening..."
        case .idle: return "Standby"
        }
    }
}

// MARK: - Silence Progress Bar

struct SilenceProgressBar: View {
    @ObservedObject var recorder: AudioRecorder

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05)) { timeline in
            GeometryReader { geo in
                let progress = silenceProgress(at: timeline.date)
                ZStack(alignment: .leading) {
                    // Track (always visible)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(0.25))
                    // Fill
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.green)
                        .frame(width: max(0, geo.size.width * progress))
                }
            }
        }
    }

    private func silenceProgress(at now: Date) -> CGFloat {
        // Only show fill during active recording (not listening/idle)
        guard recorder.state == .recording,
              let start = recorder.silenceStart,
              recorder.silenceThresholdSeconds > 0 else { return 0 }
        let elapsed = now.timeIntervalSince(start)
        return CGFloat(min(max(elapsed / recorder.silenceThresholdSeconds, 0), 1))
    }
}
