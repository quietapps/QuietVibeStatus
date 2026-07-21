import SwiftUI

/// Log of finished sessions — duration, model, and estimated cost.
struct HistoryPane: View {
    @ObservedObject private var history = SessionHistory.shared
    @EnvironmentObject private var prefs: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup {
                SettingsToggleRow(
                    title: "Keep session history",
                    subtitle: "Log each finished session so you can review what ran, how long it took, and its estimated cost. Stored locally in ~/.quietvibestatus; the prompt and recap are included.",
                    isOn: $prefs.keepSessionHistory
                )
            }

            if prefs.keepSessionHistory {
                summary
                recentList
            }
        }
    }

    // MARK: - Summary

    private var summary: some View {
        SettingsGroup(title: "Last 7 days") {
            SettingsRow(title: "Sessions") {
                Text("\(history.entries(withinDays: 7).count)")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            SettingsRow(
                title: "Estimated cost",
                subtitle: "At published list prices. Subscription plans don't bill per token, so treat this as a weight, not an invoice."
            ) {
                Text(ModelPricing.format(history.totalCost(withinDays: 7)))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            SettingsRow(title: "Tokens") {
                Text(ModelPricing.formatTokens(history.totalTokens(withinDays: 7)))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Recent list

    @ViewBuilder
    private var recentList: some View {
        if history.entries.isEmpty {
            SettingsGroup {
                Text("No finished sessions yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
        } else {
            SettingsGroup(title: "Recent") {
                ForEach(history.entries.prefix(50)) { entry in
                    HistoryRow(entry: entry)
                }
            }

            Button("Clear history", role: .destructive) {
                history.clear()
            }
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(entry.failed ? Color.red : entry.agentKind.tint)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.headline)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(entry.project)
                    if let model = entry.model {
                        Text("· \(model)")
                    }
                    Text("· \(entry.durationText)")
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let cost = entry.estimatedCost {
                Text(ModelPricing.format(cost))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else if let usage = entry.usage {
                Text(ModelPricing.formatTokens(usage.totalTokens))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 12) }
        .help(entry.recap ?? entry.errorMessage ?? entry.cwd)
    }
}
