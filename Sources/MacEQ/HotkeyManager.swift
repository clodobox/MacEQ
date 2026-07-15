import Carbon.HIToolbox
import Foundation

/// Registers the global EQ-bypass hotkey via Carbon's RegisterEventHotKey — the
/// only global-hotkey API that works without the Accessibility permission.
/// Interfaces a C API, hence a class.
///
/// The Carbon event handler fires on the main thread (application event target),
/// so `onToggle` is invoked on the main thread.
final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let onToggle: () -> Void

    /// keyCode is a Carbon virtual key (kVK_*); modifiers is a Carbon modifier
    /// mask (cmdKey/optionKey/controlKey/shiftKey).
    init?(keyCode: UInt32, modifiers: UInt32, onToggle: @escaping () -> Void) {
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
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registerStatus == noErr else {
            // Most likely another app owns this combination; the app works
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
