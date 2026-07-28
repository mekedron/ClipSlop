import Testing
@testable import ClipSlop

/// Pure detector tests. The five names come from the real presses the
/// detector was built for (the 2026-07-27 LinkedIn debug logs).
@Suite("Reply-target detector")
struct ReplyTargetDetectorTests {

    private func text(_ string: String) -> SurroundingNode {
        SurroundingNode(role: "AXStaticText", text: string)
    }

    private func tree(leaves: [String]) -> SurroundingNode {
        SurroundingNode(role: "AXWebArea", label: "page", children:
            leaves.map(text) + [SurroundingNode(role: "AXTextArea", isField: true)]
        )
    }

    // MARK: - Fires on real mention shapes

    @Test(arguments: [
        "Daniel Vafidis", "Oleksandr Malka", "Dave V", "Brill Pappin", "Michael Long",
    ])
    func firesOnEachRealMention(name: String) throws {
        // LinkedIn pre-fills the name with a trailing space.
        let result = try #require(ReplyTargetDetector.detect(
            fieldValue: name + " ",
            tree: tree(leaves: [name, "some comment body", "6d"])
        ))
        #expect(result.target.name == name)
        #expect(result.target.matchCount == 1)
        let annotated = result.annotatedTree.children.first { $0.text == name }
        #expect(annotated?.note == ReplyTargetDetector.noteText)
    }

    @Test func multipleMatchesAllAnnotatedAndCounted() throws {
        let result = try #require(ReplyTargetDetector.detect(
            fieldValue: "Michael Long ",
            tree: tree(leaves: ["Michael Long", "first message", "Michael Long", "second message"])
        ))
        #expect(result.target.matchCount == 2)
        let notes = result.annotatedTree.children.filter { $0.note != nil }
        #expect(notes.count == 2)
    }

    @Test func decoratedLeafMatchesOnNameBoundary() throws {
        // "Michael Long • 2nd" — name followed by a non-letter matches…
        let result = try #require(ReplyTargetDetector.detect(
            fieldValue: "Michael Long ",
            tree: tree(leaves: ["Michael Long • 2nd", "body"])
        ))
        #expect(result.target.matchCount == 1)
        // …a longer name that merely starts the same never does.
        #expect(ReplyTargetDetector.detect(
            fieldValue: "Dave V ",
            tree: tree(leaves: ["Dave Vernon", "body"])
        ) == nil)
    }

    @Test func lowercaseParticlesAllowedMidName() throws {
        let result = try #require(ReplyTargetDetector.detect(
            fieldValue: "Daniel van der Berg ",
            tree: tree(leaves: ["Daniel van der Berg"])
        ))
        #expect(result.target.name == "Daniel van der Berg")
    }

    // MARK: - Refuses everything that is not a mention

    @Test(arguments: [
        // Real drafts: length, casing, punctuation.
        "Template can have only 2 statuses: Draft and Published",
        "ok sure",
        "Thanks",                       // single word — never a mention
        "Sounds good",                  // second word lowercase
        "Great post!",                  // punctuation
        "",
        "   ",
    ])
    func refusesNonMentionDrafts(value: String) {
        // Even with a leaf that matches the draft verbatim, the shape gate
        // refuses — this is what keeps normal drafts on the draft framing.
        #expect(ReplyTargetDetector.detect(
            fieldValue: value,
            tree: tree(leaves: [value.trimmingCharacters(in: .whitespaces), "context"])
        ) == nil)
    }

    @Test func refusesNameAbsentFromScreen() {
        // Name-shaped, but the page shows no such person — a two-word draft
        // like "Warm Regards" must stay a draft.
        #expect(ReplyTargetDetector.detect(
            fieldValue: "Warm Regards ",
            tree: tree(leaves: ["completely different content"])
        ) == nil)
    }

    @Test func refusesWithoutTree() {
        #expect(ReplyTargetDetector.detect(fieldValue: "Dave V ", tree: nil) == nil)
    }

    @Test func annotationNeverTouchesLeafText() throws {
        let original = tree(leaves: ["Dave V", "What harnesses try?"])
        let result = try #require(ReplyTargetDetector.detect(fieldValue: "Dave V ", tree: original))
        #expect(result.annotatedTree.plainText == original.plainText)
    }
}
