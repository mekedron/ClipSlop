import SwiftUI
import UniformTypeIdentifiers

struct QuickAccessGridConfigurator: View {
    let appState: AppState

    @State private var isPromptDropTargeted: Bool = false

    private let loc = Loc.shared

    var body: some View {
        @Bindable var settings = appState.settings

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(loc.t("settings.quick_access.columns"))
                Stepper(value: $settings.quickAccessGridColumns, in: 1...8) {
                    Text("\(settings.quickAccessGridColumns)")
                        .monospacedDigit()
                        .frame(minWidth: 24, alignment: .trailing)
                }
                .fixedSize()
                Spacer()
            }

            if settings.quickAccessTiles.isEmpty {
                emptyDropZone
            } else {
                tileGrid(columns: max(1, settings.quickAccessGridColumns))
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onDrop(of: [.utf8PlainText], isTargeted: $isPromptDropTargeted) { providers, _ in
            handlePromptDrop(providers: providers, before: nil)
        }
    }

    private var emptyDropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.grid.3x3")
                .font(.system(size: 28))
                .foregroundStyle(isPromptDropTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            Text(loc.t("settings.quick_access.grid_empty"))
                .font(.body)
                .foregroundStyle(.secondary)
            Text(loc.t("settings.quick_access.grid_empty_hint"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .padding(20)
        .background(emptyDropZoneBackground)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.15), value: isPromptDropTargeted)
    }

    @ViewBuilder
    private var emptyDropZoneBackground: some View {
        if isPromptDropTargeted {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.tint.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.tint, style: StrokeStyle(lineWidth: 2, dash: [5]))
                )
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [5]))
        }
    }

    private func tileGrid(columns: Int) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns),
            spacing: 10
        ) {
            ForEach(appState.settings.quickAccessTiles) { tile in
                tileCell(for: tile)
            }
        }
    }

    private func tileCell(for tile: QuickAccessTile) -> some View {
        let resolved = appState.promptStore.findNode(byID: tile.promptID)
        let prompt = resolved?.isPrompt == true ? resolved : nil

        return QuickAccessTileEditorCell(
            tile: tile,
            prompt: prompt,
            onChangeMethod: { newMethod in
                updateMethod(tileID: tile.id, method: newMethod)
            },
            onRemove: {
                removeTile(tileID: tile.id)
            }
        )
        .onDrag {
            NSItemProvider(object: TileDragPayload.encode(tileID: tile.id) as NSString)
        }
        .onDrop(of: [.utf8PlainText], isTargeted: nil) { providers, _ in
            handleCellDrop(providers: providers, targetTileID: tile.id)
        }
    }

    // MARK: - Mutations

    private func handlePromptDrop(providers: [NSItemProvider], before targetID: UUID?) -> Bool {
        guard !providers.isEmpty else { return false }
        for provider in providers {
            provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let ns = object as? NSString else { return }
                let string = ns as String
                if let promptID = PromptDragPayload.decode(string) {
                    Task { @MainActor in
                        if let targetID {
                            _ = insertTile(promptID: promptID, before: targetID)
                        } else {
                            _ = appendTile(promptID: promptID)
                        }
                    }
                }
            }
        }
        return true
    }

    private func handleCellDrop(providers: [NSItemProvider], targetTileID: UUID) -> Bool {
        guard !providers.isEmpty else { return false }
        for provider in providers {
            provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let ns = object as? NSString else { return }
                let string = ns as String
                if let promptID = PromptDragPayload.decode(string) {
                    Task { @MainActor in
                        _ = insertTile(promptID: promptID, before: targetTileID)
                    }
                } else if let sourceTileID = TileDragPayload.decode(string), sourceTileID != targetTileID {
                    Task { @MainActor in
                        _ = moveTile(sourceTileID: sourceTileID, onto: targetTileID)
                    }
                }
            }
        }
        return true
    }

    private func appendTile(promptID: UUID) -> Bool {
        guard let node = appState.promptStore.findNode(byID: promptID), node.isPrompt else { return false }
        var tiles = appState.settings.quickAccessTiles
        guard !tiles.contains(where: { $0.promptID == promptID }) else { return false }
        tiles.append(QuickAccessTile(promptID: promptID))
        appState.settings.quickAccessTiles = tiles
        return true
    }

    private func insertTile(promptID: UUID, before targetID: UUID) -> Bool {
        guard let node = appState.promptStore.findNode(byID: promptID), node.isPrompt else { return false }
        var tiles = appState.settings.quickAccessTiles
        guard !tiles.contains(where: { $0.promptID == promptID }) else { return false }
        guard let targetIndex = tiles.firstIndex(where: { $0.id == targetID }) else {
            return appendTile(promptID: promptID)
        }
        tiles.insert(QuickAccessTile(promptID: promptID), at: targetIndex)
        appState.settings.quickAccessTiles = tiles
        return true
    }

    private func moveTile(sourceTileID: UUID, onto targetTileID: UUID) -> Bool {
        guard sourceTileID != targetTileID else { return false }
        var tiles = appState.settings.quickAccessTiles
        guard let fromIndex = tiles.firstIndex(where: { $0.id == sourceTileID }),
              let originalTargetIndex = tiles.firstIndex(where: { $0.id == targetTileID })
        else { return false }

        let movingForward = fromIndex < originalTargetIndex
        let moving = tiles.remove(at: fromIndex)
        guard let postRemovalTargetIndex = tiles.firstIndex(where: { $0.id == targetTileID }) else {
            tiles.append(moving)
            appState.settings.quickAccessTiles = tiles
            return true
        }
        // Land the dragged tile on the target's visual slot:
        //   forward drag → insert AFTER target (target shifted left by removal)
        //   backward drag → insert BEFORE target (target index unchanged)
        let insertIndex = movingForward ? postRemovalTargetIndex + 1 : postRemovalTargetIndex
        tiles.insert(moving, at: insertIndex)
        appState.settings.quickAccessTiles = tiles
        return true
    }

    private func updateMethod(tileID: UUID, method: QuickAccessMethod) {
        var tiles = appState.settings.quickAccessTiles
        guard let index = tiles.firstIndex(where: { $0.id == tileID }) else { return }
        tiles[index].method = method
        appState.settings.quickAccessTiles = tiles
    }

    private func removeTile(tileID: UUID) {
        appState.settings.quickAccessTiles.removeAll { $0.id == tileID }
    }
}
