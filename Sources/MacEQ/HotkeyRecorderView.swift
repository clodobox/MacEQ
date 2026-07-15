import Carbon.HIToolbox
import SwiftUI

/// Tiny window that records a new global-hotkey binding: while visible, a local
/// key monitor captures the next keystroke that includes at least one of
/// Command/Option/Control and hands it to the controller. Esc cancels.
struct HotkeyRecorderView: View {
    @ObservedObject var controller: EQController
    @Environment(\.dismiss) private var dismiss
    @State private var monitor: Any?

    var body: some View {
        VStack(spacing: 10) {
            Text("Press the new shortcut")
                .font(.headline)
            Text("Current: \(controller.hotkeyDisplay)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Combine at least one of ⌘ ⌥ ⌃ with a key. Esc cancels.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(width: 280)
        .onAppear { startMonitor() }
        .onDisappear { stopMonitor() }
    }

    private func startMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Int(event.keyCode) == kVK_Escape {
                dismiss()
                return nil
            }
            var carbonModifiers: UInt32 = 0
            if event.modifierFlags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
            if event.modifierFlags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
            if event.modifierFlags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
            if event.modifierFlags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
            // Shift alone would shadow normal typing system-wide; require a
            // command/option/control anchor.
            guard carbonModifiers & ~UInt32(shiftKey) != 0 else { return event }
            controller.setHotkey(
                keyCode: UInt32(event.keyCode),
                modifiers: carbonModifiers,
                display: displayString(for: event, carbonModifiers: carbonModifiers)
            )
            dismiss()
            return nil
        }
    }

    private func stopMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    private func displayString(for event: NSEvent, carbonModifiers: UInt32) -> String {
        var display = ""
        if carbonModifiers & UInt32(controlKey) != 0 { display += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { display += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { display += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { display += "⌘" }
        let key = event.charactersIgnoringModifiers?.uppercased() ?? ""
        display += key.isEmpty || key.unicodeScalars.contains(where: { $0.value < 0x20 })
            ? "key \(event.keyCode)"
            : key
        return display
    }
}
