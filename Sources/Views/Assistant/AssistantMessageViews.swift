import SwiftUI
import Textual

/// Renders one transcript item. Proposal cards get Approve/Reject buttons that
/// resolve the assistant's pending confirmation.
struct AssistantChatItemView: View {
    let item: PromptAssistantService.ChatItem
    let service: PromptAssistantService

    var body: some View {
        switch item {
        case .userText(_, let text):
            UserMessageBubble(text: text)
        case .assistantText(_, let text):
            AssistantMessageText(text: text)
        case .toolActivity(_, let text):
            ToolActivityRow(text: text)
        case .proposal(let proposal):
            ProposalCardView(
                proposal: proposal,
                onApprove: { service.resolveConfirmation(approved: true) },
                onReject: { service.resolveConfirmation(approved: false) }
            )
        }
    }
}

// MARK: - Message bubbles

private struct UserMessageBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            Text(text)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct AssistantMessageText: View {
    let text: String

    var body: some View {
        HStack {
            // Assistant replies come back as Markdown — render them with the
            // app's native (no-WebView) Textual renderer, sized to content so it
            // flows inside the transcript.
            StructuredText(markdown: text)
                .textual.textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 40)
        }
    }
}

private struct ToolActivityRow: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "wrench.and.screwdriver")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Proposal card

struct ProposalCardView: View {
    let proposal: ToolProposal
    let onApprove: () -> Void
    let onReject: () -> Void

    private let loc = Loc.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(proposal.title).fontWeight(.semibold)
            } icon: {
                Image(systemName: proposal.isDestructive ? "exclamationmark.triangle.fill" : "pencil.and.outline")
                    .foregroundStyle(proposal.isDestructive ? .orange : Color.accentColor)
            }
            .font(.callout)

            if let warning = proposal.warning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            ForEach(proposal.fields) { field in
                ProposalFieldRow(field: field)
            }

            footer
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(proposal.isDestructive ? Color.orange.opacity(0.4) : Color.secondary.opacity(0.2))
        )
    }

    private var cardBackground: Color {
        proposal.isDestructive ? Color.orange.opacity(0.06) : Color.secondary.opacity(0.08)
    }

    @ViewBuilder
    private var footer: some View {
        switch proposal.resolution {
        case .pending:
            HStack(spacing: 8) {
                Button(role: proposal.isDestructive ? .destructive : nil, action: onApprove) {
                    Text(loc.t("assistant.approve"))
                }
                .buttonStyle(.borderedProminent)

                Button(action: onReject) {
                    Text(loc.t("assistant.reject"))
                }
                .buttonStyle(.bordered)
            }
        case .approved:
            Label(loc.t("assistant.applied"), systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .rejected:
            Label(loc.t("assistant.declined"), systemImage: "xmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ProposalFieldRow: View {
    let field: ProposalField

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(field.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            if let old = field.oldValue, !old.isEmpty {
                ValueBlock(text: old, tint: .red)
            }
            if let new = field.newValue {
                ValueBlock(text: new, tint: .green)
            }
        }
    }
}

/// A value shown inside a proposal card. Long values (prompt bodies) scroll
/// inside a capped height so a big edit doesn't blow up the card.
private struct ValueBlock: View {
    let text: String
    let tint: Color

    var body: some View {
        ScrollView(.vertical) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 120)
        .fixedSize(horizontal: false, vertical: true)
        .padding(8)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
    }
}
