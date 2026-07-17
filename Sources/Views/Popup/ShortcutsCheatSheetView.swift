import SwiftUI

/// Full keyboard-shortcut reference shown as an overlay on the popup (⌘/).
/// The status bar only has room for the most common hints — this is the
/// complete list, grouped by mode.
struct ShortcutsCheatSheetView: View {
    let appState: AppState
    private let loc = Loc.shared

    var body: some View {
        ZStack {
            // Dimmed backdrop — click anywhere outside the panel to dismiss
            Color.black.opacity(0.25)
                .contentShape(Rectangle())
                .onTapGesture {
                    appState.isShortcutsOverlayVisible = false
                }

            // The panel can be taller than a small popup window — fall back
            // to scrolling instead of clipping when it doesn't fit.
            ViewThatFits(in: .vertical) {
                panel
                ScrollView(showsIndicators: false) {
                    panel
                        .padding(.vertical, 16)
                }
            }
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(loc.t("shortcuts.title"))
                    .font(.headline)
                Spacer()
                Button {
                    appState.isShortcutsOverlayVisible = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 14) {
                    section(loc.t("shortcuts.section.viewing"), rows: [
                        ("↑ ↓", loc.t("popup.hint.history")),
                        ("Space", loc.t("popup.hint.page_down")),
                        ("⇧Space", loc.t("popup.hint.page_up")),
                        ("⌫", loc.t("popup.hint.back")),
                        ("⌘D", loc.t("shortcuts.display_next")),
                        ("⇧⌘D", loc.t("shortcuts.display_prev")),
                        ("⌘L", loc.t("shortcuts.toggle_library")),
                        ("⌘/", loc.t("shortcuts.toggle_overlay")),
                        ("Esc", loc.t("popup.hint.close")),
                    ])

                    section(loc.t("shortcuts.section.search"), rows: [
                        ("/", loc.t("popup.hint.search")),
                        ("↑ ↓", loc.t("popup.hint.search_select")),
                        ("↩", loc.t("popup.hint.search_run")),
                        ("Esc", loc.t("popup.hint.search_exit")),
                    ])

                    section(loc.t("shortcuts.section.editing"), rows: [
                        ("⌘↩", loc.t("popup.done")),
                        ("Esc", loc.t("popup.cancel")),
                    ])
                }

                VStack(alignment: .leading, spacing: 14) {
                    section(loc.t("shortcuts.section.actions"), rows: [
                        ("⌘C", loc.t("popup.copy")),
                        ("⌃⌘C", loc.t("popup.copy_and_close")),
                        ("⌃⌘V", loc.t("popup.copy_close_paste")),
                        ("⌘A", loc.t("popup.select_all")),
                        ("⌘E", loc.t("popup.edit")),
                        ("⌘O", loc.t("popup.open")),
                        ("⌘S", loc.t("popup.save")),
                        ("⌘F", loc.t("popup.hint.find")),
                        ("⌘G", loc.t("shortcuts.find_next")),
                        ("⇧⌘G", loc.t("shortcuts.find_prev")),
                        ("⌘,", loc.t("shortcuts.settings")),
                    ])

                    section(loc.t("shortcuts.section.adhoc"), rows: [
                        ("⌘K", loc.t("popup.hint.adhoc")),
                        ("↩", loc.t("popup.hint.adhoc_run")),
                        ("⇧↩", loc.t("popup.hint.adhoc_newline")),
                        ("Esc", loc.t("popup.hint.adhoc_exit")),
                    ])
                }
            }

            Divider()

            Text(loc.t("popup.mnemonic_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.quaternary)
        )
        .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
    }

    private func section(_ title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            ForEach(rows, id: \.0) { key, label in
                HStack(spacing: 8) {
                    Text(key)
                        .font(.caption.monospaced().weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                        .frame(minWidth: 52, alignment: .leading)
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
            }
        }
    }
}
