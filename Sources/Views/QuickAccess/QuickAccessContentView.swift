import AppKit
import SwiftUI

struct QuickAccessContentView: View {
    let appState: AppState
    let onClose: () -> Void
    let onActivate: (QuickAccessTile) -> Void

    private let loc = Loc.shared

    var body: some View {
        let store = appState.quickAccessStore

        ZStack {
            VisualEffectBlur(material: .menu, blendingMode: .behindWindow)
                .ignoresSafeArea()

            Group {
                if store.tiles.isEmpty {
                    emptyState
                } else {
                    gridContent(
                        tiles: store.tiles,
                        columns: max(1, store.gridColumns)
                    )
                }
            }
            .padding(16)

            QuickAccessKeyMonitor(
                appState: appState,
                onClose: onClose,
                onActivate: onActivate
            )
            .frame(width: 0, height: 0)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.grid.3x3")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(loc.t("quick_access.empty_state"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func gridContent(tiles: [QuickAccessTile], columns: Int) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns),
            spacing: 8
        ) {
            ForEach(tiles) { tile in
                if let prompt = appState.promptStore.findNode(byID: tile.promptID),
                   prompt.isPrompt {
                    QuickAccessTileView(tile: tile, prompt: prompt) {
                        onActivate(tile)
                    }
                    .frame(height: 70)
                } else {
                    Color.clear.frame(height: 70)
                }
            }
        }
    }
}

private struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

private struct QuickAccessKeyMonitor: NSViewRepresentable {
    let appState: AppState
    let onClose: () -> Void
    let onActivate: (QuickAccessTile) -> Void

    func makeNSView(context: Context) -> KeyMonitorView {
        let view = KeyMonitorView()
        view.appState = appState
        view.onClose = onClose
        view.onActivate = onActivate
        return view
    }

    func updateNSView(_ nsView: KeyMonitorView, context: Context) {
        nsView.appState = appState
        nsView.onClose = onClose
        nsView.onActivate = onActivate
    }

    final class KeyMonitorView: NSView {
        var appState: AppState?
        var onClose: (() -> Void)?
        var onActivate: ((QuickAccessTile) -> Void)?
        private var monitor: Any?

        private static let escapeKeyCode: UInt16 = 53

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self else { return event }
                    guard event.window === self.window else { return event }
                    return self.handleKey(event) ? nil : event
                }
            }
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.removeFromSuperview()
        }

        @MainActor
        private func handleKey(_ event: NSEvent) -> Bool {
            guard let appState else { return false }

            if event.keyCode == Self.escapeKeyCode {
                onClose?()
                return true
            }

            let modifiers = MnemonicModifiers(eventFlags: event.modifierFlags)
            let useKeyCodes = appState.settings.useKeyCodes

            let primaryKey: String
            if useKeyCodes, let mapped = keyCodeToCharacter(event.keyCode) {
                primaryKey = mapped
            } else {
                primaryKey = event.charactersIgnoringModifiers?.lowercased() ?? ""
            }

            if !primaryKey.isEmpty, activateTile(matchingKey: primaryKey, modifiers: modifiers) {
                return true
            }

            if !useKeyCodes,
               let fallback = keyCodeToCharacter(event.keyCode),
               fallback != primaryKey,
               activateTile(matchingKey: fallback, modifiers: modifiers) {
                return true
            }

            if let specialID = keyCodeToIdentifier(event.keyCode),
               activateTile(matchingKey: specialID, modifiers: modifiers) {
                return true
            }

            return false
        }

        @MainActor
        private func activateTile(matchingKey key: String, modifiers: MnemonicModifiers) -> Bool {
            guard let appState, let onActivate else { return false }
            for tile in appState.quickAccessStore.tiles {
                guard let prompt = appState.promptStore.findNode(byID: tile.promptID),
                      prompt.isPrompt else { continue }
                if prompt.mnemonicKey.lowercased() == key.lowercased()
                    && (prompt.mnemonicModifiers ?? []) == modifiers {
                    onActivate(tile)
                    return true
                }
            }
            return false
        }
    }
}
