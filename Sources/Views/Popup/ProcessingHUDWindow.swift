import SwiftUI

final class ProcessingHUDWindow: NSPanel {
    private let onCancel: () -> Void

    init(promptName: String, onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 64),
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
        collectionBehavior = [.canJoinAllSpaces, .transient]

        let hudView = ProcessingHUDView(promptName: promptName, onCancel: onCancel)
        contentView = NSHostingView(rootView: hudView)
    }

    func showAtCenter() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let screenFrame = screen?.visibleFrame else { return }
        let x = screenFrame.midX - frame.width / 2
        let y = screenFrame.midY - frame.height / 2 + 100
        setFrameOrigin(NSPoint(x: x, y: y))
        orderFrontRegardless()
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel()
    }
}

/// Transient panel shown when an inline (quick-paste) run fails. The caller
/// owns its lifetime — there is no auto-dismiss timer in the window itself.
final class ErrorHUDWindow: NSPanel {
    private let onDismiss: () -> Void

    init(promptName: String, message: String, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 64),
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
        collectionBehavior = [.canJoinAllSpaces, .transient]

        let hudView = ErrorHUDView(promptName: promptName, message: message, onDismiss: onDismiss)
        let hosting = NSHostingView(rootView: hudView)
        contentView = hosting
        setContentSize(hosting.fittingSize)
    }

    func showAtCenter() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let screenFrame = screen?.visibleFrame else { return }
        let x = screenFrame.midX - frame.width / 2
        let y = screenFrame.midY - frame.height / 2 + 100
        setFrameOrigin(NSPoint(x: x, y: y))
        orderFrontRegardless()
    }

    override func cancelOperation(_ sender: Any?) {
        onDismiss()
    }
}

private struct ErrorHUDView: View {
    let promptName: String
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)

            VStack(alignment: .leading, spacing: 2) {
                Text(promptName)
                    .font(.system(.body, weight: .medium))
                    .lineLimit(1)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 320)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct ProcessingHUDView: View {
    let promptName: String
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)

            VStack(alignment: .leading, spacing: 2) {
                Text(promptName)
                    .font(.system(.body, weight: .medium))
                    .lineLimit(1)
                Text("Processing...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
