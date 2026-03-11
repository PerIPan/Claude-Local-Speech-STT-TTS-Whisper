import AppKit
import SwiftUI
import CoreText

class AppDelegate: NSObject, NSApplicationDelegate {
    let serverManager = ServerManager()
    let setupManager = SetupManager()
    let dictationManager = DictationManager()
    let hotkeyManager = HotkeyManager()
    let accessibilityManager = AccessibilityManager()
    private var dictationSetupDone = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prompt for Accessibility permission if not already granted
        accessibilityManager.requestIfNeeded()
        // Clean stale temp/lock/pid files from previous sessions (background, delayed)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            _ = ConfigManager.cleanTempFiles()
        }

        // Register bundled Outfit font
        if let fontURL = Bundle.main.url(forResource: "Outfit-VariableFont_wght", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
        }

        // Hide dock icon (menubar-only app)
        NSApp.setActivationPolicy(.accessory)

        // Start hotkey listener immediately so Ctrl works without opening the menubar first
        setupDictation()

        if setupManager.isSetupComplete {
            serverManager.startAll()
        } else {
            setupManager.runFirstLaunchSetup { [weak self] success in
                guard success else { return }
                // startAll must run on main thread (BUG-11: timer + process management)
                DispatchQueue.main.async {
                    self?.serverManager.startAll()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        ConfigManager.showClaudeSettingsInstructions()
                    }
                }
            }
        }
    }

    func setupDictation() {
        // Bug 4: guard against duplicate calls from onAppear
        guard !dictationSetupDone else { return }
        dictationSetupDone = true

        // Load saved hotkey preference
        if let saved = try? String(contentsOf: Paths.pttHotkey, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let key = PTTKey(rawValue: saved) {
            hotkeyManager.pttKey = key
            TranscriptionOverlay.shared.pttKeyLabel = key.label
        }

        // Load saved interaction mode
        dictationManager.interactionMode = InteractionMode.load()
        TranscriptionOverlay.shared.interactionMode = dictationManager.interactionMode

        // Capture the frontmost app PID at the moment the hotkey is pressed down,
        // before recording UI or any window can steal focus away.
        hotkeyManager.onKeyDown = { [weak self] in
            guard let self else { return }
            self.dictationManager.captureTargetApp()
            // Hold-to-talk: start recording on key down
            if self.dictationManager.interactionMode == .holdToTalk {
                self.dictationManager.holdToTalkDown()
            }
        }
        hotkeyManager.onKeyUp = { [weak self] in
            guard let self else { return }
            // Hold-to-talk: stop recording on key up
            if self.dictationManager.interactionMode == .holdToTalk {
                self.dictationManager.holdToTalkUp()
            }
        }
        hotkeyManager.onToggle = { [weak self] in
            guard let self else { return }
            // Press-to-talk and hands-free use toggle
            if self.dictationManager.interactionMode != .holdToTalk {
                self.dictationManager.toggle()
            }
        }
        hotkeyManager.start()

        TranscriptionOverlay.shared.dictationManager = dictationManager

        // Show transcription overlay by default on launch
        TranscriptionOverlay.shared.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager.stop()
        serverManager.stopAll(synchronous: true)
        _ = ConfigManager.cleanTempFiles()
    }
}
