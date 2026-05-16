import SwiftUI

struct QuickAccessTileView: View {
    let tile: QuickAccessTile
    let prompt: PromptNode
    let onActivate: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: onActivate) {
            VStack(spacing: 4) {
                Text(prompt.mnemonicDisplay)
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 22, minHeight: 22)
                    .padding(.horizontal, 2)
                    .background(Color.purple)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                Text(prompt.name)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)

                Image(systemName: tile.method.iconName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tint)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(8)
            .contentShape(Rectangle())
            .background(tileBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.tint.opacity(isHovered ? 0.6 : 0), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    @ViewBuilder
    private var tileBackground: some View {
        if isHovered {
            RoundedRectangle(cornerRadius: 8)
                .fill(.tint.opacity(0.18))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary.opacity(0.4))
        }
    }
}
