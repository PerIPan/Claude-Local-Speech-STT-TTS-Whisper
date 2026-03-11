import SwiftUI
import ServiceManagement

// MARK: - Design Tokens

private enum OWColor {
    /// Card background — translucent to let vibrancy show through
    static let cardBackground = Color(nsColor: .controlBackgroundColor).opacity(0.35)
    /// Section label / secondary text
    static let muted = Color.secondary
    /// Thin separator line
    static let divider = Color.primary.opacity(0.08)
    /// Accent — gray for interactive states (pickers, checkboxes)
    static let accent = Color.gray
    /// Inline tag pill background
    static let pillBackground = Color.primary.opacity(0.06)
}

private enum OWFont {
    static func title(_ size: CGFloat = 15) -> Font {
        .custom("Outfit", size: size).weight(.semibold)
    }
    static func sectionLabel(_ size: CGFloat = 11) -> Font {
        .custom("Outfit", size: size).weight(.semibold)
    }
    static func body(_ size: CGFloat = 13) -> Font {
        .custom("Outfit", size: size)
    }
    static func caption(_ size: CGFloat = 10) -> Font {
        .custom("Outfit", size: size)
    }
    static func mono(_ size: CGFloat = 11) -> Font {
        .custom("Outfit", size: size).monospaced()
    }
}

// MARK: - MenuBarView

struct MenuBarView: View {
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var setupManager: SetupManager
    @EnvironmentObject var dictationManager: DictationManager
    @EnvironmentObject var accessibilityManager: AccessibilityManager
    @State private var autoSubmit = false
    @State private var autoFocusEnabled = false
    @State private var autoFocusReturn = false
    @State private var focusAppName = ""
    @State private var focusSelection = "Code"  // visual default; only written on explicit toggle
    @State private var customFocusApp = ""
    @State private var saveDebounce: DispatchWorkItem?
    @State private var selectedPTTKey = "ctrl"
    @State private var selectedMode: InteractionMode = .holdToTalk
    @State private var silenceThreshold: Int = 3
    @State private var selectedVolume = "medium"
    @State private var selectedVoice = "af_heart"
    @State private var selectedLanguage = "en"
    @State private var selectedDetail = "natural"
    @State private var showStoppedBanner = false
    @State private var pttKeyChanged = false
    @State private var selectedPlatform: Platform = .claudeCode
    @State private var hookApplied = false
    @State private var claudeMdApplied = false
    @State private var superpowersApplied = false
    @State private var applyMessage = ""
    @State private var serverReachable = false
    @State private var launchAtLogin = false
    @State private var voiceSettingsExpanded = FileManager.default.fileExists(atPath: Paths.voiceSettingsCardExpanded.path)
    @State private var setupExpanded = !FileManager.default.fileExists(atPath: Paths.setupCardExpanded.path)
    @State private var serverExpanded = FileManager.default.fileExists(atPath: Paths.serverCardExpanded.path)
    // logsExpanded removed — merged into serverExpanded
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
        ("brainstorming", "Brainstorming"),
    ]

    private static let volumeLevels: [(id: String, label: String, value: String)] = [
        ("low", "Low", "0.3"),
        ("medium", "Medium", "1"),
        ("high", "High", "4"),
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

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
                .padding(.bottom, 12)

            setupProgressSection

            serverStatusCard
                .padding(.bottom, 8)

            voiceInputCard
                .padding(.bottom, 8)

            voiceSettingsCard
                .padding(.bottom, 8)

            automationCard
                .padding(.bottom, 8)

            setupCard
                .padding(.bottom, 8)

            serverCard
                .padding(.bottom, 8)

            footerSection
        }
        .padding(14)
        .font(OWFont.body())
        .frame(width: 310)
        // Native AppKit controls replaced with custom OWMenuPicker/OWCheckbox
        .background(.ultraThinMaterial)
        .onAppear {
            selectedPlatform = Platform.load()
            launchAtLogin = SMAppService.mainApp.status == .enabled
            autoSubmit = FileManager.default.fileExists(atPath: Paths.autoSubmitFlag.path)
            autoFocusEnabled = FileManager.default.fileExists(atPath: Paths.autoFocusApp.path)
            autoFocusReturn = FileManager.default.fileExists(atPath: Paths.autoFocusReturn.path)
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
            if let savedVolume = try? String(contentsOf: Paths.ttsVolume, encoding: .utf8),
               !savedVolume.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let val = savedVolume.trimmingCharacters(in: .whitespacesAndNewlines)
                if let match = Self.volumeLevels.first(where: { $0.value == val }) {
                    selectedVolume = match.id
                }
            }
            dictationManager.updatePort(serverManager.port)
            selectedMode = InteractionMode.load()
            if let savedStr = try? String(contentsOf: Paths.silenceThreshold, encoding: .utf8),
               let saved = Int(savedStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
                silenceThreshold = saved
            }
            refreshDiagnostics()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 10) {
            if let appIcon = NSApp.applicationIconImage {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            Text("Open Whisperer")
                .font(OWFont.title(15))
            Spacer()
        }
    }

    // MARK: - Setup Progress (conditional)

    @ViewBuilder
    private var setupProgressSection: some View {
        if case .inProgress(let step) = setupManager.state {
            OWCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text(step)
                        .font(OWFont.caption())
                        .foregroundColor(.secondary)
                    ProgressView(value: setupManager.progress)
                        .progressViewStyle(.linear)
                        .tint(OWColor.accent)
                }
            }
            .padding(.bottom, 8)
        } else if case .failed(let reason) = setupManager.state {
            OWCard {
                VStack(alignment: .leading, spacing: 8) {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(OWFont.caption())
                        .foregroundColor(.red)
                    Button("Retry Setup") {
                        setupManager.resetAndRerun { success in
                            guard success else { return }
                            DispatchQueue.main.async { serverManager.startAll() }
                        }
                    }
                    .buttonStyle(OWPrimaryButtonStyle())
                }
            }
            .padding(.bottom, 8)
        }
    }

    // MARK: - Server Status Card

    private var serverStatusCard: some View {
        OWCard {
            VStack(spacing: 0) {
                ModernStatusRow(
                    label: "Whisper Speech-to-Text",
                    subtitle: serverManager.sttModel,
                    port: "\(serverManager.port)",
                    status: serverManager.status
                )
                OWInternalDivider()
                ModernStatusRow(
                    label: "Kokoro Text-to-Speech",
                    subtitle: serverManager.ttsModel,
                    port: "\(serverManager.port)",
                    status: serverManager.status
                )
            }
        }
    }

    // MARK: - Voice Input Card

    private var voiceInputCard: some View {
        OWCard {
            VStack(alignment: .leading, spacing: 10) {
                OWCardHeader(title: "Voice Input", icon: "mic.fill")

                // Mode dropdown
                OWPickerRow(label: "Mode", labelWidth: 52) {
                    OWMenuPicker(
                        selection: $selectedMode,
                        options: InteractionMode.allCases.map { (id: $0, label: $0.label) }
                    )
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: selectedMode) { _, newValue in
                    newValue.save()
                    dictationManager.interactionMode = newValue
                }

                // Mode description hint
                Text(selectedMode.description)
                    .font(OWFont.caption(10))
                    .foregroundColor(.secondary)

                if !dictationManager.recorder.micPermission {
                    OWInternalDivider()

                    Button(action: { dictationManager.recorder.openMicSettings() }) {
                        Label("Grant Microphone Access", systemImage: "mic.slash")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(OWRowButtonStyle())

                    Text("Required for built-in dictation")
                        .font(OWFont.caption())
                        .foregroundColor(.orange)
                } else {
                    OWInternalDivider()

                    // Recording state + PTT key — aligned icon column
                    HStack(spacing: 8) {
                        Circle()
                            .fill(stateColor)
                            .frame(width: 7, height: 7)
                            .shadow(color: stateColor.opacity(0.5), radius: stateColor == .green || stateColor == .red ? 3 : 0)
                            .frame(width: 16)
                        Text(stateLabel)
                            .font(OWFont.body(12))
                            .foregroundColor(.primary)

                        Spacer()

                        if selectedMode != .handsFree {
                            OWMenuPicker(
                                selection: $selectedPTTKey,
                                options: PTTKey.allCases.map { (id: $0.rawValue, label: $0.label) }
                            )
                            .frame(width: 76)
                        }
                    }
                    .onChange(of: selectedPTTKey) { _, newValue in
                        try? newValue.write(to: Paths.pttHotkey, atomically: true, encoding: .utf8)
                        if let key = PTTKey(rawValue: newValue) {
                            TranscriptionOverlay.shared.pttKeyLabel = key.label
                        }
                        pttKeyChanged = true
                    }

                    // Hands-free: silence threshold
                    if selectedMode == .handsFree {
                        HStack(spacing: 8) {
                            Image(systemName: "speaker.slash")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .frame(width: 16)
                            Text("Silence")
                                .font(OWFont.body(12))
                            Spacer()
                            OWMenuPicker(
                                selection: $silenceThreshold,
                                options: [3, 4, 5, 7, 10, 20].map { (id: $0, label: "\($0)s") }
                            )
                            .frame(width: 76)
                            .onChange(of: silenceThreshold) { _, newValue in
                                let str = String(newValue)
                                try? str.write(to: Paths.silenceThreshold, atomically: true, encoding: .utf8)
                                dictationManager.recorder.silenceThresholdSeconds = TimeInterval(newValue)
                            }
                        }

                        if dictationManager.isCalibrating {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Calibrating microphone...")
                                    .font(OWFont.caption())
                                    .foregroundColor(.orange)
                            }
                        }

                        if dictationManager.ttsPlaying {
                            HStack(spacing: 6) {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(.blue)
                                Text("say \"hold on\" to interrupt TTS")
                                    .font(OWFont.caption())
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    // Overlay toggle — aligned icon column
                    HStack(spacing: 8) {
                        Image(systemName: "waveform")
                            .font(.system(size: 11))
                            .foregroundColor(overlay.isVisible ? .green : .secondary)
                            .frame(width: 16)
                        Text("Transcription Overlay")
                            .font(OWFont.body(12))
                        Spacer()
                        OWMenuPicker(
                            selection: Binding(
                                get: { overlay.isVisible ? "on" : "off" },
                                set: { newValue in
                                    if newValue == "on" { overlay.show() } else { overlay.hide() }
                                }
                            ),
                            options: [(id: "on", label: "ON"), (id: "off", label: "OFF")]
                        )
                        .frame(width: 76)
                    }

                    // Hotkey-change notice
                    if pttKeyChanged {
                        InlineBadge(text: "Restart app to apply new hotkey", color: .orange)
                    }

                    // Error display
                    if let err = dictationManager.error {
                        InlineBadge(text: err, color: .red)
                    }
                }
            }
        }
    }

    // MARK: - Voice Settings Card

    private var voiceSettingsCard: some View {
        OWCollapsibleCard(
            title: "Voice Settings",
            icon: "slider.horizontal.3",
            expanded: $voiceSettingsExpanded
        ) {
            EmptyView()
        } expandedContent: {
            VStack(alignment: .leading, spacing: 10) {
                OWPickerRow(label: "Dictate", labelWidth: 52) {
                    OWMenuPicker(selection: $selectedLanguage, options: Self.languages)
                        .frame(maxWidth: .infinity)
                }
                .onChange(of: selectedLanguage) { _, newValue in
                    if newValue == "auto" {
                        try? FileManager.default.removeItem(at: Paths.sttLanguage)
                    } else {
                        try? newValue.write(to: Paths.sttLanguage, atomically: true, encoding: .utf8)
                    }
                }

                OWInternalDivider()

                OWPickerRow(label: "Voice", labelWidth: 52) {
                    OWMenuPicker(selection: $selectedVoice, options: Self.voices)
                        .frame(maxWidth: .infinity)
                }
                .onChange(of: selectedVoice) { _, newValue in
                    try? newValue.write(to: Paths.ttsVoice, atomically: true, encoding: .utf8)
                }

                OWInternalDivider()

                OWPickerRow(label: "Detail", labelWidth: 52) {
                    OWMenuPicker(selection: $selectedDetail, options: Self.detailLevels)
                        .frame(maxWidth: .infinity)
                }
                .onChange(of: selectedDetail) { _, newValue in
                    try? newValue.write(to: Paths.voiceDetail, atomically: true, encoding: .utf8)
                    // Auto-apply the new voice block immediately
                    let result = ConfigManager.applyVoiceTag(for: selectedPlatform, forceUpdate: true)
                    claudeMdApplied = result.success
                    applyMessage = result.message
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { applyMessage = "" }
                    setupExpanded = true
                }

                OWInternalDivider()

                OWPickerRow(label: "Volume", labelWidth: 52) {
                    OWMenuPicker(selection: $selectedVolume, options: Self.volumeLevels.map { (id: $0.id, label: $0.label) })
                        .frame(maxWidth: .infinity)
                }
                .onChange(of: selectedVolume) { _, newValue in
                    if let level = Self.volumeLevels.first(where: { $0.id == newValue }) {
                        try? level.value.write(to: Paths.ttsVolume, atomically: true, encoding: .utf8)
                    }
                }

            }
        }
        .onChange(of: voiceSettingsExpanded) { _, newValue in
            if newValue {
                try? "open".write(to: Paths.voiceSettingsCardExpanded, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(at: Paths.voiceSettingsCardExpanded)
            }
        }
    }

    // MARK: - Automation Card

    private var automationCard: some View {
        OWCard {
            VStack(alignment: .leading, spacing: 10) {
                OWCardHeader(title: "Automation", icon: "gearshape.2")

                HStack(spacing: 20) {
                    OWCheckbox(label: "auto-focus", isOn: $autoFocusEnabled)
                    OWCheckbox(label: "auto-submit", isOn: $autoSubmit)
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

                // Auto-focus sub-options
                if autoFocusEnabled {
                    OWInternalDivider()

                    OWMenuPicker(selection: $focusSelection, options: Self.focusApps)
                        .frame(maxWidth: .infinity)
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
                            .font(OWFont.body(12))
                            .onChange(of: customFocusApp) { _, newValue in
                                if !newValue.isEmpty {
                                    focusAppName = newValue
                                    debouncedSaveFocusApp()
                                }
                            }
                    }

                    OWCheckbox(label: "with return", isOn: $autoFocusReturn)
                        .onChange(of: autoFocusReturn) { _, enabled in
                            if enabled {
                                try? "on".write(to: Paths.autoFocusReturn, atomically: true, encoding: .utf8)
                            } else {
                                try? FileManager.default.removeItem(at: Paths.autoFocusReturn)
                            }
                        }

                    Text("focus target app, insert text, return to previous")
                        .font(OWFont.caption())
                        .foregroundColor(.secondary)
                }

                // Auto-submit hint
                if autoSubmit {
                    Text("enter is auto-applied after text insertion")
                        .font(OWFont.caption())
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Setup Card

    private var setupCard: some View {
        OWCollapsibleCard(
            title: "Setup",
            icon: "hammer",
            expanded: $setupExpanded
        ) {
            OWMenuPicker(
                selection: $selectedPlatform,
                options: Platform.allCases.map { (id: $0, label: $0.label) }
            )
            .frame(width: 130)
            .onChange(of: selectedPlatform) { _, newValue in
                newValue.save()
                refreshDiagnostics()
            }
        } expandedContent: {
            VStack(alignment: .leading, spacing: 8) {
                // Hook row — aligned label + info + apply
                HStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Text("Hook")
                            .font(OWFont.body(11))
                        Image(systemName: "info.circle")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .frame(width: 80, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { ConfigManager.showHookInstructions(for: selectedPlatform) }
                    .help("Tap for setup instructions")

                    Button(action: {
                        let result = ConfigManager.applyHook(for: selectedPlatform)
                        hookApplied = result.success
                        applyMessage = result.message
                        refreshDiagnostics()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { applyMessage = "" }
                    }) {
                        Label(
                            hookApplied ? "Applied" : "Auto-Apply",
                            systemImage: hookApplied ? "checkmark.circle.fill" : "bolt.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(OWRowButtonStyle(tinted: hookApplied, urgent: !hookApplied))
                    .help(selectedPlatform == .claudeCode
                        ? "writes the TTS hook into ~/.claude/settings.json"
                        : "writes the notify hook into ~/.codex/config.toml")
                }

                // Voice Tag row — aligned label + info + apply
                HStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Text("Voice Tag")
                            .font(OWFont.body(11))
                        Image(systemName: "info.circle")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .frame(width: 80, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { ConfigManager.showVoiceTagInstructions(for: selectedPlatform) }
                    .help("Tap for setup instructions")

                    Button(action: {
                        let result = ConfigManager.applyVoiceTag(for: selectedPlatform, forceUpdate: !claudeMdApplied)
                        claudeMdApplied = result.success
                        applyMessage = result.message
                        refreshDiagnostics()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { applyMessage = "" }
                    }) {
                        Label(
                            claudeMdApplied ? "Applied" : "Auto-Apply",
                            systemImage: claudeMdApplied ? "checkmark.circle.fill" : "bolt.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(OWRowButtonStyle(tinted: claudeMdApplied, urgent: !claudeMdApplied))
                    .help(selectedPlatform == .claudeCode
                        ? "appends VOICE tag instructions to ~/.claude/CLAUDE.md"
                        : "appends VOICE tag instructions to ~/.codex/instructions.md")
                }

                // Superpowers row — Claude Code only
                if selectedPlatform == .claudeCode {
                    HStack(spacing: 6) {
                        HStack(spacing: 4) {
                            Text("Superpowers")
                                .font(OWFont.body(11))
                            Image(systemName: "info.circle")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .frame(width: 80, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { ConfigManager.showSuperpowersInstructions() }
                        .help("obra/superpowers — agentic skills framework")

                        Button(action: {
                            let result = ConfigManager.applySuperpowers()
                            superpowersApplied = ConfigManager.checkSuperpowersInstalled()
                            applyMessage = result.message
                            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { applyMessage = "" }
                        }) {
                            Label(
                                superpowersApplied ? "Installed" : "Copy Install",
                                systemImage: superpowersApplied ? "checkmark.circle.fill" : "doc.on.clipboard"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(OWRowButtonStyle(tinted: superpowersApplied, urgent: !superpowersApplied))
                        .help("copies install command to clipboard")
                    }
                }

                // Apply message feedback
                if !applyMessage.isEmpty {
                    Text(applyMessage)
                        .font(OWFont.caption())
                        .foregroundColor(
                            applyMessage.lowercased().contains("fail") ? .red : .green
                        )
                        .transition(.opacity)
                }

                // Diagnostics
                VStack(alignment: .leading, spacing: 4) {
                    ModernDiagnosticRow(label: "HOOK configured", ok: hookApplied)
                    ModernDiagnosticRow(label: "VOICE tag active", ok: claudeMdApplied)
                    if selectedPlatform == .claudeCode {
                        ModernDiagnosticRow(label: "superpowers installed", ok: superpowersApplied)
                    }
                }
            }
        }
        .onChange(of: setupExpanded) { _, newValue in
            if newValue {
                try? FileManager.default.removeItem(at: Paths.setupCardExpanded)
            } else {
                try? "closed".write(to: Paths.setupCardExpanded, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: - Server Card

    private var serverCard: some View {
        OWCollapsibleCard(
            title: "Server & Logs",
            icon: "gearshape",
            expanded: $serverExpanded
        ) {
            EmptyView()
        } expandedContent: {
            VStack(alignment: .leading, spacing: 8) {
                let serverStopped = serverManager.status == .stopped

                HStack(spacing: 6) {
                    if serverStopped || serverManager.status == .error {
                        Button(action: { serverManager.startAll() }) {
                            Label("Start Server", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(OWRowButtonStyle())
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
                        .buttonStyle(OWRowButtonStyle())
                    }

                    PortField(label: "", port: $serverManager.port, disabled: !serverStopped)
                }

                if showStoppedBanner {
                    Text("Server stopped")
                        .font(OWFont.body(11))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .transition(.opacity)
                }

                ModernDiagnosticRow(label: "Server reachable", ok: serverReachable)

                OWInternalDivider()

                HStack(spacing: 6) {
                    Button(action: { ConfigManager.showLog(name: "Server", url: Paths.serverLog) }) {
                        Label("Server Log", systemImage: "doc.text")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(OWRowButtonStyle())

                    Button(action: {
                        ConfigManager.showLog(
                            name: "Events",
                            url: Paths.appSupport.appendingPathComponent("paste_debug.log")
                        )
                    }) {
                        Label("Events Log", systemImage: "list.bullet.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(OWRowButtonStyle())
                }
            }
        }
        .onChange(of: serverExpanded) { _, newValue in
            if newValue {
                try? "open".write(to: Paths.serverCardExpanded, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(at: Paths.serverCardExpanded)
            }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        OWCard {
            VStack(alignment: .leading, spacing: 8) {
                // Permissions
                ModernDiagnosticRow(label: "Accessibility", ok: accessibilityManager.isGranted)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                ModernDiagnosticRow(label: "Microphone", ok: dictationManager.recorder.micPermission)
                    .contentShape(Rectangle())
                    .onTapGesture { dictationManager.recorder.openMicSettings() }
                ModernDiagnosticRow(label: "Speech Recognition", ok: dictationManager.keywordDetector.permissionGranted)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
                            NSWorkspace.shared.open(url)
                        }
                    }

                OWInternalDivider()

                // Launch at login
                ModernDiagnosticRow(label: "Start on startup", ok: launchAtLogin)
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

                OWInternalDivider()

                HStack {
                    Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                        .font(OWFont.caption())
                        .foregroundStyle(.tertiary)

                    Spacer()

                    Button(action: { NSApplication.shared.terminate(nil) }) {
                        Label("Quit", systemImage: "power")
                            .font(OWFont.body(12))
                    }
                    .buttonStyle(OWRowButtonStyle())
                    .keyboardShortcut("q")
                }
            }
        }
    }

    // MARK: - Computed helpers

    private var stateColor: Color {
        switch dictationManager.recorderState {
        case .recording: return .red
        case .uploading: return .orange
        case .listening: return .green
        case .idle: return dictationManager.ttsPlaying ? .blue : .green
        }
    }

    private var stateLabel: String {
        if dictationManager.isCalibrating { return "Calibrating..." }
        if dictationManager.ttsPlaying { return "Playing..." }
        switch dictationManager.recorderState {
        case .recording: return "Recording..."
        case .uploading: return "Transcribing..."
        case .listening: return "Listening..."
        case .idle: return "Standby"
        }
    }

    private func refreshDiagnostics() {
        hookApplied = ConfigManager.checkHookConfigured(for: selectedPlatform)
        claudeMdApplied = ConfigManager.checkVoiceTagConfigured(for: selectedPlatform)
        superpowersApplied = ConfigManager.checkSuperpowersInstalled()
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

// MARK: - OWCard (rounded card container)

struct OWCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(OWColor.cardBackground)
                    .shadow(color: Color.black.opacity(0.04), radius: 1, x: 0, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
            )
    }
}

// MARK: - OWCollapsibleCard

struct OWCollapsibleCard<Trailing: View, Expanded: View>: View {
    let title: String
    let icon: String
    @Binding var expanded: Bool
    let trailing: Trailing
    let expandedContent: Expanded

    init(
        title: String,
        icon: String,
        expanded: Binding<Bool>,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder expandedContent: () -> Expanded
    ) {
        self.title = title
        self.icon = icon
        self._expanded = expanded
        self.trailing = trailing()
        self.expandedContent = expandedContent()
    }

    var body: some View {
        OWCard {
            VStack(alignment: .leading, spacing: 0) {
                // Header row — always visible
                HStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.secondary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .animation(.easeInOut(duration: 0.18), value: expanded)

                        Image(systemName: icon)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        Text(title)
                            .font(OWFont.sectionLabel(12))
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation { expanded.toggle() } }

                    Spacer()
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation { expanded.toggle() } }

                    trailing
                }

                // Expanded content
                if expanded {
                    OWInternalDivider()
                        .padding(.top, 10)
                    expandedContent
                        .padding(.top, 8)
                }
            }
        }
    }
}

// MARK: - OWCardHeader

struct OWCardHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
            Text(title)
                .font(OWFont.sectionLabel(11))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - OWPickerRow

struct OWPickerRow<Content: View>: View {
    let label: String
    let labelWidth: CGFloat
    let content: Content

    init(label: String, labelWidth: CGFloat = 60, @ViewBuilder content: () -> Content) {
        self.label = label
        self.labelWidth = labelWidth
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(OWFont.body(11))
                .foregroundColor(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            content
        }
    }
}

// MARK: - OWInternalDivider

struct OWInternalDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 0.5)
    }
}

// MARK: - OWMenuPicker (custom SwiftUI dropdown — avoids dark AppKit NSPopUpButton)

struct OWMenuPicker<T: Hashable>: View {
    @Binding var selection: T
    let options: [(id: T, label: String)]

    var body: some View {
        Menu {
            ForEach(options, id: \.id) { option in
                Button {
                    selection = option.id
                } label: {
                    if option.id == selection {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(currentLabel)
                    .font(OWFont.body(11))
                    .foregroundColor(.primary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(Color.primary.opacity(0.35))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    )
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    private var currentLabel: String {
        options.first(where: { $0.id == selection })?.label ?? ""
    }
}

// MARK: - OWCheckbox (custom SwiftUI checkbox — avoids dark AppKit NSButton)

struct OWCheckbox: View {
    let label: String
    @Binding var isOn: Bool
    var tint: Color = Color.primary.opacity(0.40)

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(isOn ? tint : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(
                                    isOn ? tint : Color.primary.opacity(0.25),
                                    lineWidth: 1
                                )
                        )
                        .frame(width: 13, height: 13)
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .animation(.easeInOut(duration: 0.12), value: isOn)
                Text(label)
                    .font(OWFont.body(12))
                    .foregroundColor(.primary)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - InlineBadge

struct InlineBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(OWFont.caption())
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color.opacity(0.10))
            )
    }
}

// MARK: - ModernStatusRow

struct ModernStatusRow: View {
    let label: String
    let subtitle: String
    let port: String
    let status: ServerManager.ServerStatus

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(dotColor.opacity(0.18))
                    .frame(width: 18, height: 18)
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(OWFont.body(12))
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(OWFont.caption(10))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Text(":\(port)")
                .font(OWFont.mono(10))
                .foregroundColor(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
        }
        .padding(.vertical, 4)
    }

    private var dotColor: Color {
        switch status {
        case .running: return .green
        case .starting: return .orange
        case .error: return .red
        case .stopped: return Color(nsColor: .systemGray)
        }
    }
}

// MARK: - ModernDiagnosticRow

struct ModernDiagnosticRow: View {
    let label: String
    let ok: Bool
    var notInstalled: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 10))
                .foregroundColor(iconColor)

            Text(notInstalled ? "\(label) (not installed)" : label)
                .font(OWFont.body(11))
                .foregroundColor(notInstalled ? .secondary : (ok ? .primary : .secondary))
        }
    }

    private var iconName: String {
        if notInstalled { return "minus.circle" }
        return ok ? "checkmark.circle.fill" : "xmark.circle"
    }

    private var iconColor: Color {
        if notInstalled { return .secondary }
        return ok ? .green : .secondary
    }
}

// MARK: - SectionHeader (kept for backward compatibility)

struct SectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text(title)
                .font(OWFont.sectionLabel())
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - CollapsibleHeader (kept for backward compatibility)

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
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(title)
                    .font(OWFont.sectionLabel())
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

struct OWPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(OWFont.body(12).weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(OWColor.accent.opacity(configuration.isPressed ? 0.85 : 1.0))
            )
            .foregroundColor(.white)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct OWRowButtonStyle: ButtonStyle {
    var tinted: Bool = false
    var urgent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        let color: Color = tinted ? .green : (urgent ? .orange : .primary)
        let bgOpacity = tinted || urgent
            ? (configuration.isPressed ? 0.20 : 0.12)
            : (configuration.isPressed ? 0.12 : 0.05)
        configuration.label
            .font(OWFont.body(11))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(color.opacity(bgOpacity))
            )
            .foregroundColor(color)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Legacy alias so existing call sites that use MenuBarButtonStyle still compile.
typealias MenuBarButtonStyle = OWPrimaryButtonStyle

/// Legacy alias so existing call sites that use MenuBarRowButtonStyle still compile.
typealias MenuBarRowButtonStyle = OWRowButtonStyle

// MARK: - PortField

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
                    .font(OWFont.body(12))
                    .frame(minWidth: 60, alignment: .leading)
            }
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .disabled(disabled)
                .opacity(disabled ? 0.45 : 1.0)
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

// MARK: - DiagnosticRow (legacy alias → ModernDiagnosticRow)

struct DiagnosticRow: View {
    let label: String
    let ok: Bool
    var notInstalled: Bool = false

    var body: some View {
        ModernDiagnosticRow(label: label, ok: ok, notInstalled: notInstalled)
    }
}

// MARK: - StatusRow (legacy alias → ModernStatusRow)

struct StatusRow: View {
    let label: String
    let subtitle: String
    let port: String
    let status: ServerManager.ServerStatus

    var body: some View {
        ModernStatusRow(label: label, subtitle: subtitle, port: port, status: status)
    }
}
