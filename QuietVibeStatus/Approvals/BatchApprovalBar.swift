import SwiftUI

/// Header over a run of permission cards from one session, with a decision that covers all of them.
///
/// An agent partway through a task queues several permissions before you get to the panel, and
/// answering a stack of six one at a time is most of the friction in unblocking it. Only permissions
/// are batched — plans and questions each need their own answer.
struct BatchApprovalBar: View {
    let sessionID: String
    let count: Int
    let project: String?

    @State private var confirmingDenial = false

    var body: some View {
        HStack(spacing: Theme.s2) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.attention)

            Text("\(count) requests\(project.map { " from \($0)" } ?? "")")
                .font(Theme.ui(10, weight: .medium))
                .foregroundStyle(Theme.onDark2)
                .lineLimit(1)

            Spacer(minLength: Theme.s2)

            if confirmingDenial {
                Text("Deny all \(count)?")
                    .font(Theme.ui(10))
                    .foregroundStyle(Theme.onDark3)
                ActionButton(title: "Confirm", style: .destructive) {
                    PendingRequestRegistry.shared.resolveAll(
                        sessionID: sessionID,
                        with: .deny(reason: nil)
                    )
                }
                ActionButton(title: "Cancel", style: .quiet) {
                    confirmingDenial = false
                }
            } else {
                ActionButton(title: "Allow all", style: .primary) {
                    PendingRequestRegistry.shared.resolveAll(sessionID: sessionID, with: .allow)
                }
                // One click that denies several unread requests deserves a second one. Allow-all is
                // recoverable — the agent asks again next time — while a denial the agent handles as
                // a refusal is not.
                ActionButton(title: "Deny all", style: .destructive) {
                    confirmingDenial = true
                }
            }
        }
        .padding(.horizontal, Theme.s3)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous)
                .fill(Theme.attention.opacity(0.16))
        )
        .onChange(of: count) { _, _ in confirmingDenial = false }
    }
}
