import AppKit
import SwiftUI

/// The Magic Button's status surface (§3.5): a non-blocking panel that shows
/// generation progress (with the ✕ cancel target, R10) and, after insertion,
/// the post-insert loop — Undo/Restore · ⌘R Regenerate · type-to-refine ·
/// Copy.
///
/// Shown with `orderFrontRegardless()` so it never steals focus from the
/// field the user is reading. `becomesKeyOnlyIfNeeded` lets a click into the
/// refine field make it key; Esc and ⌘R work only while it *is* key — no
/// global event tap ever.
final class MagicToastWindow: NSPanel {
    private let onEscape: () -> Void

    @MainActor
    init(coordinator: MagicPressCoordinator, onEscape: @escaping () -> Void) {
        self.onEscape = onEscape
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 80),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isMovableByWindowBackground = true
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .transient]

        contentView = FirstMouseHostingView(rootView: MagicToastView(coordinator: coordinator))
    }

    @MainActor
    func show(anchoredAt anchor: NSRect) {
        layoutIfNeeded()
        guard let visible = CaretLocator.screenFor(anchor: anchor)?.visibleFrame else { return }
        let origin = CaretLocator.panelOrigin(anchor: anchor, panelSize: frame.size, visibleFrame: visible)
        setFrameOrigin(origin)
        orderFrontRegardless()
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape()
    }

    override var canBecomeKey: Bool { true }
}

/// The toast belongs to an app that is usually *inactive* — without
/// first-mouse acceptance the initial click on any control is swallowed by
/// AppKit as "the activating click" and buttons need a second attempt.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Content

struct MagicToastView: View {
    @Bindable var coordinator: MagicPressCoordinator

    @State private var refineText = ""
    @State private var refineExpanded = false
    @State private var refineHeight: CGFloat = 22
    @State private var insertAnywayArmed = false
    @State private var holdStartedAt: ContinuousClock.Instant?

    var body: some View {
        Group {
            switch coordinator.toastState {
            case .none:
                EmptyView()
            case .generating(let label):
                generating(label: label)
            case .inserted:
                inserted
            case .panelResult(let text, let reason, let warnings):
                panelResult(text: text, reason: reason, warnings: warnings)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 380)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { coordinator.toastHovered = $0 }
    }

    // MARK: States

    private func generating(label: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(label)
                .font(.system(.body, weight: .medium))
                .lineLimit(1)
            Spacer()
            closeButton { coordinator.cancelGeneration() }
        }
    }

    private var inserted: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(.tint)
                Text(coordinator.restoreNote ?? Loc.shared.t("magic.toast.inserted"))
                    .font(.system(.body, weight: .medium))
                    .lineLimit(1)
                Spacer()
                closeButton { coordinator.dismissToast(outcome: nil) }
            }
            HStack(spacing: 8) {
                toastAction("arrow.uturn.backward", Loc.shared.t("magic.toast.undo"), id: "undo") {
                    coordinator.undoOrRestore()
                }
                toastAction("arrow.clockwise", Loc.shared.t("magic.toast.regenerate"), id: "regenerate") {
                    coordinator.regenerate()
                }
                .keyboardShortcut("r", modifiers: .command)
                toastAction("doc.on.doc", Loc.shared.t("magic.toast.copy"), id: "copy") {
                    coordinator.copyResult()
                }
                Spacer()
            }
            refineRow
        }
    }

    private func panelResult(
        text: String, reason: MagicToastPanelReason, warnings: [VerifierWarning]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: reason == .verifierFailed ? "exclamationmark.shield" : "doc.on.clipboard")
                    .foregroundStyle(reason == .verifierFailed ? .yellow : .secondary)
                Text(reasonTitle(reason))
                    .font(.system(.body, weight: .medium))
                    .lineLimit(2)
                Spacer()
                closeButton { coordinator.dismissToast(outcome: nil) }
            }

            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(warnings.prefix(3).enumerated()), id: \.offset) { _, warning in
                        Text(warningText(warning))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            ScrollView {
                Text(text)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 120)

            HStack(spacing: 8) {
                toastAction("doc.on.doc", Loc.shared.t("magic.toast.copy"), id: "copy") {
                    coordinator.copyResult()
                }
                if reason == .verifierFailed {
                    holdToInsertButton
                        .accessibilityIdentifier("magic.toast.insert_anyway")
                }
                Spacer()
            }
        }
    }

    // MARK: Pieces

    private var refineRow: some View {
        Group {
            if refineExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ChatInputTextView(text: $refineText, verticalInset: 3) { height in
                        refineHeight = min(max(height, 22), 66)
                    }
                    .frame(height: refineHeight)
                    HStack {
                        Text(Loc.shared.t("magic.toast.refine_hint"))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button(Loc.shared.t("magic.toast.refine_send")) {
                            submitRefine()
                        }
                        .accessibilityIdentifier("magic.toast.refine_send")
                        .controlSize(.small)
                        .keyboardShortcut(.return, modifiers: [])
                        .disabled(refineText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            } else {
                Button {
                    refineExpanded = true
                    // The click that expands the pill also makes the panel
                    // key (becomesKeyOnlyIfNeeded) so typing lands here.
                    coordinator.makeToastKey()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "pencil.line")
                        Text(Loc.shared.t("magic.toast.refine"))
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Loc.shared.t("magic.toast.refine"))
                .accessibilityIdentifier("magic.toast.refine")
            }
        }
    }

    private func submitRefine() {
        let instruction = refineText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        refineText = ""
        refineExpanded = false
        coordinator.refine(instruction)
    }

    /// Hold-to-confirm (§10.2): "Insert anyway" is deliberately
    /// high-friction, and every use is logged as a guard-health signal.
    ///
    /// The insert fires on *release*, never mid-hold: while the mouse button
    /// is down over this panel our app owns the event-tracking session, and
    /// a synthetic ⌘V posted then never reaches the target app — the exact
    /// live-test failure ("held it, nothing inserted").
    private var holdToInsertButton: some View {
        Text(insertAnywayArmed
             ? Loc.shared.t("magic.toast.insert_anyway_release")
             : Loc.shared.t("magic.toast.insert_anyway"))
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(insertAnywayArmed ? AnyShapeStyle(.yellow.opacity(0.4)) : AnyShapeStyle(.quaternary),
                        in: RoundedRectangle(cornerRadius: 6))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard holdStartedAt == nil else { return }
                        holdStartedAt = ContinuousClock().now
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(600))
                            if holdStartedAt != nil { insertAnywayArmed = true }
                        }
                    }
                    .onEnded { _ in
                        let start = holdStartedAt
                        holdStartedAt = nil
                        insertAnywayArmed = false
                        if let start, ContinuousClock().now - start >= .milliseconds(600) {
                            coordinator.insertAnyway()
                        }
                    }
            )
    }

    // Plain-style buttons with custom label views lose their AX titles in
    // the hosting-view bridge — VoiceOver (and the QA rig) saw five
    // nameless buttons. Label + stable identifier are set explicitly.
    private func toastAction(_ symbol: String, _ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                Text(title)
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier("magic.toast.\(id)")
    }

    private func closeButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Loc.shared.t("magic.toast.close"))
        .accessibilityIdentifier("magic.toast.close")
    }

    private func reasonTitle(_ reason: MagicToastPanelReason) -> String {
        switch reason {
        case .nonEditable: Loc.shared.t("magic.toast.result_ready")
        case .focusMismatch: Loc.shared.t("magic.toast.focus_moved")
        case .verifierFailed: Loc.shared.t("magic.toast.verifier_failed")
        }
    }

    private func warningText(_ warning: VerifierWarning) -> String {
        Loc.shared.t(warning.messageKey, warning.messageArgs.first ?? "", warning.messageArgs.count > 1 ? warning.messageArgs[1] : "")
    }
}
