import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Click to record, then press the combination you want.
///
/// Uses a *local* event monitor, which only sees keys while the Settings window is focused — the
/// recorder must not swallow keystrokes from other apps while it's armed.
struct ShortcutRecorder: View {
    let action: ShortcutAction
    @ObservedObject var hotKeys: GlobalHotKeys

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Press keys…" : hotKeys.binding(for: action).display)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(recording ? Color.accentColor : .primary)
                .frame(minWidth: 64)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(recording ? 0.14 : 0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(recording ? Color.accentColor : .clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape abandons recording rather than binding itself.
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
                return nil
            }

            var modifiers = 0
            if event.modifierFlags.contains(.command) { modifiers |= cmdKey }
            if event.modifierFlags.contains(.option) { modifiers |= optionKey }
            if event.modifierFlags.contains(.control) { modifiers |= controlKey }
            if event.modifierFlags.contains(.shift) { modifiers |= shiftKey }

            // A bare key would fire constantly while you type elsewhere; require a modifier.
            guard modifiers != 0 else { return nil }

            hotKeys.setBinding(
                KeyBinding(keyCode: UInt32(event.keyCode), modifiers: modifiers),
                for: action
            )
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
