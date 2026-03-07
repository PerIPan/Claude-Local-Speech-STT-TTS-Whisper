import Foundation
import SwiftUI

enum ConfigManager {

    // MARK: - Claude Code: settings.json

    static func showClaudeSettingsInstructions() {
        let hookPath = Paths.ttsHook.path
        let window = InstructionWindow(
            title: "Step 1: Claude Code Hook (settings.json)",
            instructions: """
            Add the TTS hook to your Claude Code settings:

            1. Open ~/.claude/settings.json
               (or your project's .claude/settings.json)

            2. Add the following:

            {
              "hooks": {
                "Stop": [{
                  "hooks": [{
                    "type": "command",
                    "command": "\(hookPath)",
                    "timeout": 60
                  }]
                }]
              }
            }

            This makes Claude speak every response aloud.
            """
        )
        window.show()
    }

    // MARK: - Claude Code: CLAUDE.md

    static func showClaudeMdInstructions() {
        let window = InstructionWindow(
            title: "Step 2: CLAUDE.md (Voice Tag)",
            instructions: """
            Add this to your project's CLAUDE.md file:

            ## Voice Mode
            ALWAYS include a [VOICE: ...] tag at the END
            of every response. This tag contains a short,
            conversational spoken summary (1-3 sentences)
            that the TTS hook extracts and reads aloud.

            Write the voice content as natural speech -
            no code, no file paths, no markdown.

            Example:
            [VOICE: I fixed the bug in the login page.
            It was a missing null check on the user object.]

            This tells Claude to add a spoken summary
            to every response.
            """
        )
        window.show()
    }

    // MARK: - Voquill Instructions

    static func showVoquillInstructions(sttPort: Int) {
        let window = InstructionWindow(
            title: "Configure Voquill",
            instructions: """
            Set up Voquill to use your local Whisper server:

            1. Open Voquill settings
            2. Select "OpenAI Compatible API" mode
            3. Set these values:

               Endpoint:  http://localhost:\(sttPort)
               Model:     whisper
               API Key:   whisper
               Language:  en

            4. Make sure the Whisper server is running
               (green dot in menubar)

            Voquill will now use your local Whisper for
            high-accuracy, private transcription.
            """
        )
        window.show()
    }

    // MARK: - Voquill Download

    static func showVoquillDownload() {
        let window = InstructionWindow(
            title: "Get Voquill",
            instructions: """
            Voquill is a free, open-source macOS dictation app
            that works with your local Whisper server.

            Download from GitHub:
            https://github.com/nicobailey/Voquill

            1. Go to the Releases page
            2. Download the latest .dmg
            3. Drag Voquill to Applications
            4. Then use "Voquill Setup" in the menubar
               to configure it for local Whisper
            """
        )
        window.show()
    }

    // MARK: - View Logs (individual)

    static func showLog(name: String, url: URL) {
        // Read only last 32KB to avoid memory spike on large logs (BUG-16)
        var content = ""
        if let fileHandle = try? FileHandle(forReadingFrom: url) {
            defer { fileHandle.closeFile() }
            let fileSize = fileHandle.seekToEndOfFile()
            let readStart: UInt64 = fileSize > 32768 ? fileSize - 32768 : 0
            fileHandle.seek(toFileOffset: readStart)
            let rawData = fileHandle.readDataToEndOfFile()
            // Try UTF-8 first, fall back to lossy Latin-1
            let decoded = String(data: rawData, encoding: .utf8)
                ?? String(data: rawData, encoding: .isoLatin1)
                ?? "(unable to read log)"
            if decoded == "(unable to read log)" {
                content = decoded
            } else {
                let lines = decoded.components(separatedBy: "\n")
                let cleanLines = readStart > 0 ? Array(lines.dropFirst()) : lines
                let tail = cleanLines.suffix(80).joined(separator: "\n")
                content = tail.isEmpty ? "(empty)" : tail
            }
        } else {
            content = "(no log file yet)"
        }

        let window = InstructionWindow(
            title: "\(name) Log",
            instructions: content
        )
        window.show()
    }
}

// MARK: - Instruction Window

class InstructionWindow: NSObject, NSWindowDelegate {
    private let title: String
    private let instructions: String
    private var window: NSWindow?

    // Keep alive until window closes — all access on main thread (BUG-10)
    private static var activeWindows: [InstructionWindow] = []

    init(title: String, instructions: String) {
        self.title = title
        self.instructions = instructions
    }

    func show() {
        DispatchQueue.main.async { [self] in
            // Append on main thread to avoid data race (BUG-10)
            InstructionWindow.activeWindows.append(self)

            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            w.title = title
            w.center()
            w.isReleasedWhenClosed = false
            w.delegate = self

            let hostingView = NSHostingView(rootView: InstructionView(
                title: title,
                instructions: instructions
            ))
            w.contentView = hostingView
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

            self.window = w
        }
    }

    func windowWillClose(_ notification: Notification) {
        InstructionWindow.activeWindows.removeAll { $0 === self }
    }
}

struct InstructionView: View {
    let title: String
    let instructions: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                Text(instructions)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }

            HStack {
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(instructions, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                }) {
                    Label(copied ? "Copied!" : "Copy to Clipboard", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Spacer()
            }
        }
        .padding(16)
    }
}
