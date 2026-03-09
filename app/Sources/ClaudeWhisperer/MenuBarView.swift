import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var setupManager: SetupManager
    @EnvironmentObject var dictationManager: DictationManager
    @State private var autoSubmit = false
    @State private var autoFocusEnabled = false
    @State private var focusAppName = ""
    @State private var focusSelection = "Code"  // visual default; only written on explicit toggle
    @State private var customFocusApp = ""
    @State private var saveDebounce: DispatchWorkItem?
    @State private var selectedVoice = "af_heart"
    @State private var selectedLanguage = "auto"
    @State private var showStoppedBanner = false
    @State private var hookApplied = false
    @State private var claudeMdApplied = false
    @State private var applyMessage = ""
    @State private var serverReachable = false
    @State private var cleanMessage = ""
    @ObservedObject private var overlay = TranscriptionOverlay.shared

    private static let voices: [(id: String, label: String)] = [
        ("af_heart", "Heart (Female)"),
        ("af_bella", "Bella (Female)"),
        ("af_sarah", "Sarah (Female)"),
        ("af_nicole", "Nicole (Female)"),
        ("am_michael", "Michael (Male)"),
        ("am_adam", "Adam (Male)"),
        ("bf_emma", "Emma (British F)"),
        ("bm_george", "George (British M)"),
    ]

    private static let languages: [(id: String, label: String)] = [
        ("auto", "Auto-detect"),
        ("en", "English"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("nl", "Dutch"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("zh", "Chinese"),
        ("ar", "Arabic"),
        ("hi", "Hindi"),
        ("ru", "Russian"),
        ("pl", "Polish"),
        ("tr", "Turkish"),
        ("uk", "Ukrainian"),
        ("sv", "Swedish"),
    ]

    private static let focusApps = [
        "Code",
        "Code - Insiders",
        "Cursor",
        "Windsurf",
        "Claude",
        "Terminal",
        "iTerm2",
        "Warp",
        "Alacritty",
        "Ghostty",
        "Custom"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 8) {
                if let appIcon = NSApp.applicationIconImage {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 32, height: 32)
                }
                Text("Claude Whisperer")
                    .font(.custom("Outfit", size: 16).weight(.semibold))
            }
            .padding(.bottom, 4)

            Divider().opacity(0.4)

            // Setup in progress
            if case .inProgress(let step) = setupManager.state {
                VStack(alignment: .leading, spacing: 4) {
                    Text(step)
                        .font(.custom("Outfit", size: 12))
                        .foregroundColor(.secondary)
                    ProgressView(value: setupManager.progress)
                        .progressViewStyle(.linear)
                        .tint(.blue)
                }
                .padding(.vertical, 4)
            } else if case .failed(let reason) = setupManager.state {
                VStack(alignment: .leading, spacing: 4) {
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .font(.custom("Outfit", size: 12))
                        .foregroundColor(.red)
                    Button("Retry Setup") {
                        setupManager.resetAndRerun { success in
                            guard success else { return }
                            DispatchQueue.main.async { serverManager.startAll() }
                        }
                    }
                    .buttonStyle(MenuBarButtonStyle())
                }
                .padding(.vertical, 4)
            } else {
                // Server status — single unified server
                StatusRow(label: "Whisper STT", subtitle: serverManager.sttModel, port: "\(serverManager.port)", status: serverManager.status)
                StatusRow(label: "Kokoro TTS", subtitle: serverManager.ttsModel, port: "\(serverManager.port)", status: serverManager.status)

                let isStopped = serverManager.status == .stopped
                PortField(label: "Port", port: $serverManager.port, disabled: !isStopped)
            }

            Divider().opacity(0.4)

            // Automation — checkboxes up top, info below
            HStack(spacing: 4) {
                Image(systemName: "gearshape.2")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text("Automation")
                    .font(.custom("Outfit", size: 11).weight(.medium))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 16) {
                Toggle("auto-submit", isOn: $autoSubmit)
                    .font(.custom("Outfit", size: 13))
                    .toggleStyle(.checkbox)

                Toggle("auto-focus", isOn: $autoFocusEnabled)
                    .font(.custom("Outfit", size: 13))
                    .toggleStyle(.checkbox)
            }
            .onChange(of: autoSubmit) { _, enabled in
                if enabled {
                    try? "on".write(to: Paths.autoSubmitFlag, atomically: true, encoding: .utf8)
                } else {
                    do {
                        try FileManager.default.removeItem(at: Paths.autoSubmitFlag)
                    } catch {
                        NSLog("Failed to remove auto-submit flag: \(error)")
                    }
                }
            }
            .onChange(of: autoFocusEnabled) { _, enabled in
                if enabled {
                    if focusAppName.isEmpty {
                        focusAppName = focusSelection == "Custom" ? customFocusApp : focusSelection
                    }
                    saveFocusApp()
                } else {
                    try? FileManager.default.removeItem(at: Paths.autoFocusApp)
                }
            }

            // Info text below checkboxes
            VStack(alignment: .leading, spacing: 3) {
                Text("Submit: say \"submit\" or \"send\" at end of phrase")
                    .font(.custom("Outfit", size: 10))
                    .foregroundColor(.secondary)
                Text("Requires Accessibility permission")
                    .font(.custom("Outfit", size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 2)

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
                        .font(.custom("Outfit", size: 12))
                        .padding(.leading, 20)
                        .onChange(of: customFocusApp) { _, newValue in
                            if !newValue.isEmpty {
                                focusAppName = newValue
                                debouncedSaveFocusApp()
                            }
                        }
                }
            }

            Divider().opacity(0.4)

            // Language & Voice
            HStack {
                Text("Language")
                    .font(.custom("Outfit", size: 12))
                    .frame(width: 60, alignment: .leading)
                Picker("", selection: $selectedLanguage) {
                    ForEach(Self.languages, id: \.id) { lang in
                        Text(lang.label).tag(lang.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
            .onChange(of: selectedLanguage) { _, newValue in
                if newValue == "auto" {
                    try? FileManager.default.removeItem(at: Paths.sttLanguage)
                } else {
                    try? newValue.write(to: Paths.sttLanguage, atomically: true, encoding: .utf8)
                }
            }

            HStack {
                Text("Voice")
                    .font(.custom("Outfit", size: 12))
                    .frame(width: 60, alignment: .leading)
                Picker("", selection: $selectedVoice) {
                    ForEach(Self.voices, id: \.id) { voice in
                        Text(voice.label).tag(voice.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
            .onChange(of: selectedVoice) { _, newValue in
                try? newValue.write(to: Paths.ttsVoice, atomically: true, encoding: .utf8)
            }

            Divider().opacity(0.4)

            // Push-to-Talk
            SectionHeader(title: "Push-to-Talk", icon: "mic.fill")

            if !dictationManager.recorder.micPermission {
                Button(action: { dictationManager.recorder.openMicSettings() }) {
                    Label("Grant Microphone Access", systemImage: "mic.slash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(MenuBarRowButtonStyle())
                Text("Required for built-in dictation")
                    .font(.custom("Outfit", size: 10))
                    .foregroundColor(.orange)
                    .padding(.leading, 2)
            } else {
                HStack(spacing: 6) {
                    Circle()
                        .fill(dictationManager.recorderState == .recording ? Color.red :
                              dictationManager.recorderState == .uploading ? Color.orange : Color.green)
                        .frame(width: 8, height: 8)
                    Text(dictationManager.recorderState == .recording ? "Recording..." :
                         dictationManager.recorderState == .uploading ? "Transcribing..." : "Standby")
                        .font(.custom("Outfit", size: 12))
                    Spacer()
                    Text("Ctrl to toggle")
                        .font(.custom("Outfit", size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 2)

                if let err = dictationManager.error {
                    Text(err)
                        .font(.custom("Outfit", size: 10))
                        .foregroundColor(.red)
                        .padding(.leading, 2)
                        .lineLimit(2)
                }
            }

            Divider().opacity(0.4)

            // Claude setup
            SectionHeader(title: "Claude Setup", icon: "hammer")

            HStack(spacing: 6) {
                Button(action: { ConfigManager.showClaudeSettingsInstructions() }) {
                    Label("Hook", systemImage: "gearshape")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(MenuBarRowButtonStyle())

                Button(action: {
                    let result = ConfigManager.applyHookToSettings()
                    hookApplied = result.success
                    applyMessage = result.message
                    refreshDiagnostics()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { applyMessage = "" }
                }) {
                    Label(hookApplied ? "Applied" : "Auto-Apply", systemImage: hookApplied ? "checkmark.circle.fill" : "bolt.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(MenuBarRowButtonStyle())
                .help("Writes the TTS hook into ~/.claude/settings.json")
            }

            HStack(spacing: 6) {
                Button(action: { ConfigManager.showClaudeMdInstructions() }) {
                    Label("Voice Tag", systemImage: "doc.text")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(MenuBarRowButtonStyle())

                Button(action: {
                    let result = ConfigManager.applyClaudeMd()
                    claudeMdApplied = result.success
                    applyMessage = result.message
                    refreshDiagnostics()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { applyMessage = "" }
                }) {
                    Label(claudeMdApplied ? "Applied" : "Auto-Apply", systemImage: claudeMdApplied ? "checkmark.circle.fill" : "bolt.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(MenuBarRowButtonStyle())
                .help("Appends VOICE tag instructions to ~/.claude/CLAUDE.md")
            }

            if !applyMessage.isEmpty {
                Text(applyMessage)
                    .font(.custom("Outfit", size: 10))
                    .foregroundColor(applyMessage.contains("failed") || applyMessage.contains("Failed") ? .red : .green)
                    .transition(.opacity)
            }

            // Diagnostics checklist
            VStack(alignment: .leading, spacing: 2) {
                DiagnosticRow(label: "Hook configured", ok: hookApplied)
                DiagnosticRow(label: "Voice tag active", ok: claudeMdApplied)
                DiagnosticRow(label: "Server reachable", ok: serverReachable)
            }
            .padding(.leading, 2)

            Divider().opacity(0.4)

            // Logs
            SectionHeader(title: "Logs", icon: "doc.text.magnifyingglass")

            HStack(spacing: 6) {
                Button(action: { ConfigManager.showLog(name: "Server", url: Paths.serverLog) }) {
                    Label("Server Log", systemImage: "doc.text")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(MenuBarRowButtonStyle())

                Button(action: { ConfigManager.showLog(name: "Events", url: Paths.appSupport.appendingPathComponent("paste_debug.log")) }) {
                    Label("Events Log", systemImage: "list.bullet.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(MenuBarRowButtonStyle())
            }

            HStack(spacing: 6) {
                Button(action: {
                    let count = ConfigManager.cleanTempFiles()
                    cleanMessage = "Cleaned \(count) file\(count == 1 ? "" : "s")"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { cleanMessage = "" }
                }) {
                    Label("Clean Temp", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(MenuBarRowButtonStyle())
                .help("Remove stale TTS temp files, locks, and PID files")
            }

            if !cleanMessage.isEmpty {
                Text(cleanMessage)
                    .font(.custom("Outfit", size: 10))
                    .foregroundColor(.green)
                    .transition(.opacity)
            }

            Toggle("Transcription Overlay", isOn: Binding(
                get: { overlay.isVisible },
                set: { enabled in
                    if enabled {
                        overlay.show()
                    } else {
                        overlay.hide()
                    }
                }
            ))
                .font(.custom("Outfit", size: 11))
                .toggleStyle(.checkbox)

            Divider().opacity(0.4)

            // Server controls
            let serverStopped = serverManager.status == .stopped
            HStack(spacing: 6) {
                if serverStopped || serverManager.status == .error {
                    Button(action: { serverManager.startAll() }) {
                        Label("Start Server", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(MenuBarButtonStyle())

                    if serverManager.status == .error {
                        Button(action: { serverManager.restartAll() }) {
                            Label("Restart", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(MenuBarButtonStyle())
                    }
                } else {
                    Button(action: {
                        serverManager.stopAll()
                        showStoppedBanner = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            showStoppedBanner = false
                        }
                    }) {
                        Label("Stop", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(MenuBarButtonStyle())

                    Button(action: { serverManager.restartAll() }) {
                        Label("Restart", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(MenuBarButtonStyle())
                }
            }

            if showStoppedBanner {
                Text("Server stopped")
                    .font(.custom("Outfit", size: 11))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .transition(.opacity)
            }

            Divider().opacity(0.4)

            HStack {
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                    .font(.custom("Outfit", size: 10))
                    .foregroundStyle(.tertiary)

                Spacer()

                Button(action: { NSApplication.shared.terminate(nil) }) {
                    Label("Quit", systemImage: "power")
                        .font(.custom("Outfit", size: 12))
                }
                .buttonStyle(MenuBarRowButtonStyle())
                .keyboardShortcut("q")
            }
        }
        .font(.custom("Outfit", size: 13))
        .padding(16)
        .frame(width: 260)
        .onAppear {
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
            if let savedVoice = try? String(contentsOf: Paths.ttsVoice, encoding: .utf8),
               !savedVoice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let voice = savedVoice.trimmingCharacters(in: .whitespacesAndNewlines)
                if Self.voices.contains(where: { $0.id == voice }) {
                    selectedVoice = voice
                }
            }
            if let savedLang = try? String(contentsOf: Paths.sttLanguage, encoding: .utf8),
               !savedLang.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let lang = savedLang.trimmingCharacters(in: .whitespacesAndNewlines)
                if Self.languages.contains(where: { $0.id == lang }) {
                    selectedLanguage = lang
                }
            }
            dictationManager.updatePort(serverManager.port)
            refreshDiagnostics()
        }
    }

    private func refreshDiagnostics() {
        hookApplied = ConfigManager.checkHookConfigured()
        claudeMdApplied = ConfigManager.checkClaudeMdConfigured()
        ConfigManager.testTTS(port: serverManager.port) { ok in
            DispatchQueue.main.async { serverReachable = ok }
        }
    }

    private func saveFocusApp() {
        guard autoFocusEnabled, !focusAppName.isEmpty else { return }
        try? focusAppName.write(to: Paths.autoFocusApp, atomically: true, encoding: .utf8)
    }

    private func debouncedSaveFocusApp() {
        saveDebounce?.cancel()
        let work = DispatchWorkItem { saveFocusApp() }
        saveDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}

// MARK: - Section Header

struct SectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(title)
                .font(.custom("Outfit", size: 11).weight(.medium))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Button Styles

struct MenuBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom("Outfit", size: 12).weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.15 : 0.08))
            )
            .foregroundColor(.primary)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct MenuBarRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom("Outfit", size: 12))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.04))
            )
            .contentShape(RoundedRectangle(cornerRadius: 5))
            .foregroundColor(.primary)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Port Field

struct PortField: View {
    let label: String
    @Binding var port: Int
    var disabled: Bool = false
    @State private var text: String = ""

    private var isValid: Bool {
        guard let p = Int(text) else { return false }
        return p >= 1024 && p <= 65535
    }

    var body: some View {
        HStack {
            Text(label)
                .font(.custom("Outfit", size: 12))
                .frame(minWidth: 60, alignment: .leading)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .disabled(disabled)
                .opacity(disabled ? 0.5 : 1.0)
                .foregroundColor(isValid || text.isEmpty ? .primary : .red)
                .onAppear { text = "\(port)" }
                .onChange(of: text) { _, newValue in
                    if let p = Int(newValue), p >= 1024, p <= 65535 {
                        port = p
                    }
                }
                .onChange(of: port) { _, newPort in
                    let portStr = "\(newPort)"
                    if text != portStr { text = portStr }
                }
        }
    }
}

// MARK: - Diagnostic Row

struct DiagnosticRow: View {
    let label: String
    let ok: Bool
    var notInstalled: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: notInstalled ? "minus.circle" : (ok ? "checkmark.circle.fill" : "xmark.circle"))
                .font(.system(size: 9))
                .foregroundColor(notInstalled ? .secondary : (ok ? .green : .secondary))
            Text(notInstalled ? "\(label) (not installed)" : label)
                .font(.custom("Outfit", size: 10))
                .foregroundColor(notInstalled ? .secondary : (ok ? .primary : .secondary))
        }
    }
}

// MARK: - Status Row

struct StatusRow: View {
    let label: String
    let subtitle: String
    let port: String
    let status: ServerManager.ServerStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .shadow(color: statusColor.opacity(0.4), radius: status == .running ? 2 : 0)
            Text(label)
                .font(.custom("Outfit", size: 13))
            Text(subtitle)
                .font(.custom("Outfit", size: 9))
                .foregroundStyle(.tertiary)
            Spacer()
            Text(":\(port)")
                .font(.custom("Outfit", size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 1)
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
