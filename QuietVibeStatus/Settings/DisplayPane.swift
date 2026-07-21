import SwiftUI

struct DisplayPane: View {
    @EnvironmentObject private var prefs: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "Notch") {
                HStack(spacing: 12) {
                    ForEach(NotchStyle.allCases, id: \.self) { style in
                        StyleCard(
                            style: style,
                            selected: prefs.notchStyle == style
                        ) {
                            prefs.notchStyle = style
                        }
                    }
                }
                .padding(12)

                SettingsRow(title: "Display") {
                    Picker("", selection: displayBinding) {
                        ForEach(DisplayTarget.allCases, id: \.self) { target in
                            Text(target.title).tag(target)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
            }

            SettingsGroup(title: "Panel size") {
                SettingsRow(title: "Content font size") {
                    Picker("", selection: $prefs.contentFontSize) {
                        Text("10pt (Compact)").tag(10.0)
                        Text("11pt (Default)").tag(11.0)
                        Text("12pt").tag(12.0)
                        Text("13pt (Large)").tag(13.0)
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
                SettingsSliderRow(
                    title: "Completion card height",
                    value: $prefs.completionCardHeight,
                    range: 60 ... 200,
                    step: 5
                ) { "\(Int($0))pt" }
                SettingsSliderRow(
                    title: "Max panel height",
                    value: $prefs.maxPanelHeight,
                    range: 240 ... 900,
                    step: 20
                ) { "\(Int($0))pt" }
                SettingsSliderRow(
                    title: "Max panel width",
                    value: $prefs.maxPanelWidth,
                    range: 440 ... 800,
                    step: 20
                ) { "\(Int($0))pt" }
            }

            SettingsGroup(title: "Activity animation") {
                SettingsRow(
                    title: "Style",
                    subtitle: prefs.activityAnimation.subtitle
                ) {
                    Picker("", selection: animationBinding) {
                        ForEach(ActivityAnimation.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }

                HStack(spacing: 20) {
                    ForEach(ActivityAnimation.allCases) { style in
                        VStack(spacing: 6) {
                            ActivityGlyph(active: true, color: Theme.blue, size: 16)
                                .environment(\.activityAnimationOverride, style)
                                .frame(height: 20)
                            Text(style.title)
                                .font(.system(size: 10))
                                .foregroundStyle(
                                    prefs.activityAnimation == style ? .primary : .secondary
                                )
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(
                                    prefs.activityAnimation == style
                                        ? Color.primary.opacity(0.08) : .clear
                                )
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { prefs.activityAnimation = style }
                    }
                }
                .padding(12)
            }

            SettingsGroup(title: "Session card") {
                SettingsToggleRow(title: "Show project name", isOn: $prefs.showProjectName)
                SettingsToggleRow(title: "Show worktree", isOn: $prefs.showWorktree)
                SettingsToggleRow(title: "Show AI model", isOn: $prefs.showModel)
                SettingsToggleRow(
                    title: "Show subagents",
                    subtitle: "Hide fan-out subagents to keep the panel clean and fast.",
                    isOn: $prefs.showSubagents
                )
                SettingsToggleRow(
                    title: "Show agent activity detail",
                    isOn: $prefs.showActivityDetail
                )
                SettingsToggleRow(
                    title: "Show token cost",
                    subtitle: "Add a chip with the session's token spend, estimated at list prices.",
                    isOn: $prefs.showSessionCost
                )
                SettingsToggleRow(
                    title: "Group cards by project",
                    subtitle: "Collect sessions from the same directory under one heading, instead of a flat list.",
                    isOn: $prefs.groupByProject
                )

                SessionCardPreview()
                    .padding(12)
            }

            SettingsGroup(title: "Tuning") {
                SettingsSliderRow(
                    title: "Notch width",
                    value: $prefs.notchWidthAdjust,
                    range: -40 ... 40,
                    step: 1
                ) { "\(Int($0))pt" }
                SettingsSliderRow(
                    title: "Notch height",
                    value: $prefs.notchHeightAdjust,
                    range: -10 ... 20,
                    step: 1
                ) { "\(Int($0))pt" }
            }

            Text("The pill should line up with your Mac's physical notch. If it sits slightly off, nudge it with the tuning sliders.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var animationBinding: Binding<ActivityAnimation> {
        Binding(
            get: { prefs.activityAnimation },
            set: { prefs.activityAnimation = $0 }
        )
    }

    private var displayBinding: Binding<DisplayTarget> {
        Binding(
            get: { prefs.displayTarget },
            set: { prefs.displayTarget = $0 }
        )
    }
}

struct StyleCard: View {
    let style: NotchStyle
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.black)
                        .frame(height: 22)
                    HStack(spacing: 5) {
                        Circle().fill(Theme.success).frame(width: 5, height: 5)
                        if style == .detailed {
                            Capsule().fill(Theme.onDark3).frame(width: 34, height: 4)
                        }
                        Spacer()
                        Text(style == .detailed ? "2 ses" : "2")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(Theme.onDark2)
                    }
                    .padding(.horizontal, 8)
                }
                Text(style.title).font(.system(size: 12, weight: .medium))
                Text(style.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Theme.blue : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}
