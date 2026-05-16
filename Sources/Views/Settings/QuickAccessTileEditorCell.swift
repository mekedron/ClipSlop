import SwiftUI

struct QuickAccessTileEditorCell: View {
    let tile: QuickAccessTile
    let prompt: PromptNode?
    let onChangeMethod: (QuickAccessMethod) -> Void
    let onRemove: () -> Void

    private let loc = Loc.shared

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                if let prompt {
                    Text(prompt.mnemonicDisplay)
                        .font(.system(.caption, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 22, minHeight: 22)
                        .padding(.horizontal, 2)
                        .background(Color.purple)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: "questionmark.diamond")
                        .foregroundStyle(.red)
                }

                Text(prompt?.name ?? loc.t("settings.quick_access.tile.missing"))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(prompt == nil ? .red : .primary)

                Spacer(minLength: 4)

                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(loc.t("settings.quick_access.tile.remove"))
            }

            Picker(loc.t("settings.quick_access.method.label"), selection: Binding(
                get: { tile.method },
                set: { onChangeMethod($0) }
            )) {
                Label(loc.t("settings.quick_access.method.inline"),
                      systemImage: QuickAccessMethod.inline.iconName)
                    .tag(QuickAccessMethod.inline)
                Label(loc.t("settings.quick_access.method.open_in_clipslop"),
                      systemImage: QuickAccessMethod.openInPopup.iconName)
                    .tag(QuickAccessMethod.openInPopup)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: .infinity)
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}
