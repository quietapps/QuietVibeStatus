import SwiftUI

struct NotificationsPane: View {
    @EnvironmentObject private var prefs: Preferences
    @ObservedObject private var notifier = ApprovalNotifier.shared
    @State private var newDirectoryFilter = ""
    @State private var newPromptFilter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "Completion notifications") {
                SettingsToggleRow(
                    title: "Expand the panel for completion notifications",
                    subtitle: "Turn off to keep the panel collapsed and show a subtle glow instead. Approvals and questions still expand automatically.",
                    isOn: $prefs.expandForCompletions
                )
                SettingsRow(
                    title: "Subagent notifications",
                    subtitle: "Choose when completion notifications appear. Approvals and questions always appear immediately."
                ) {
                    Picker("", selection: subagentBinding) {
                        ForEach(SubagentNotificationPolicy.allCases, id: \.self) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
            }

            SettingsGroup(title: "Approval banners") {
                SettingsRow(
                    title: "Notification Center banners",
                    subtitle: "Allow and Deny appear on the banner itself, so a blocked agent reaches you in fullscreen or on another display. Quiet scenes still silence them."
                ) {
                    Picker("", selection: approvalNotificationBinding) {
                        ForEach(ApprovalNotificationPolicy.allCases, id: \.self) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
                if prefs.approvalNotifications != .never, !notifier.isAuthorized {
                    SettingsRow(
                        title: "Notifications are not allowed yet",
                        subtitle: "macOS asks the first time an agent blocks. If you dismissed that prompt, turn Quiet Vibe Status on in System Settings → Notifications."
                    ) {
                        Button("Open System Settings") {
                            let url = URL(
                                string: "x-apple.systempreferences:com.apple.preference.notifications"
                            )
                            if let url { NSWorkspace.shared.open(url) }
                        }
                    }
                }
                SettingsToggleRow(
                    title: "Flag risky commands",
                    subtitle: "Marks approval cards whose command deletes outside the project, pipes a download into a shell, force-pushes, or touches credentials. Advisory only — nothing is blocked.",
                    isOn: $prefs.showRiskWarnings
                )
            }

            SettingsGroup(title: "Quiet scenes") {
                Text("Stays quiet while any scene below is active — no auto-expand, no sound, approvals included. A subtle dot still marks completions.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                SettingsToggleRow(title: "Focus mode", isOn: $prefs.quietInFocusMode)
                SettingsToggleRow(title: "Screen locked or asleep", isOn: $prefs.quietWhenLocked)
                SettingsToggleRow(title: "Screen recording or sharing", isOn: $prefs.quietWhenRecording)
            }

            SettingsGroup(title: "Built-in filters") {
                SettingsToggleRow(
                    title: "Agent helper sessions",
                    subtitle: "Hides memory writers, title generators, and health probes that agents spawn in the background.",
                    isOn: $prefs.filterCodexInternalWorkers
                )
            }

            SettingsGroup(title: "Custom filters: directory") {
                FilterEditor(
                    placeholder: "e.g. /scratch/experiments",
                    hint: "Hide any session whose working directory contains:",
                    text: $newDirectoryFilter,
                    entries: $prefs.directoryFilters
                )
            }

            SettingsGroup(title: "Custom filters: first prompt") {
                SettingsRow(title: "Match type") {
                    Picker("", selection: $prefs.promptFilterMatchType) {
                        Text("Starts with").tag("prefix")
                        Text("Contains").tag("contains")
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
                FilterEditor(
                    placeholder: "e.g. ## Memory Writing Agent",
                    hint: "Hide any session whose first prompt matches:",
                    text: $newPromptFilter,
                    entries: $prefs.promptFilters
                )
            }
        }
    }

    private var approvalNotificationBinding: Binding<ApprovalNotificationPolicy> {
        Binding(
            get: { prefs.approvalNotifications },
            set: { policy in
                prefs.approvalNotifications = policy
                // Turning it on here is the one place the prompt makes sense before an agent blocks.
                if policy != .never { notifier.requestAuthorizationIfNeeded() }
            }
        )
    }

    private var subagentBinding: Binding<SubagentNotificationPolicy> {
        Binding(
            get: { prefs.subagentNotifications },
            set: { prefs.subagentNotifications = $0 }
        )
    }
}

/// Add/remove list used by both filter groups.
struct FilterEditor: View {
    let placeholder: String
    let hint: String
    @Binding var text: String
    @Binding var entries: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add pattern", action: add)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if entries.isEmpty {
                Text("No custom patterns.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(entries, id: \.self) { entry in
                    HStack {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .foregroundStyle(.secondary)
                        Text(entry)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            entries.removeAll { $0 == entry }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .padding(12)
    }

    private func add() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !entries.contains(trimmed) else { return }
        entries.append(trimmed)
        text = ""
    }
}
