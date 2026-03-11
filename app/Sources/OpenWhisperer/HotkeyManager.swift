import AppKit
import Combine

/// Which modifier key triggers push-to-talk.
enum PTTKey: String, CaseIterable {
    case fn = "fn"
    case ctrl = "ctrl"
    case option = "option"
    case cmd = "cmd"

    var label: String {
        switch self {
        case .fn: return "fn"
        case .ctrl: return "Ctrl"
        case .option: return "Option"
        case .cmd: return "Cmd"
        }
    }

    var modifierFlag: NSEvent.ModifierFlags {
        switch self {
        case .fn: return .function
        case .ctrl: return .control
        case .option: return .option
        case .cmd: return .command
        }
    }
}

/// Manages a global modifier-key toggle hotkey for push-to-talk dictation.
/// Detects solo modifier taps (press+release without any other key in between)
/// to avoid conflicts with key combos like Ctrl+C.
class HotkeyManager {
    var onToggle: (() -> Void)?

    /// Called the moment the hotkey is pressed down (before release).
    /// Used to capture the frontmost app PID before any focus shifts occur.
    var onKeyDown: (() -> Void)?

    /// Called on key release (separate from onToggle).
    /// Used by hold-to-talk mode to stop recording on release.
    var onKeyUp: (() -> Void)?

    var pttKey: PTTKey = .ctrl {
        didSet {
            if pttKey != oldValue {
                keyDown = false
                wasCombo = false
            }
        }
    }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    /// Accessed only on main thread — global monitor dispatches to main.
    private var keyDown = false
    private var wasCombo = false

    func start() {
        // Global monitor: catches events when our app is NOT focused.
        // Global monitors deliver on a private AppKit thread, so we dispatch to main.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.flagsChanged, .keyDown]
        ) { [weak self] event in
            DispatchQueue.main.async {
                self?.handleEvent(event)
            }
        }

        // Local monitor: catches events when our app IS focused.
        // Dispatch to main for consistency with global monitor (M-5).
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown]
        ) { [weak self] event in
            DispatchQueue.main.async { self?.handleEvent(event) }
            return event
        }
    }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }

    /// Must be called on main thread (global monitor dispatches here).
    private func handleEvent(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            let pressed = event.modifierFlags.contains(pttKey.modifierFlag)
            if pressed && !keyDown {
                keyDown = true
                wasCombo = false
                onKeyDown?()
            } else if !pressed && keyDown {
                keyDown = false
                if !wasCombo {
                    // Fire onKeyUp first (hold-to-talk uses this to stop recording)
                    onKeyUp?()
                    // onToggle fires second — AppDelegate guards against hold-to-talk (L-3)
                    onToggle?()
                }
            }

        case .keyDown:
            if keyDown {
                wasCombo = true
            }

        default:
            break
        }
    }

    deinit {
        stop()
    }
}
