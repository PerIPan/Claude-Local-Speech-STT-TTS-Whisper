import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var setupManager: SetupManager
    @State private var autoSubmit = false
    @State private var autoFocusEnabled = false
    @State private var focusAppName = ""
    @State private var focusSelection = "Code"  // visual default; only written on explicit toggle
    @State private var customFocusApp = ""

    private static let focusApps = [
        "Code",
        "Code - Insiders",
        "Cursor",
        "Windsurf",
        "Terminal",
        "iTerm2",
        "Warp",
        "Alacritty",
        "Ghostty",
        "Custom"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Image(systemName: "waveform")
                    .foregroundColor(.accentColor)
                Text("Claude Whisperer")
                    .font(.headline)
            }
            .padding(.bottom, 4)

            Divider()

            // Setup in progress
            if case .inProgress(let step) = setupManager.state {
                VStack(alignment: .leading, spacing: 4) {
                    Text(step)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ProgressView(value: setupManager.progress)
                        .progressViewStyle(.linear)
                }
                .padding(.vertical, 4)
            } else if case .failed(let reason) = setupManager.state {
                VStack(alignment: .leading, spacing: 4) {
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.red)
                    Button("Retry Setup") {
                        setupManager.resetAndRerun { success in
                            if success { serverManager.startAll() }
                        }
                    }
                }
                .padding(.vertical, 4)
            } else {
                // Server status
                StatusRow(label: "Whisper STT", port: "\(serverManager.sttPort)", status: serverManager.sttStatus)
                StatusRow(label: "Kokoro TTS", port: "\(serverManager.ttsPort)", status: serverManager.ttsStatus)
            }

            Divider()

            // Automation group
            HStack {
                Text("Automation")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("(requires Accessibility permission)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Toggle(isOn: $autoSubmit) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-Submit")
                    Text("Say \"submit\" / \"send\" at end of phrase")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            .onChange(of: autoSubmit) { _, enabled in
                if enabled {
                    try? "on".write(to: Paths.autoSubmitFlag, atomically: true, encoding: .utf8)
                } else {
                    try? FileManager.default.removeItem(at: Paths.autoSubmitFlag)
                }
            }

            Toggle(isOn: $autoFocusEnabled) {
                Text("Auto-Focus")
            }
            .toggleStyle(.checkbox)
            .onChange(of: autoFocusEnabled) { _, enabled in
                if enabled {
                    // Set default on first enable if no app was loaded from disk
                    if focusAppName.isEmpty {
                        focusAppName = focusSelection == "Custom" ? customFocusApp : focusSelection
                    }
                    saveFocusApp()
                } else {
                    try? FileManager.default.removeItem(at: Paths.autoFocusApp)
                }
            }

            if autoFocusEnabled {
                Picker("", selection: $focusSelection) {
                    ForEach(Self.focusApps, id: \.self) { app in
                        Text(app).tag(app)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .padding(.leading, 20)
                .onChange(of: focusSelection) { _, newValue in
                    if newValue == "Custom" {
                        focusAppName = customFocusApp
                    } else {
                        focusAppName = newValue
                    }
                    saveFocusApp()
                }

                if focusSelection == "Custom" {
                    TextField("App name", text: $customFocusApp)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .padding(.leading, 20)
                        .onChange(of: customFocusApp) { _, newValue in
                            if !newValue.isEmpty {
                                focusAppName = newValue
                                saveFocusApp()
                            }
                        }
                }
            }

            Divider()

            // Ports (always visible, editable only when stopped)
            let isStopped = serverManager.sttStatus == .stopped && serverManager.ttsStatus == .stopped
            PortField(label: "STT Port", port: $serverManager.sttPort, disabled: !isStopped)
            PortField(label: "TTS Port", port: $serverManager.ttsPort, disabled: !isStopped)

            if isStopped {
                Button(action: { serverManager.startAll() }) {
                    Label("Start Servers", systemImage: "play.circle")
                }
            } else {
                Button(action: {
                    serverManager.stopAll()
                    // Show alert after a brief delay so status updates first (BUG-14)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        showStoppedAlert()
                    }
                }) {
                    Label("Stop Servers", systemImage: "stop.circle")
                }
                Button(action: { serverManager.restartAll() }) {
                    Label("Restart Servers", systemImage: "arrow.clockwise")
                }
            }

            Divider()

            // Claude setup (split into steps)
            Text("Claude Setup")
                .font(.caption)
                .foregroundColor(.secondary)

            Button(action: { ConfigManager.showClaudeSettingsInstructions() }) {
                Label("settings.json (Hook)", systemImage: "gearshape")
            }

            Button(action: { ConfigManager.showClaudeMdInstructions() }) {
                Label("CLAUDE.md (Voice Tag)", systemImage: "doc.text")
            }

            Divider()

            // Voquill
            Text("Voquill")
                .font(.caption)
                .foregroundColor(.secondary)

            Button(action: { ConfigManager.showVoquillInstructions(sttPort: serverManager.sttPort) }) {
                Label("Voquill Setup", systemImage: "mic")
            }

            Button(action: { ConfigManager.showVoquillDownload() }) {
                Label("Get Voquill", systemImage: "arrow.down.circle")
            }

            Divider()

            // Logs (split per server)
            Text("Logs")
                .font(.caption)
                .foregroundColor(.secondary)

            Button(action: { ConfigManager.showLog(name: "Whisper STT", url: Paths.sttLog) }) {
                Label("STT Log", systemImage: "doc.text.magnifyingglass")
            }

            Button(action: { ConfigManager.showLog(name: "Kokoro TTS", url: Paths.ttsLog) }) {
                Label("TTS Log", systemImage: "doc.text.magnifyingglass")
            }

            Divider()

            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.0")")
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            Button(action: { NSApplication.shared.terminate(nil) }) {
                Label("Quit", systemImage: "power")
            }
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 260)
        .onAppear {
            // Load state from disk on appear instead of @State init (BUG-05)
            autoSubmit = FileManager.default.fileExists(atPath: Paths.autoSubmitFlag.path)
            autoFocusEnabled = FileManager.default.fileExists(atPath: Paths.autoFocusApp.path)
            if let saved = try? String(contentsOf: Paths.autoFocusApp, encoding: .utf8),
               !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let name = saved.trimmingCharacters(in: .whitespacesAndNewlines)
                focusAppName = name
                if Self.focusApps.contains(name) {
                    focusSelection = name
                } else {
                    focusSelection = "Custom"
                    customFocusApp = name
                }
            }
        }
    }

    private func saveFocusApp() {
        guard autoFocusEnabled, !focusAppName.isEmpty else { return }
        try? focusAppName.write(to: Paths.autoFocusApp, atomically: true, encoding: .utf8)
    }

    private func showStoppedAlert() {
        let alert = NSAlert()
        alert.messageText = "Servers Stopped"
        alert.informativeText = "Both STT and TTS servers have been stopped."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

struct PortField: View {
    let label: String
    @Binding var port: Int
    var disabled: Bool = false
    @State private var text: String = ""

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .frame(width: 60, alignment: .leading)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .disabled(disabled)
                .opacity(disabled ? 0.6 : 1.0)
                .onAppear { text = "\(port)" }
                .onChange(of: text) { _, newValue in
                    if let p = Int(newValue), p > 0, p <= 65535 {
                        port = p
                    }
                }
                .onChange(of: port) { _, newPort in
                    // Sync text when port changes externally (BUG-07)
                    let portStr = "\(newPort)"
                    if text != portStr { text = portStr }
                }
        }
    }
}

struct StatusRow: View {
    let label: String
    let port: String
    let status: ServerManager.ServerStatus

    var body: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(.body, design: .default))
            Spacer()
            Text(":\(port)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var statusColor: Color {
        switch status {
        case .running: return .green
        case .starting: return .orange
        case .error: return .red
        case .stopped: return .gray
        }
    }
}
