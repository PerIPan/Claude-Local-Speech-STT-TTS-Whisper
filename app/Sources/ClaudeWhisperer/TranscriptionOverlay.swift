import Foundation
import SwiftUI

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
    private var nextLineId = 0

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
    @Published var currentRecorder: AudioRecorder = AudioRecorder()

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

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 160),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        w.level = .floating
        w.isReleasedWhenClosed = false
        w.isMovableByWindowBackground = true
        w.delegate = self
        w.contentView = hostingView
        w.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92)
        w.hasShadow = true
        w.minSize = NSSize(width: 200, height: 80)

        // Position bottom-right of screen
        if let screen = NSScreen.main {
            let x = screen.visibleFrame.maxX - 360
            let y = screen.visibleFrame.minY + 20
            w.setFrameOrigin(NSPoint(x: x, y: y))
        }

        w.makeKeyAndOrderFront(nil)
        self.window = w
        isVisible = true
        startTailing()
    }

    func hide() {
        stopTailing()
        window?.close()
        window = nil
        isVisible = false
    }

    func windowWillClose(_ notification: Notification) {
        stopTailing()
        window = nil
        isVisible = false
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
        source?.cancel()
        source = nil
        fileHandle = nil
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
            // Waveform always visible — shows status label + bars
            WaveformBar(recorder: recorder)
                .frame(height: 44)
                .padding(.horizontal, 8)
                .padding(.top, 6)

            Divider().padding(.horizontal, 8).padding(.vertical, 4)

            if overlay.lines.isEmpty && recorder.state == .idle {
                Text("Listening for transcriptions...")
                    .font(.custom("Outfit", size: 10))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(overlay.lines.reversed()) { line in
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

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Circle()
                    .fill(recorder.state == .recording ? Color.red :
                          recorder.state == .uploading ? Color.orange : Color.green)
                    .frame(width: 8, height: 8)
                Text(recorder.state == .recording ? "Recording..." :
                     recorder.state == .uploading ? "Transcribing..." : "Standby")
                    .font(.custom("Outfit", size: 10))
                    .foregroundColor(recorder.state == .recording ? .red :
                                     recorder.state == .uploading ? .orange : .green)
                Spacer()
                if recorder.state == .recording {
                    Text("Press Ctrl to stop")
                        .font(.custom("Outfit", size: 9))
                        .foregroundColor(.secondary)
                }
            }

            // Waveform always visible — flat bars when idle, active when recording, dimmed when transcribing
            GeometryReader { geo in
                HStack(alignment: .center, spacing: 2) {
                    ForEach(0..<recorder.levelHistory.count, id: \.self) { i in
                        let level = CGFloat(recorder.levelHistory[i])
                        let barHeight = max(2, level * geo.size.height * 0.9)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.orange.opacity(level * 0.5 + 0.5))
                            .frame(width: 3, height: barHeight)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(recorder.state == .uploading ? 0.4 : recorder.state == .idle ? 0.3 : 1.0)
            }
        }
    }
}
