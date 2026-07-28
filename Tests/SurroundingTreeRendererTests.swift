import Foundation
import Testing
@testable import ClipSlop

/// Pure renderer tests — no AX, no disk. Fixtures model the surfaces the
/// tree capture exists for: a LinkedIn-style feed (WHICH post does the
/// comment box belong to?) and a chat with a noisy sidebar.
@Suite("Surrounding tree renderer")
struct SurroundingTreeRendererTests {

    private func text(_ string: String) -> SurroundingNode {
        SurroundingNode(role: "AXStaticText", text: string)
    }

    private var field: SurroundingNode {
        SurroundingNode(role: "AXTextArea", isField: true)
    }

    // MARK: - Fixtures

    /// Three-post feed, comment field inside post 2's comment list.
    private func linkedInFeed() -> SurroundingNode {
        func post(_ author: String, _ body: String, comments: [SurroundingNode]) -> SurroundingNode {
            SurroundingNode(role: "AXGroup", label: "post by \(author)", children: [
                text(author),
                text(body),
                SurroundingNode(role: "AXList", label: "comments", children: comments),
            ])
        }
        return SurroundingNode(role: "AXWebArea", label: "feed", children: [
            post("Ville Korhonen", "POST-ONE body about quarterly hiring plans and team growth.",
                 comments: [text("COMMENT-1A congrats on the growth")]),
            post("Priya Patel", "POST-TWO body announcing the new benchmark results.",
                 comments: [
                    text("COMMENT-2A impressive numbers, which hardware?"),
                    text("COMMENT-2B looking forward to the writeup"),
                    field,
                 ]),
            post("Sam Ortiz", "POST-THREE body celebrating a product launch.",
                 comments: [text("COMMENT-3A well deserved")]),
        ])
    }

    /// Messaging surface: sidebar of chat previews, message list, composer.
    private func chatSurface(messageCount: Int = 6) -> SurroundingNode {
        let sidebar = SurroundingNode(role: "AXGroup", label: "chats", children: (1...8).map {
            text("SIDEBAR-PREVIEW-\($0) some other conversation")
        })
        let messages = SurroundingNode(role: "AXList", label: "messages", children: (1...messageCount).map {
            text("MESSAGE-\($0) chat line number \($0) with some content")
        })
        let main = SurroundingNode(role: "AXGroup", children: [messages, field])
        return SurroundingNode(role: "AXWebArea", children: [sidebar, main])
    }

    // MARK: - Normalization

    @Test func wrapperChainsCollapse() {
        // Chromium-style: empty single-child AXGroup chains hoist away.
        let wrapped = SurroundingNode(role: "AXGroup", children: [
            SurroundingNode(role: "AXGroup", children: [
                SurroundingNode(role: "AXGroup", children: [
                    text("hello world"),
                    field,
                ]),
            ]),
        ])
        let normalized = SurroundingTreeRenderer.normalize(wrapped)
        #expect(normalized == SurroundingNode(role: "AXGroup", children: [text("hello world"), field]))
    }

    @Test func labeledSingleChildContainersSurvive() {
        let tree = SurroundingNode(role: "AXGroup", label: "post", children: [
            SurroundingNode(role: "AXList", label: "comments", children: [text("one comment")]),
        ])
        let normalized = SurroundingTreeRenderer.normalize(tree)
        #expect(normalized.label == "post")
        #expect(normalized.children.first?.label == "comments")
    }

    @Test func emptyContainersArePruned() {
        let tree = SurroundingNode(role: "AXGroup", label: "page", children: [
            SurroundingNode(role: "AXGroup", label: "toolbar", children: [
                SurroundingNode(role: "AXGroup"),
                SurroundingNode(role: "AXList", label: "empty list"),
            ]),
            text("real content"),
            field,
        ])
        let normalized = SurroundingTreeRenderer.normalize(tree)
        #expect(normalized.children == [text("real content"), field])
    }

    // MARK: - Rendering

    @Test func tagAndLabelRendering() {
        let tree = SurroundingNode(role: "AXWebArea", children: [
            SurroundingNode(role: "AXGroup", label: "post by Priya", children: [
                text("first"), text("second"),
            ]),
            SurroundingNode(role: "AXList", label: "comments", children: [text("a comment"), field]),
            SurroundingNode(role: "AXList", children: [text("unlabeled list item"), text("another")]),
        ])
        let (rendered, truncated) = SurroundingTreeRenderer.render(tree, maxTokens: 0)
        #expect(!truncated)
        // Labeled generic container: label only, no "group" tag noise.
        #expect(rendered.contains("[post by Priya]"))
        #expect(!rendered.contains("[group: post by Priya]"))
        // Labeled non-generic container ON the field path: tag + label +
        // containment note.
        #expect(rendered.contains("[list: comments — contains your field]"))
        // Unlabeled non-generic container off the path: bare tag, no note.
        #expect(rendered.contains("[list]"))
        // Unlabeled web area on the field path: tag + containment note.
        #expect(rendered.contains("[webarea — contains your field]"))
    }

    @Test func onlyTheFieldsEnclosingSectionsCarryTheContainmentNote() {
        // Two conversations on one screen — the thread that holds the field,
        // and a docked chat overlay rendered after it with newer messages.
        // The containment notes must single out the field's sections; the
        // overlay must visibly lack one, or the model cannot tell which
        // conversation it is replying in.
        let main = SurroundingNode(role: "AXGroup", children: [
            SurroundingNode(role: "AXList", label: "messages", children: [text("THREAD question for the user")]),
            field,
        ])
        let overlay = SurroundingNode(role: "AXGroup", label: "Messaging", children: [
            text("OVERLAY newer message from a different person"),
        ])
        let tree = SurroundingNode(role: "AXWebArea", children: [main, overlay])
        let (rendered, _) = SurroundingTreeRenderer.render(tree, maxTokens: 0)
        #expect(rendered.contains("[webarea — contains your field]"))
        #expect(rendered.contains("[group — contains your field]"))
        #expect(rendered.contains("[Messaging]"))
        #expect(!rendered.contains("[Messaging — contains your field]"))
    }

    @Test func unlabeledGroupOffPathEmitsNoLineAndNoExtraIndent() {
        let tree = SurroundingNode(role: "AXWebArea", label: "page", children: [
            SurroundingNode(role: "AXGroup", children: [text("inside silent group"), text("second line")]),
            field,
        ])
        let (rendered, _) = SurroundingTreeRenderer.render(tree, maxTokens: 0)
        let lines = rendered.components(separatedBy: "\n")
        // No "[group]" line for the off-path unlabeled group…
        #expect(!lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "[group]" }))
        // …and no phantom indent level either: indent tracks emitted lines
        // only, so the silent group's children sit at the root's child
        // level. Depth stays meaningful — one level per visible line —
        // instead of being diluted by every invisible wrapper.
        #expect(lines.contains("  inside silent group"))
        #expect(!lines.contains("    inside silent group"))
    }

    @Test func markerSitsAtTheExactFieldPosition() throws {
        let tree = SurroundingNode(role: "AXGroup", label: "thread", children: [
            text("BEFORE the field"),
            field,
            text("AFTER the field"),
        ])
        let (rendered, _) = SurroundingTreeRenderer.render(tree, maxTokens: 0)
        let lines = rendered.components(separatedBy: "\n")
        let before = try #require(lines.firstIndex { $0.contains("BEFORE the field") })
        let marker = try #require(lines.firstIndex { $0.contains(SurroundingTreeRenderer.fieldMarkerPrefix) })
        let after = try #require(lines.firstIndex { $0.contains("AFTER the field") })
        #expect(before < marker && marker < after)
    }

    @Test func fieldNoteAppearsInsideTheMarker() {
        let tree = SurroundingNode(role: "AXGroup", label: "page", children: [text("content here"), field])
        let (rendered, _) = SurroundingTreeRenderer.render(
            tree, maxTokens: 0, fieldNote: "empty \"Add a comment…\" box"
        )
        #expect(rendered.contains("⟨YOUR FIELD — you are writing here — empty \"Add a comment…\" box⟩"))
    }

    @Test func ancestorChainDerivation() {
        let chain = SurroundingTreeRenderer.ancestorChain(of: linkedInFeed())
        #expect(chain == ["feed", "post by Priya Patel", "comments"])
        let (rendered, _) = SurroundingTreeRenderer.render(linkedInFeed(), maxTokens: 0)
        #expect(rendered.contains("YOU ARE WRITING IN: feed › post by Priya Patel › comments"))
    }

    @Test func zeroBudgetRendersEverythingUntruncated() {
        let (rendered, truncated) = SurroundingTreeRenderer.render(linkedInFeed(), maxTokens: 0)
        #expect(!truncated)
        for marker in ["POST-ONE", "POST-TWO", "POST-THREE", "COMMENT-1A", "COMMENT-2A", "COMMENT-2B", "COMMENT-3A"] {
            #expect(rendered.contains(marker), "zero budget must keep \(marker)")
        }
        #expect(!rendered.contains(SurroundingTreeRenderer.trimMarker))
    }

    // MARK: - Structure-aware trim

    @Test func trimKeepsChainAndNearestSiblingsFirst() {
        // Budget for the chain + post 2's own content, not the whole feed:
        // the other posts vanish, the comments beside the field stay.
        let (rendered, truncated) = SurroundingTreeRenderer.render(linkedInFeed(), maxTokens: 140)
        #expect(truncated)
        #expect(rendered.contains("YOU ARE WRITING IN: feed › post by Priya Patel › comments"))
        #expect(rendered.contains(SurroundingTreeRenderer.fieldMarkerPrefix))
        #expect(rendered.contains("COMMENT-2A"))
        #expect(rendered.contains("COMMENT-2B"))
        #expect(!rendered.contains("POST-ONE"))
        #expect(!rendered.contains("POST-THREE"))
        #expect(rendered.contains(SurroundingTreeRenderer.trimMarker))
    }

    @Test func budgetTooSmallStillRendersHeaderChainAndMarker() {
        let (rendered, truncated) = SurroundingTreeRenderer.render(linkedInFeed(), maxTokens: 1)
        #expect(truncated)
        #expect(rendered.contains("YOU ARE WRITING IN: feed › post by Priya Patel › comments"))
        #expect(rendered.contains(SurroundingTreeRenderer.outlineHeader))
        #expect(rendered.contains("[post by Priya Patel — contains your field]"))
        #expect(rendered.contains("[list: comments — contains your field]"))
        #expect(rendered.contains(SurroundingTreeRenderer.fieldMarkerPrefix))
        // Every content unit dropped — no text lines survive.
        #expect(!rendered.contains("COMMENT"))
        #expect(!rendered.contains("POST-"))
    }

    @Test func trimMarkersStandWhereSubtreesDropped() throws {
        let (rendered, _) = SurroundingTreeRenderer.render(linkedInFeed(), maxTokens: 100)
        let lines = rendered.components(separatedBy: "\n")
        let markerLines = lines.filter { $0.contains(SurroundingTreeRenderer.trimMarker) }
        #expect(!markerLines.isEmpty)
        // Post 1's subtree was dropped: a trim marker precedes post 2's line.
        let postTwo = try #require(lines.firstIndex { $0.contains("[post by Priya Patel") })
        #expect(lines[..<postTwo].contains { $0.contains(SurroundingTreeRenderer.trimMarker) })
    }

    @Test func plainTextExcludesStructuralLines() {
        let plain = linkedInFeed().plainText
        #expect(plain.contains("POST-TWO body announcing the new benchmark results."))
        #expect(plain.contains("COMMENT-2A impressive numbers, which hardware?"))
        #expect(!plain.contains("["))
        #expect(!plain.contains("YOU ARE WRITING IN"))
        #expect(!plain.contains("⟨"))
        #expect(!plain.contains("feed"))
    }

    // MARK: - Fixture: chat with sidebar

    @Test func chatMarkerFollowsTheNewestMessage() throws {
        let (rendered, _) = SurroundingTreeRenderer.render(chatSurface(), maxTokens: 0)
        let lines = rendered.components(separatedBy: "\n")
        let newest = try #require(lines.firstIndex { $0.contains("MESSAGE-6") })
        let marker = try #require(lines.firstIndex { $0.contains(SurroundingTreeRenderer.fieldMarkerPrefix) })
        #expect(marker > newest)
    }

    @Test func chatSidebarIsTrimmedBeforeMessages() {
        // Budget for the messages but not the sidebar: the conversation
        // being replied to survives, the other chats' previews vanish.
        let (rendered, truncated) = SurroundingTreeRenderer.render(chatSurface(), maxTokens: 130)
        #expect(truncated)
        #expect(rendered.contains("MESSAGE-6"))
        #expect(rendered.contains("MESSAGE-5"))
        #expect(!rendered.contains("SIDEBAR-PREVIEW"))
        #expect(rendered.contains(SurroundingTreeRenderer.fieldMarkerPrefix))
    }

    @Test func chatMessagesPartialTrimDropsOldestFirst() {
        // Tighter still: the messages unit itself no longer fits whole —
        // its oldest (farthest-from-field) lines drop, the newest stay.
        let (rendered, truncated) = SurroundingTreeRenderer.render(chatSurface(messageCount: 12), maxTokens: 115)
        #expect(truncated)
        #expect(rendered.contains("MESSAGE-12"))
        #expect(!rendered.contains("MESSAGE-1 "))
        #expect(rendered.contains(SurroundingTreeRenderer.trimMarker))
    }

    // MARK: - Article boundaries (structural subroles)

    private func article(_ children: [SurroundingNode]) -> SurroundingNode {
        SurroundingNode(role: "AXGroup", subrole: "AXDocumentArticle", children: children)
    }

    @Test func unlabeledArticleEmitsItsBoundaryLineEvenOffPath() {
        let tree = SurroundingNode(role: "AXWebArea", label: "page", children: [
            article([text("COMMENT-A body"), text("COMMENT-A timestamp")]),
            article([text("COMMENT-B body"), field]),
        ])
        let (rendered, _) = SurroundingTreeRenderer.render(tree, maxTokens: 0)
        let lines = rendered.components(separatedBy: "\n")
        // Off-path article draws its boundary; on-path one carries the note.
        #expect(lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "[article]" }))
        #expect(rendered.contains("[article — contains your field]"))
    }

    @Test func singleChildArticleSurvivesNormalization() {
        // A one-line comment is still one comment — hoisting its article
        // wrapper would merge it visually into the neighboring thread.
        let tree = SurroundingNode(role: "AXWebArea", label: "page", children: [
            article([text("lone one-line comment")]),
            field,
        ])
        let normalized = SurroundingTreeRenderer.normalize(tree)
        #expect(normalized.children.first?.subrole == "AXDocumentArticle")
        let (rendered, _) = SurroundingTreeRenderer.render(tree, maxTokens: 0)
        #expect(rendered.contains("[article]"))
    }

    @Test func nestedArticlesRenderNestedBoundaries() throws {
        // A reply thread: comment article containing a reply article.
        let tree = SurroundingNode(role: "AXWebArea", label: "page", children: [
            article([
                text("PARENT comment body"),
                article([text("REPLY body"), field]),
            ]),
        ])
        let (rendered, _) = SurroundingTreeRenderer.render(tree, maxTokens: 0)
        let lines = rendered.components(separatedBy: "\n")
        let outer = try #require(lines.firstIndex { $0.hasSuffix("[article — contains your field]") })
        let inner = try #require(lines.lastIndex { $0.hasSuffix("[article — contains your field]") })
        #expect(outer < inner)
        // The inner article is indented one level deeper than the outer.
        let indent = { (line: String) in line.prefix(while: { $0 == " " }).count }
        #expect(indent(lines[inner]) == indent(lines[outer]) + 2)
        // The chain header names the nesting.
        #expect(rendered.contains("YOU ARE WRITING IN: page › article › article"))
    }

    @Test func leafNoteRendersAfterTheTextInMarkerBrackets() {
        var author = text("Dave V")
        author.note = "LIKELY REPLY TARGET"
        let tree = SurroundingNode(role: "AXWebArea", label: "page", children: [
            article([author, text("What harnesses try?")]),
            field,
        ])
        let (rendered, _) = SurroundingTreeRenderer.render(tree, maxTokens: 0)
        #expect(rendered.contains("Dave V  ⟨LIKELY REPLY TARGET⟩"))
        // The note never leaks into the grounding/language pool.
        #expect(!tree.plainText.contains("LIKELY REPLY TARGET"))
    }

    /// Modeled on the real misfire `press-2026-07-27-212716-35349BB4`: a
    /// post with several comment threads, the composer inside one nested
    /// reply thread, unrelated comments adjacent in document order.
    private func linkedInThreadedPost() -> SurroundingNode {
        func comment(_ author: String, _ body: String, replies: [SurroundingNode] = []) -> SurroundingNode {
            article([text(author), text("6d"), text(body)] + replies)
        }
        return SurroundingNode(role: "AXWebArea", label: "Post | LinkedIn", children: [
            article([
                text("Swiss Army knife"),
                text("POST body about subscriptions and one-time purchases."),
                SurroundingNode(role: "AXList", label: "comments", children: [
                    comment("Ilia Brakhov", "OTHER-THREAD subscriptions are necessary for servers."),
                    comment("Michael Long", "TARGET-THREAD you can add a local model option.", replies: [
                        article([text("Nikita Rabykin"), text("REPLY the app supports ollama already."), field]),
                    ]),
                    comment("Eugene Malikov", "ADJACENT local models could be extremely slow."),
                ]),
            ]),
        ])
    }

    @Test func threadedPostChainAndContainmentSingleOutTheReplyBranch() {
        let (rendered, _) = SurroundingTreeRenderer.render(linkedInThreadedPost(), maxTokens: 0)
        // The enclosing branch (Michael Long's thread) carries containment…
        let lines = rendered.components(separatedBy: "\n")
        let containing = lines.filter { $0.contains(SurroundingTreeRenderer.containsFieldNote) }
        #expect(containing.count >= 3)
        // …while the sibling threads' articles visibly lack it.
        let bareArticles = lines.filter { $0.trimmingCharacters(in: .whitespaces) == "[article]" }
        #expect(bareArticles.count == 2)
        // Author names render beside the bodies they wrote.
        for name in ["Ilia Brakhov", "Michael Long", "Eugene Malikov", "Nikita Rabykin"] {
            #expect(rendered.contains(name))
        }
    }

    @Test func threadedPostTrimNeverDropsTheInnermostThread() {
        let (rendered, truncated) = SurroundingTreeRenderer.render(linkedInThreadedPost(), maxTokens: 150)
        #expect(truncated)
        // The reply branch (unit 0 chain + nearest siblings) survives the
        // squeeze; the unrelated threads go first.
        #expect(rendered.contains("TARGET-THREAD"))
        #expect(rendered.contains(SurroundingTreeRenderer.fieldMarkerPrefix))
        #expect(!rendered.contains("OTHER-THREAD"))
    }
}
