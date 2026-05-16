import Foundation
import Testing
@testable import ClipSlop

/// Pure-logic tests for the prompt-search scoring algorithm. No UI, no async,
/// no main-actor work — the static `score` and `tokenize` helpers are pure
/// functions over `(name, path, tokens)`.

@Suite("PromptSearchState scoring")
struct PromptSearchScoringTests {

    @Test("Empty query yields empty token list")
    func emptyQueryYieldsNoTokens() {
        #expect(PromptSearchState.tokenize("").isEmpty)
        #expect(PromptSearchState.tokenize("   ").isEmpty)
    }

    @Test("Whitespace-split tokens")
    func tokenizeSplitsOnWhitespace() {
        let tokens = PromptSearchState.tokenize("ana sum")
        #expect(tokens == ["ana", "sum"])
    }

    @Test("Multi-token query matches across name and path")
    func anaSumMatchesAnalyzeSummaryInWriting() {
        // The user's example: "ana sum" should match "Analyze - Summary"
        // even when "Analyze - Summary" lives inside the "Writing" folder.
        let tokens = PromptSearchState.tokenize("ana sum")
        let score = PromptSearchState.score(
            name: "Analyze - Summary",
            path: ["Writing"],
            tokens: tokens
        )
        #expect(score != nil)
        #expect((score ?? 0) > 0)
    }

    @Test("Unmatched token filters out the prompt")
    func missingTokenReturnsNil() {
        let tokens = PromptSearchState.tokenize("hello goodbye")
        let score = PromptSearchState.score(
            name: "Hello World",
            path: [],
            tokens: tokens
        )
        #expect(score == nil)
    }

    @Test("Name-only match scores higher than path-only match")
    func nameBeatsPath() {
        let tokens = ["writer"]
        let nameMatch = PromptSearchState.score(
            name: "Writer Helper",
            path: ["Tools"],
            tokens: tokens
        )
        let pathMatch = PromptSearchState.score(
            name: "Helper",
            path: ["Writer"],
            tokens: tokens
        )
        #expect(nameMatch != nil && pathMatch != nil)
        #expect((nameMatch ?? 0) > (pathMatch ?? 0))
    }

    @Test("Word-start bonus increases score")
    func wordStartBonus() {
        let tokens = ["ana"]
        let atStart = PromptSearchState.score(name: "Analyze X", path: [], tokens: tokens) ?? 0
        // "ana" doesn't actually appear at a word start of "Banana" — it's mid-word.
        let midWord = PromptSearchState.score(name: "Banana", path: [], tokens: tokens) ?? 0
        #expect(atStart > midWord)
    }

    @Test("Diacritic-insensitive matching")
    func diacriticInsensitive() {
        let tokens = ["cafe"]
        let score = PromptSearchState.score(name: "Café", path: [], tokens: tokens)
        #expect(score != nil)
    }

    @Test("Case-insensitive matching")
    func caseInsensitive() {
        let tokens = ["SUMMARY"]
        let score = PromptSearchState.score(name: "summary", path: [], tokens: tokens)
        #expect(score != nil)
    }

    @Test("Path token match works when name has no match")
    func pathOnlyMatchSucceeds() {
        let tokens = ["writing"]
        let score = PromptSearchState.score(name: "Summary", path: ["Writing"], tokens: tokens)
        #expect(score != nil)
        #expect((score ?? 0) > 0)
    }
}

@Suite("PromptSearchState selection")
@MainActor
struct PromptSearchSelectionTests {

    @Test("clampedSelectedIndex stays in bounds when results shrink")
    func clampedIndexBounds() {
        let state = PromptSearchState()
        // No store wired → results is empty → clamp is 0.
        state.selectedIndex = 10
        #expect(state.clampedSelectedIndex == 0)
    }

    @Test("selectNext and selectPrevious clamp at edges")
    func selectionClampsAtEdges() {
        let state = PromptSearchState()
        // With empty results, both no-op.
        state.selectNext()
        state.selectPrevious()
        #expect(state.selectedIndex == 0)
    }

    @Test("query change resets selectedIndex to 0")
    func queryDidSetResetsSelection() {
        let state = PromptSearchState()
        state.selectedIndex = 5
        state.query = "x"
        #expect(state.selectedIndex == 0)
    }

    @Test("activate sets isActive and bumps focusToken")
    func activateBumpsFocusToken() {
        let state = PromptSearchState()
        let before = state.focusToken
        state.activate()
        #expect(state.isActive)
        #expect(state.focusToken == before + 1)
    }

    @Test("deactivate clears query and selection")
    func deactivateResets() {
        let state = PromptSearchState()
        state.activate()
        state.query = "abc"
        state.selectedIndex = 3
        state.deactivate()
        #expect(!state.isActive)
        #expect(state.query.isEmpty)
        #expect(state.selectedIndex == 0)
    }
}
