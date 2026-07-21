import SwiftUI
import UniformTypeIdentifiers

struct SoundPane: View {
    @EnvironmentObject private var prefs: Preferences
    @State private var customSounds = CustomSounds.installed()

    private let sessionEvents: [SoundEvent] = [.sessionStart, .taskComplete, .taskError]
    private let interactionEvents: [SoundEvent] = [.approvalNeeded, .taskAcknowledge]
    private let systemEvents: [SoundEvent] = [.contextLimit, .idleReminder, .spamDetection]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup {
                SettingsToggleRow(title: "Enable sound effects", isOn: $prefs.soundEnabled)
                SettingsSliderRow(
                    title: "Volume",
                    value: $prefs.soundVolume,
                    range: 0 ... 1,
                    step: 0.05
                ) { "\(Int($0 * 100))%" }
            }

            SettingsGroup(title: "Session") { eventRows(sessionEvents) }
            SettingsGroup(title: "Interactions") { eventRows(interactionEvents) }
            SettingsGroup(title: "System") { eventRows(systemEvents) }

            SettingsGroup(title: "My sounds") {
                if customSounds.isEmpty {
                    Text("No imported sounds yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(12)
                } else {
                    ForEach(customSounds, id: \.self) { name in
                        SettingsRow(title: name) {
                            Button("Remove") {
                                try? FileManager.default.removeItem(
                                    at: CustomSounds.directory.appendingPathComponent(name)
                                )
                                customSounds = CustomSounds.installed()
                            }
                        }
                    }
                }
                SettingsRow(title: "Add sound…", subtitle: "WAV, MP3, or AIFF") {
                    Button("Choose file") { importSound() }
                }
            }

            SettingsGroup(title: "Quiet hours") {
                SettingsToggleRow(
                    title: "Silence during quiet hours",
                    subtitle: "Mutes all sounds during the selected range (crosses midnight if the end is earlier than the start). Useful when agents run overnight.",
                    isOn: $prefs.quietHoursEnabled
                )
                if prefs.quietHoursEnabled {
                    SettingsSliderRow(
                        title: "Start",
                        value: $prefs.quietHoursStart,
                        range: 0 ... 23.5,
                        step: 0.5
                    ) { timeText($0) }
                    SettingsSliderRow(
                        title: "End",
                        value: $prefs.quietHoursEnd,
                        range: 0 ... 23.5,
                        step: 0.5
                    ) { timeText($0) }
                }
            }

        }
    }

    @ViewBuilder
    private func eventRows(_ events: [SoundEvent]) -> some View {
        ForEach(events) { event in
            SettingsRow(title: event.title, subtitle: event.subtitle) {
                HStack(spacing: 6) {
                    Picker("", selection: binding(for: event)) {
                        Text("Off").tag("off")
                        Divider()
                        ForEach(Chiptune.library.keys.sorted(), id: \.self) { name in
                            Text(name.capitalized).tag(name)
                        }
                        if !customSounds.isEmpty {
                            Divider()
                            ForEach(customSounds, id: \.self) { name in
                                Text(name).tag("custom:\(name)")
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)

                    Button {
                        SoundEngine.shared.preview(soundNamed: binding(for: event).wrappedValue)
                    } label: {
                        Image(systemName: "play.circle")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func binding(for event: SoundEvent) -> Binding<String> {
        Binding(
            get: {
                prefs.soundAssignments[event.rawValue]
                    ?? (event.defaultsToOn ? Chiptune.defaultName(for: event) : "off")
            },
            set: { prefs.soundAssignments[event.rawValue] = $0 }
        )
    }

    private func timeText(_ value: Double) -> String {
        let hour = Int(value)
        let minute = value.truncatingRemainder(dividingBy: 1) >= 0.5 ? 30 : 0
        return String(format: "%02d:%02d", hour, minute)
    }

    private func importSound() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav, .mp3, .aiff]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        CustomSounds.importFile(at: url)
        customSounds = CustomSounds.installed()
    }
}
