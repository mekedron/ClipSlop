import AppKit
import SwiftUI

final class QuickAccessWindow: NSPanel {
    private let appState: AppState

    @MainActor
    init(appState: AppState) {
        self.appState = appState
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
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
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .transient]

        contentView = NSHostingView(rootView: QuickAccessContentView(
            appState: appState,
            onClose: { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.appState.dismissQuickAccess()
                }
            },
            onActivate: { [weak self] tile in
                guard let self else { return }
                Task { @MainActor in
                    self.appState.activateQuickAccessTile(tile)
                }
            }
        ))
    }

    @MainActor
    func showNearCursor() {
        sizeToFitGrid()

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }

        let w = frame.width
        let h = frame.height
        let cursorInset: CGFloat = 12
        var x = mouse.x - cursorInset
        var y = mouse.y - h + cursorInset  // NSWindow origin is bottom-left

        x = max(visible.minX, min(x, visible.maxX - w))
        y = max(visible.minY, min(y, visible.maxY - h))

        setFrameOrigin(NSPoint(x: x, y: y))
        // Match PopupWindow.showAtCenter: KeyboardShortcuts callbacks fire in
        // the source app's context, so without explicit activation the panel
        // opens behind and never receives key events for mnemonic activation.
        // Pairs with the focus-handoff in AppState.dismissQuickAccess.
        makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }

    @MainActor
    private func sizeToFitGrid() {
        let store = appState.quickAccessStore
        let tiles = store.tiles
        let columns = max(1, store.gridColumns)

        let cellWidth: CGFloat = 110
        let cellHeight: CGFloat = 70
        let spacing: CGFloat = 8
        let padding: CGFloat = 16

        if tiles.isEmpty {
            setContentSize(NSSize(width: 320, height: 140))
            return
        }

        let rows = max(1, Int(ceil(Double(tiles.count) / Double(columns))))

        let contentWidth = CGFloat(columns) * cellWidth
            + CGFloat(columns - 1) * spacing
            + padding * 2
        let contentHeight = CGFloat(rows) * cellHeight
            + CGFloat(rows - 1) * spacing
            + padding * 2

        setContentSize(NSSize(width: contentWidth, height: contentHeight))
    }

    override func cancelOperation(_ sender: Any?) {
        Task { @MainActor in
            appState.dismissQuickAccess()
        }
    }

    override func resignKey() {
        super.resignKey()
        Task { @MainActor in
            if appState.isQuickAccessVisible {
                appState.dismissQuickAccess()
            }
        }
    }

    override var canBecomeKey: Bool { true }
}
