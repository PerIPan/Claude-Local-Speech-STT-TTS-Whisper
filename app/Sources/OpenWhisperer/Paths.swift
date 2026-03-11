import Foundation

enum Paths {
    /// ~/Library/Application Support/OpenWhisperer
    static let appSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("OpenWhisperer")
    }()

    /// Python venv location
    static let venv = appSupport.appendingPathComponent("venv")

    /// Python binary inside venv
    static let python = venv.appendingPathComponent("bin").appendingPathComponent("python")

    /// App Resources directory (safe unwrap)
    private static let resources: URL = {
        Bundle.main.resourceURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources")
    }()

    /// uv binary (bundled in app Resources)
    static let uvBinary = resources.appendingPathComponent("uv")

    /// Unified server script (TTS + STT in one process)
    static let unifiedServer = resources.appendingPathComponent("servers").appendingPathComponent("unified_server.py")

    /// Bundled hook script
    static let ttsHook = resources.appendingPathComponent("hooks").appendingPathComponent("tts-hook.sh")

    /// Bundled speak script
    static let speakScript = resources.appendingPathComponent("scripts").appendingPathComponent("speak.sh")

    /// Setup marker file
    static let setupComplete = appSupport.appendingPathComponent(".setup-complete")

    /// Server PID file (single unified server)
    static let serverPidFile = appSupport.appendingPathComponent("server.pid")

    /// Log file (single unified server)
    static let serverLog = appSupport.appendingPathComponent("server.log")
    static let setupLog = appSupport.appendingPathComponent("setup.log")

    /// Auto-submit flag file (unified_server.py checks this)
    static let autoSubmitFlag = appSupport.appendingPathComponent("auto_submit")

    /// Auto-focus app file (unified_server.py reads target app name from this)
    static let autoFocusApp = appSupport.appendingPathComponent("auto_focus_app")

    /// Auto-focus "with return" flag — return to origin app after text insertion
    static let autoFocusReturn = appSupport.appendingPathComponent("auto_focus_return")

    /// STT language file (unified_server.py reads default language from this)
    static let sttLanguage = appSupport.appendingPathComponent("stt_language")

    /// TTS voice file (tts-hook.sh reads voice name from this)
    static let ttsVoice = appSupport.appendingPathComponent("tts_voice")

    /// Voice detail level file (controls VOICE tag verbosity in CLAUDE.md)
    static let voiceDetail = appSupport.appendingPathComponent("voice_detail")

    /// Push-to-talk hotkey preference (ctrl, option, cmd, fn)
    static let pttHotkey = appSupport.appendingPathComponent("ptt_hotkey")

    /// Interaction mode preference (pressToTalk, holdToTalk, handsFree)
    static let interactionMode = appSupport.appendingPathComponent("interaction_mode")

    /// Silence threshold for hands-free mode (seconds, default 3)
    static let silenceThreshold = appSupport.appendingPathComponent("silence_threshold")

    /// TTS volume file (tts-hook.sh reads volume level from this)
    static let ttsVolume = appSupport.appendingPathComponent("tts_volume")

    /// Card expanded states (persisted so user's collapse/expand survives restarts)
    static let setupCardExpanded = appSupport.appendingPathComponent("setup_expanded")
    static let voiceSettingsCardExpanded = appSupport.appendingPathComponent("voice_settings_expanded")
    static let serverCardExpanded = appSupport.appendingPathComponent("server_expanded")

    /// Selected AI platform (claudeCode, codexCLI)
    static let selectedPlatform = appSupport.appendingPathComponent("selected_platform")

    /// Claude Code settings
    static let claudeSettings: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude").appendingPathComponent("settings.json")
    }()

    /// Codex CLI config (~/.codex/config.toml)
    static let codexConfig: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex").appendingPathComponent("config.toml")
    }()

    /// Codex TTS hook (bundled in app Resources)
    static let codexTtsHook = resources.appendingPathComponent("hooks").appendingPathComponent("codex-tts-hook.sh")

    /// Ensure directories exist
    static func ensureDirectories() {
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
    }
}
