import AppKit
import Carbon.HIToolbox

/// Registers the global Option-T hotkey via Carbon's RegisterEventHotKey,
/// which works system-wide without accessibility permissions.
@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()
    private var hotKeyRef: EventHotKeyRef?
    private var registered = false

    func register() {
        guard !registered else { return }
        registered = true

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, _ -> OSStatus in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        HotKeyManager.toggleWidget()
                    }
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            nil
        )

        let hotKeyID = EventHotKeyID(signature: OSType(0x4E4D_4254), id: 1) // "NMBT"
        RegisterEventHotKey(
            UInt32(kVK_ANSI_T),
            UInt32(optionKey),
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
    }

    /// Toggles the MenuBarExtra window by clicking our status bar button.
    static func toggleWidget() {
        guard let button = statusButton() else { return }
        NSApp.activate(ignoringOtherApps: true)
        button.performClick(nil)
    }

    private static func statusButton() -> NSStatusBarButton? {
        for window in NSApp.windows where window.className.contains("StatusBar") {
            if let button = findButton(in: window.contentView) {
                return button
            }
        }
        // Fall back to scanning every window.
        for window in NSApp.windows {
            if let button = findButton(in: window.contentView) {
                return button
            }
        }
        return nil
    }

    private static func findButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = findButton(in: subview) { return button }
        }
        return nil
    }
}
