import SwiftUI

/// Compact quota readout in the panel header.
struct UsageBadge: View {
    @ObservedObject private var store = UsageStore.shared
    @EnvironmentObject private var prefs: Preferences

    var body: some View {
        let providers = store.displayedAll.filter { $0.short != nil || $0.long != nil }
        if !providers.isEmpty {
            HStack(spacing: 8) {
                ForEach(Array(providers.enumerated()), id: \.element.provider) { index, usage in
                    if index > 0 {
                        Rectangle()
                            .fill(Theme.onDark3.opacity(0.25))
                            .frame(width: 1, height: 11)
                    }
                    row(for: usage)
                }
            }
        }
    }

    /// One provider: its tinted chip, then the quota windows.
    private func row(for usage: ProviderUsage) -> some View {
        HStack(spacing: 5) {
            // Two providers report the same-looking percentages, so the numbers are meaningless
            // without saying whose quota they are.
            Chip(text: usage.agent.displayName, tint: usage.agent.tint, font: 9)
            if let short = usage.short {
                window("5h", short)
            }
            if usage.short != nil, usage.long != nil {
                Text("|")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.onDark3.opacity(0.5))
            }
            if let long = usage.long {
                window("7d", long)
            }
        }
        .opacity(usage.isStale ? 0.5 : 1)
        .help(helpText(for: usage))
    }

    /// Both quota windows side by side. Seeing only the 5-hour number hides the case that actually
    /// bites — a healthy short window while the weekly one is nearly spent.
    private func window(_ label: String, _ value: UsageWindow) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(Theme.mono(10, weight: .medium))
                .foregroundStyle(Theme.onDark2)
            Text(text(for: value))
                .font(Theme.mono(10, weight: .semibold))
                .foregroundStyle(color(for: value))
        }
    }

    private func helpText(for usage: ProviderUsage) -> String {
        var parts = ["\(usage.provider) usage"]
        if let short = usage.short, let reset = short.resetText {
            parts.append("5h resets in \(reset)")
        }
        if let long = usage.long, let reset = long.resetText {
            parts.append("7d resets in \(reset)")
        }
        return parts.joined(separator: " · ")
    }

    private func text(for window: UsageWindow) -> String {
        prefs.usageDisplayValue == "remaining"
            ? "\(Int(window.remainingPercentage))%"
            : "\(Int(window.usedPercentage))%"
    }

    private func color(for window: UsageWindow) -> Color {
        switch window.usedPercentage {
        case ..<70: return Theme.success
        case ..<90: return Theme.warning
        default: return Theme.danger
        }
    }
}
