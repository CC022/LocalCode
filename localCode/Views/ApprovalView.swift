import AgentCore
import SwiftUI

/// Inline approval prompt — rendered inside the assistant bubble while the
/// agent loop is suspended on a permission gate. The bubble auto-collapses
/// into the normal tool-result disclosure once a choice is made.
struct ApprovalView: View {
    let request: ApprovalRequest
    let resolve: (ApprovalChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                Text(request.reason)
                    .font(.callout.weight(.medium))
            }
            Text(request.call.summary)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 8) {
                Button("Deny") { resolve(.deny) }
                Spacer()
                Button("Allow for session") { resolve(.session) }
                Button("Allow once") { resolve(.once) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
    }
}
