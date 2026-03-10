import SwiftUI
import ServiceManagement

struct MenuBarView: View {
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var setupManager: SetupManager
    @EnvironmentObject var dictationManager: DictationManager
    @EnvironmentObject var accessibilityManager: AccessibilityManager
    @State private var autoSubmit = false
    @State private var autoFocusEnabled = false
    @State private var focusAppName = ""
    @State private var focusSelection = "Code"  // visual default; only written on explicit toggle
    @State private var customFocusApp = ""
    @State private var saveDebounce: DispatchWorkItem?
    @State private var selectedPTTKey = "ctrl"
    @State private var selectedVoice = "af_heart"
    @State private var selectedLanguage = "en"
    @State private var selectedDetail = "natural"
    @State private var showStoppedBanner = false
    @State private var pttKeyChanged = false
    @State private var selectedPlatform: Platform = .claudeCode
    @State private var hookApplied = false
    @State private var claudeMdApplied = false
    @State private var applyMessage = ""
    @State private var serverReachable = false
    @State private var launchAtLogin = false
    @State private var setupExpanded = false
    @State private var serverExpanded = false
    @State private var logsExpanded = false
    @ObservedObject private var overlay = TranscriptionOverlay.shared

    private static let voices: [(id: String, label: String)] = [
        // English
        ("af_heart", "Heart (English F)"),
        ("af_bella", "Bella (English F)"),
        ("am_michael", "Michael (English M)"),
        // French
        ("ff_siwis", "Siwis (French F)"),
        // Spanish
        ("ef_dora", "Dora (Spanish F)"),
        // Italian
        ("if_sara", "Sara (Italian F)"),
        ("im_nicola", "Nicola (Italian M)"),
        // Portuguese
        ("pf_dora", "Dora (Portuguese F)"),
        // Hindi
        ("hf_alpha", "Alpha (Hindi F)"),
        // Japanese
        ("jf_alpha", "Alpha (Japanese F)"),
        // Chinese
        ("zf_xiaobei", "Xiaobei (Chinese F)"),
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

    private static let detailLevels: [(id: String, label: String)] = [
        ("brief", "Brief"),
        ("natural", "Natural"),
        ("detailed", "Detailed"),
    ]

    private static let focusApps: [(id: String, label: String)] = [
        ("Code", "VS Code"),
        ("Code - Insiders", "VS Code Insiders"),
        ("Cursor", "Cursor (AI Editor)"),
        ("Windsurf", "Windsurf (AI Editor)"),
        ("Zed", "Zed (Editor)"),
        ("Xcode", "Xcode (Apple IDE)"),
        ("Sublime Text", "Sublime Text (Editor)"),
        ("Nova", "Nova (Panic)"),
        ("Fleet", "Fleet (JetBrains)"),
        ("Claude", "Claude (Desktop)"),
        ("Terminal", "Terminal (macOS)"),
        ("iTerm2", "iTerm2 (Terminal)"),
        ("Warp", "Warp (Terminal)"),
        ("Alacritty", "Alacritty (Terminal)"),
        ("Ghostty", "Ghostty (Terminal)"),
        ("CUSTOM", "CUSTOM"),
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
                Toggle("auto-focus", isOn: $autoFocusEnabled)
                    .font(.custom("Outfit", size: 13))
                    .toggleStyle(.checkbox)

                Toggle("auto-submit", isOn: $autoSubmit)
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
                        focusAppName = focusSelection == "CUSTOM" ? customFocusApp : focusSelection
                    }
                    saveFocusApp()
                } else {
                    try? FileManager.default.removeItem(at: Paths.autoFocusApp)
                }
            }


            if autoFocusEnabled {
                Picker("", selection: $focusSelection) {
                    ForEach(Self.focusApps, id: \.id) { app in
                        Text(app.label).tag(app.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .padding(.leading, 20)
                .onChange(of: focusSelection) { _, newValue in
                    if newValue == "CUSTOM" {
                        focusAppName = customFocusApp
                    } else {
                        focusAppName = newValue
                    }
                    saveFocusApp()
                }

                if focusSelection == "CUSTOM" {
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
                Text("Dictate")
                    .font(.custom("Outfit", size: 11))
                    .frame(width: 50, alignment: .leading)
                Picker("", selection: $selectedLanguage) {
                    ForEach(Self.languages, id: \.id) { lang in
                        Text(lang.label).tag(lang.id)
                    }
                }
                .labelsHidden()
                .font(.custom("Outfit", size: 11))
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
                    .font(.custom("Outfit", size: 11))
                    .frame(width: 50, alignment: .leading)
                Picker("", selection: $selectedVoice) {
                    ForEach(Self.voices, id: \.id) { voice in
                        Text(voice.label).tag(voice.id)
                    }
                }
                .labelsHidden()
                .font(.custom("Outfit", size: 11))
                .frame(maxWidth: .infinity)
            }
            .onChange(of: selectedVoice) { _, newValue in
                try? newValue.write(to: Paths.ttsVoice, atomically: true, encoding: .utf8)
            }

            HStack {
                Text("Detail")
                    .font(.custom("Outfit", size: 11))
                    .frame(width: 50, alignment: .leading)
                Picker("", selection: $selectedDetail) {
                    ForEach(Self.detailLevels, id: \.id) { level in
                        Text(level.label).tag(level.id)
                    }
                }
                .labelsHidden()
                .font(.custom("Outfit", size: 11))
                .frame(maxWidth: .infinity)
            }
            .onChange(of: selectedDetail) { _, newValue in
                try? newValue.write(to: Paths.voiceDetail, atomically: true, encoding: .utf8)
                // Mark as needing re-apply so the button shows "Auto-Apply" again
                claudeMdApplied = false
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
                    Picker("", selection: $selectedPTTKey) {
                        ForEach(PTTKey.allCases, id: \.rawValue) { key in
                            Text(key.label).tag(key.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 70)
                }
                .padding(.horizontal, 2)
                .onChange(of: selectedPTTKey) { _, newValue in
                    try? newValue.write(to: Paths.pttHotkey, atomically: true, encoding: .utf8)
                    if let key = PTTKey(rawValue: newValue) {
                        TranscriptionOverlay.shared.pttKeyLabel = key.label
                    }
                    pttKeyChanged = true
                }

                if pttKeyChanged {
                    Text("Restart app to apply new hotkey")
                        .font(.custom("Outfit", size: 9))
                        .foregroundColor(.orange)
                        .padding(.leading, 2)
                }

                if let err = dictationManager.error {
                    Text(err)
                        .font(.custom("Outfit", size: 10))
                        .foregroundColor(.red)
                        .padding(.leading, 2)
                        .lineLimit(2)
                }

                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("Transcription Overlay")
                        .font(.custom("Outfit", size: 12))
                    Spacer()
                    Picker("", selection: Binding(
                        get: { overlay.isVisible ? "on" : "off" },
                        set: { newValue in
                            if newValue == "on" { overlay.show() } else { overlay.hide() }
                        }
                    )) {
                        Text("ON").tag("on")
                        Text("OFF").tag("off")
                    }
                    .labelsHidden()
                    .frame(width: 70)
                }
            }

            Divider().opacity(0.4)

            // AI Platform setup
            CollapsibleHeader(title: "Setup", icon: "hammer", expanded: $setupExpanded) {
                Picker("", selection: $selectedPlatform) {
                    ForEach(Platform.allCases, id: \.rawValue) { p in
                        Text(p.label).tag(p)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
                .onChange(of: selectedPlatform) { _, newValue in
                    newValue.save()
                    refreshDiagnostics()
                }
            }

            if setupExpanded {
                HStack(spacing: 6) {
                    Button(action: { ConfigManager.showHookInstructions(for: selectedPlatform) }) {
                        Label("Hook", systemImage: "gearshape")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(MenuBarRowButtonStyle())

                    Button(action: {
                        let result = ConfigManager.applyHook(for: selectedPlatform)
                        hookApplied = result.success
                        applyMessage = result.message
                        refreshDiagnostics()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { applyMessage = "" }
                    }) {
                        Label(hookApplied ? "Applied" : "Auto-Apply", systemImage: hookApplied ? "checkmark.circle.fill" : "bolt.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(MenuBarRowButtonStyle())
                    .help(selectedPlatform == .claudeCode
                        ? "Writes the TTS hook into ~/.claude/settings.json"
                        : "Writes the notify hook into ~/.codex/config.toml")
                }

                HStack(spacing: 6) {
                    Button(action: { ConfigManager.showVoiceTagInstructions(for: selectedPlatform) }) {
                        Label("Voice Tag", systemImage: "doc.text")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(MenuBarRowButtonStyle())

                    Button(action: {
                        let result = ConfigManager.applyVoiceTag(for: selectedPlatform, forceUpdate: !claudeMdApplied)
                        claudeMdApplied = result.success
                        applyMessage = result.message
                        refreshDiagnostics()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { applyMessage = "" }
                    }) {
                        Label(claudeMdApplied ? "Applied" : "Auto-Apply", systemImage: claudeMdApplied ? "checkmark.circle.fill" : "bolt.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(MenuBarRowButtonStyle())
                    .help(selectedPlatform == .claudeCode
                        ? "Appends VOICE tag instructions to ~/.claude/CLAUDE.md"
                        : "Appends VOICE tag instructions to ~/.codex/instructions.md")
                }

                if !applyMessage.isEmpty {
                    Text(applyMessage)
                        .font(.custom("Outfit", size: 10))
                        .foregroundColor(applyMessage.contains("failed") || applyMessage.contains("Failed") ? .red : .green)
                        .transition(.opacity)
                }

                VStack(alignment: .leading, spacing: 2) {
                    DiagnosticRow(label: "Hook configured", ok: hookApplied)
                    DiagnosticRow(label: "Voice tag active", ok: claudeMdApplied)
                }
                .padding(.leading, 2)
            }

            Divider().opacity(0.4)

            // Server controls
            CollapsibleHeader(title: "Server Config", icon: "gearshape", expanded: $serverExpanded)

            if serverExpanded {
                let serverStopped = serverManager.status == .stopped

                HStack(spacing: 6) {
                    if serverStopped || serverManager.status == .error {
                        Button(action: { serverManager.startAll() }) {
                            Label("Start Server", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(MenuBarRowButtonStyle())
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
                        .buttonStyle(MenuBarRowButtonStyle())
                    }

                    PortField(label: "", port: $serverManager.port, disabled: !serverStopped)
                }

                if showStoppedBanner {
                    Text("Server stopped")
                        .font(.custom("Outfit", size: 11))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .transition(.opacity)
                }

                DiagnosticRow(label: "Server reachable", ok: serverReachable)
                    .padding(.leading, 2)
            }

            Divider().opacity(0.4)

            // Logs
            CollapsibleHeader(title: "Logs", icon: "doc.text.magnifyingglass", expanded: $logsExpanded)

            if logsExpanded {
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
            }

            Divider().opacity(0.4)

            DiagnosticRow(label: accessibilityManager.isGranted ? "Accessibility granted" : "Accessibility not granted", ok: accessibilityManager.isGranted)
                .padding(.leading, 2)
                .contentShape(Rectangle())
                .onTapGesture {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }

            DiagnosticRow(label: "Start on startup", ok: launchAtLogin)
                .padding(.leading, 2)
                .contentShape(Rectangle())
                .onTapGesture { launchAtLogin.toggle() }
                .onChange(of: launchAtLogin) { _, enabled in
                    let service = SMAppService.mainApp
                    do {
                        if enabled {
                            try service.register()
                        } else {
                            try service.unregister()
                        }
                    } catch {
                        NSLog("Login item toggle failed: \(error)")
                        DispatchQueue.main.async {
                            launchAtLogin = service.status == .enabled
                        }
                    }
                }

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
            selectedPlatform = Platform.load()
            launchAtLogin = SMAppService.mainApp.status == .enabled
            autoSubmit = FileManager.default.fileExists(atPath: Paths.autoSubmitFlag.path)
            autoFocusEnabled = FileManager.default.fileExists(atPath: Paths.autoFocusApp.path)
            if let saved = try? String(contentsOf: Paths.autoFocusApp, encoding: .utf8),
               !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let name = saved.trimmingCharacters(in: .whitespacesAndNewlines)
                focusAppName = name
                if Self.focusApps.contains(where: { $0.id == name }) {
                    focusSelection = name
                } else {
                    focusSelection = "CUSTOM"
                    customFocusApp = name
                }
            }
            if let savedKey = try? String(contentsOf: Paths.pttHotkey, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               let key = PTTKey(rawValue: savedKey) {
                selectedPTTKey = savedKey
                TranscriptionOverlay.shared.pttKeyLabel = key.label
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
            if let savedDetail = try? String(contentsOf: Paths.voiceDetail, encoding: .utf8),
               !savedDetail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let detail = savedDetail.trimmingCharacters(in: .whitespacesAndNewlines)
                if Self.detailLevels.contains(where: { $0.id == detail }) {
                    selectedDetail = detail
                }
            }
            dictationManager.updatePort(serverManager.port)
            refreshDiagnostics()
        }
    }

    private func refreshDiagnostics() {
        hookApplied = ConfigManager.checkHookConfigured(for: selectedPlatform)
        claudeMdApplied = ConfigManager.checkVoiceTagConfigured(for: selectedPlatform)
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

// MARK: - Collapsible Header

struct CollapsibleHeader<Trailing: View>: View {
    let title: String
    let icon: String
    @Binding var expanded: Bool
    let trailing: Trailing

    init(title: String, icon: String, expanded: Binding<Bool>, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.icon = icon
        self._expanded = expanded
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.15), value: expanded)
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text(title)
                    .font(.custom("Outfit", size: 11).weight(.medium))
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }
            Spacer()
                .contentShape(Rectangle())
                .onTapGesture { expanded.toggle() }
            trailing
        }
    }
}

extension CollapsibleHeader where Trailing == EmptyView {
    init(title: String, icon: String, expanded: Binding<Bool>) {
        self.title = title
        self.icon = icon
        self._expanded = expanded
        self.trailing = EmptyView()
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
            if !label.isEmpty {
                Text(label)
                    .font(.custom("Outfit", size: 12))
                    .frame(minWidth: 60, alignment: .leading)
            }
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
