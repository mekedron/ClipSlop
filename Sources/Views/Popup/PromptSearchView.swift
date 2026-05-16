import SwiftUI

/// Compact search input rendered in the breadcrumb slot when search is active.
/// Keeps the keyboard focus and writes through to `searchState.query`.
struct PromptSearchBar: View {
    let searchState: PromptSearchState
    @FocusState private var isFieldFocused: Bool
    private let loc = Loc.shared

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)

            TextField(loc.t("popup.search.placeholder"), text: Bindable(searchState).query)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .default))
                .focused($isFieldFocused)

            if !searchState.query.isEmpty {
                Text("\(searchState.results.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()

                Button {
                    searchState.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(WindowDragBlocker())
        .onAppear { focusField() }
        .onChange(of: searchState.focusToken) { focusField() }
    }

    private func focusField() {
        DispatchQueue.main.async {
            isFieldFocused = true
        }
    }
}

/// Scrollable, scored result list for the "/" search overlay. Replaces the
/// prompt grid while `searchState.isActive`.
struct PromptSearchList: View {
    let appState: AppState
    let searchState: PromptSearchState
    private let loc = Loc.shared

    var body: some View {
        Group {
            if searchState.results.isEmpty {
                Text(loc.t("popup.search.no_results"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 1) {
                            // ForEach identifies each row by the prompt's UUID.
                            // We deliberately do NOT add `.id(index)` here —
                            // doing so makes SwiftUI treat the position as the
                            // identity, and stale view bodies get reused when
                            // results shrink/grow.
                            ForEach(Array(searchState.results.enumerated()), id: \.element.id) { index, result in
                                SearchResultRow(
                                    result: result,
                                    isSelected: index == searchState.clampedSelectedIndex,
                                    onActivate: {
                                        searchState.selectedIndex = index
                                        appState.applySearchResult(at: index)
                                    }
                                )
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                    }
                    .onChange(of: searchState.clampedSelectedIndex) { _, newValue in
                        let results = searchState.results
                        guard newValue >= 0, newValue < results.count else { return }
                        // Scroll by UUID — the same identity ForEach uses, so
                        // ScrollViewReader finds the right row even when the
                        // result set has just changed shape.
                        proxy.scrollTo(results[newValue].id, anchor: .center)
                    }
                }
            }
        }
        .background(.background.opacity(0.5))
    }
}

// MARK: - Row

private struct SearchResultRow: View {
    let result: PromptSearchResult
    let isSelected: Bool
    let onActivate: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    private var background: Color {
        if isPressed { return Color.accentColor.opacity(0.35) }
        if isSelected { return Color.accentColor.opacity(0.20) }
        if isHovered { return Color.primary.opacity(0.08) }
        return .clear
    }

    var body: some View {
        Button(action: onActivate) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .font(.caption)
                    .foregroundStyle(isSelected ? .white : .purple)
                    .frame(width: 18, height: 18)
                    .background(isSelected ? Color.accentColor : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                VStack(alignment: .leading, spacing: 1) {
                    Text(result.node.name)
                        .font(.subheadline)
                        .lineLimit(1)

                    if !result.path.isEmpty {
                        Text(result.path.joined(separator: " / "))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "return")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .background(WindowDragBlocker())
    }
}
