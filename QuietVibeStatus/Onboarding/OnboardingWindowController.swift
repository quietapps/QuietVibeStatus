import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController {
    static let shared = OnboardingWindowController()

    private var window: NSWindow?
    private let windowDelegate = DockPolicyWindowDelegate()

    private init() {}

    func show() {
        if let window {
            DockPolicy.promote(for: window)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let root = OnboardingView { [weak self] in
            Preferences.shared.hasCompletedOnboarding = true
            self?.close()
        }
        .environmentObject(Preferences.shared)
        .environmentObject(IntegrationManager.shared)
        .environmentObject(StatusLineInstaller.shared)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 470),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: root)
        window.delegate = windowDelegate

        self.window = window
        DockPolicy.promote(for: window)
        window.makeKeyAndOrderFront(nil)
    }

    /// Finishing from the Start button. Closing with the red X goes through the same delegate, so
    /// either way the Dock icon leaves with the window.
    private func close() {
        window?.close()
        window = nil
    }
}

/// First-run flow: explain what the app does, wire up the CLIs it found, done.
struct OnboardingView: View {
    let onFinish: () -> Void

    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var manager: IntegrationManager
    @EnvironmentObject private var statusLine: StatusLineInstaller
    @State private var step = 0

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(30)

            Divider()

            HStack {
                if step > 0 {
                    Button("Back") { withAnimation { step -= 1 } }
                }
                Spacer()
                Button(step == 2 ? "Start" : "Continue") {
                    if step == 2 {
                        onFinish()
                    } else {
                        withAnimation { step += 1 }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 470)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: welcome
        case 1: integrations
        default: finish
        }
    }

    private var welcome: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.topthird.inset.filled")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.blue)
            Text("Quiet Vibe Status")
                .font(.system(size: 24, weight: .semibold))
            Text("Your coding agents report to the notch. See what they're doing, approve what they ask, and jump straight to the terminal that needs you.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            VStack(alignment: .leading, spacing: 10) {
                OnboardingBullet(icon: "eye", text: "Watch every session at a glance")
                OnboardingBullet(icon: "hand.raised", text: "Approve permissions without switching windows")
                OnboardingBullet(icon: "questionmark.circle", text: "Answer questions from the panel")
                OnboardingBullet(icon: "arrow.uturn.forward", text: "Click a card to land on the exact tab")
            }
            .padding(.top, 8)
        }
    }

    private var integrations: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect your agents")
                .font(.system(size: 19, weight: .semibold))
            Text("Hooks get merged into each CLI's config. Anything already in those files stays exactly as it is.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            ForEach(manager.integrations) { integration in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(integration.displayName)
                            .font(.system(size: 13, weight: .medium))
                        Text(integration.isInstalled ? integration.configPath : "Not found on this Mac")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { prefs.enabledAgents.contains(integration.agent.rawValue) },
                        set: { manager.setEnabled($0, for: integration.agent) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!integration.isInstalled)
                }
                .padding(.vertical, 5)
                Divider()
            }

            Spacer()
        }
    }

    private var finish: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text("Ready")
                .font(.system(size: 20, weight: .semibold))
            Text("Start an agent in any terminal and its card appears in the notch. Everything runs locally — nothing is uploaded, and there's nothing to buy.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Toggle(
                "Also track Claude usage limits (adds a status line bridge)",
                isOn: Binding(
                    get: { statusLine.isInstalled },
                    set: { $0 ? statusLine.install() : statusLine.remove() }
                )
            )
            .font(.system(size: 12))
            .padding(.top, 8)
        }
    }
}

struct OnboardingBullet: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(Theme.blue)
                .frame(width: 18)
            Text(text)
                .font(.system(size: 12))
        }
    }
}
