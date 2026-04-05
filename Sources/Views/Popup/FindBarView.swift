import SwiftUI

// MARK: - Search Backend Protocol

@MainActor
protocol SearchableContent: AnyObject {
    /// Find all matches for the query, return total count.
    func performSearch(query: String) async -> Int
    /// Scroll to and highlight the match at the given index.
    func highlightMatch(at index: Int)
    /// Remove all search highlights.
    func clearSearch()
}

// MARK: - Find Bar State

@MainActor
@Observable
final class FindBarState {
    var isVisible = false
    var searchQuery = ""
    var totalMatches = 0
    var currentMatchIndex = 0

    weak var activeBackend: (any SearchableContent)?

    @ObservationIgnored private var searchTask: Task<Void, Never>?

    /// Incremented each time show() is called to force re-focus even when already visible.
    var focusToken = 0

    func show() {
        isVisible = true
        focusToken += 1
    }

    func dismiss() {
        searchTask?.cancel()
        searchTask = nil
        activeBackend?.clearSearch()
        isVisible = false
        searchQuery = ""
        totalMatches = 0
        currentMatchIndex = 0
    }

    func nextMatch() {
        guard totalMatches > 0 else { return }
        currentMatchIndex = (currentMatchIndex + 1) % totalMatches
        activeBackend?.highlightMatch(at: currentMatchIndex)
    }

    func previousMatch() {
        guard totalMatches > 0 else { return }
        currentMatchIndex = (currentMatchIndex - 1 + totalMatches) % totalMatches
        activeBackend?.highlightMatch(at: currentMatchIndex)
    }

    /// Clears highlights on the old backend and re-executes search after a short
    /// delay so the new view has time to register as `activeBackend`.
    func clearAndReSearch() {
        activeBackend?.clearSearch()
        totalMatches = 0
        currentMatchIndex = 0
        guard !searchQuery.isEmpty else { return }
        searchTask?.cancel()
        searchTask = Task {
            // Wait for the new view to mount and register as backend
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await executeSearch(query: searchQuery)
        }
    }

    func triggerSearch() {
        searchTask?.cancel()
        let query = searchQuery
        searchTask = Task {
            // Debounce
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await executeSearch(query: query)
        }
    }

    func executeSearchImmediately() {
        searchTask?.cancel()
        searchTask = Task {
            await executeSearch(query: searchQuery)
        }
    }

    private func executeSearch(query: String) async {
        guard !query.isEmpty, let backend = activeBackend else {
            activeBackend?.clearSearch()
            totalMatches = 0
            currentMatchIndex = 0
            return
        }
        let count = await backend.performSearch(query: query)
        guard !Task.isCancelled else { return }
        totalMatches = count
        currentMatchIndex = count > 0 ? 0 : 0
        if count > 0 {
            backend.highlightMatch(at: 0)
        }
    }
}

// MARK: - Find Bar View

struct FindBarView: View {
    let findBarState: FindBarState
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            // Search field
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.caption)

                TextField("Find...", text: Bindable(findBarState).searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .default))
                    .focused($isSearchFieldFocused)
                    .onSubmit {
                        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                            findBarState.previousMatch()
                        } else {
                            findBarState.nextMatch()
                        }
                    }
                    .onChange(of: findBarState.searchQuery) {
                        findBarState.triggerSearch()
                    }

                if !findBarState.searchQuery.isEmpty {
                    Button {
                        findBarState.searchQuery = ""
                        findBarState.activeBackend?.clearSearch()
                        findBarState.totalMatches = 0
                        findBarState.currentMatchIndex = 0
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

            // Match count
            if !findBarState.searchQuery.isEmpty {
                if findBarState.totalMatches > 0 {
                    Text("\(findBarState.currentMatchIndex + 1) of \(findBarState.totalMatches)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text("No matches")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Navigation buttons
            Button {
                findBarState.previousMatch()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(findBarState.totalMatches == 0)

            Button {
                findBarState.nextMatch()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(findBarState.totalMatches == 0)

            // Done button
            Button("Done") {
                findBarState.dismiss()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .onAppear { focusSearchField() }
        .onChange(of: findBarState.focusToken) { focusSearchField() }
    }

    private func focusSearchField() {
        // Schedule on next runloop tick so the TextField is mounted and focusable.
        DispatchQueue.main.async {
            isSearchFieldFocused = true
        }
    }
}
