import Carbon.HIToolbox
import Foundation

/// Registers the global EQ-bypass hotkey (Option+Command+E) via Carbon's
/// RegisterEventHotKey — the only global-hotkey API that works without the
/// Accessibility permission. Interfaces a C API, hence a class.
///
/// The Carbon event handler fires on the main thread (application event target),
/// so `onToggle` is invoked on the main thread.
final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let onToggle: () -> Void

    init?(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue().onToggle()
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard handlerStatus == noErr else {
            print("warning: hotkey event handler install failed with OSStatus \(handlerStatus)")
            return nil
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4D45_5131) /* 'MEQ1' */, id: 1)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_E),
            UInt32(optionKey | cmdKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registerStatus == noErr else {
            // Most likely another app owns Option+Command+E; the app works
            // without the hotkey, so this is non-fatal.
            print("warning: hotkey registration failed with OSStatus \(registerStatus)")
            RemoveEventHandler(eventHandler)
            return nil
        }
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }
}
