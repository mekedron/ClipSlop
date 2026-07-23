import Testing
@testable import ClipSlop

@Suite("Frontmatter parser")
struct FrontmatterParserTests {
    @Test func parsesScalarsListsAndBody() throws {
        let doc = try FrontmatterParser.parse("""
        ---
        id: comment.social
        priority: 70
        intents: [comment, reply]
        summary: "LinkedIn comment"
        ---
        ## Rules
        - Be brief.
        """)
        #expect(doc.fields["id"] == .scalar("comment.social"))
        #expect(doc.fields["priority"] == .scalar("70"))
        #expect(doc.fields["intents"] == .list(["comment", "reply"]))
        #expect(doc.fields["summary"] == .scalar("LinkedIn comment"))
        #expect(doc.body == "## Rules\n- Be brief.")
    }

    @Test func parsesFlowMap() throws {
        let doc = try FrontmatterParser.parse("""
        ---
        budget: {prompt_tokens_total: 3500, ms: 1500}
        ---
        """)
        #expect(doc.fields["budget"] == .map([
            "prompt_tokens_total": .scalar("3500"),
            "ms": .scalar("1500"),
        ]))
    }

    @Test func parsesNestedWhenBlock() throws {
        let doc = try FrontmatterParser.parse("""
        ---
        when:
          app: [com.google.Chrome, com.apple.Safari]
          url: "linkedin\\\\.com/(feed|posts)"
          field.state: [empty, draft]
        ---
        """)
        guard case .map(let when)? = doc.fields["when"] else {
            Issue.record("expected a map for 'when'")
            return
        }
        #expect(when["app"] == .list(["com.google.Chrome", "com.apple.Safari"]))
        // Double-quoted scalars process escapes: \\. in the file → \. pattern.
        #expect(when["url"] == .scalar("linkedin\\.com/(feed|posts)"))
        #expect(when["field.state"] == .list(["empty", "draft"]))
        #expect(doc.fieldLines["when.url"] == 4)
    }

    @Test func parsesBlockList() throws {
        let doc = try FrontmatterParser.parse("""
        ---
        needs:
          - ax.surrounding
          - index.person
        ---
        """)
        #expect(doc.fields["needs"] == .list(["ax.surrounding", "index.person"]))
    }

    @Test func quotedScalarKeepsHashAndUnquotedStripsComment() throws {
        let doc = try FrontmatterParser.parse("""
        ---
        a: "value # not a comment"
        b: value # a comment
        ---
        """)
        #expect(doc.fields["a"] == .scalar("value # not a comment"))
        #expect(doc.fields["b"] == .scalar("value"))
    }

    @Test func singleQuotedScalarIsVerbatim() throws {
        let doc = try FrontmatterParser.parse("""
        ---
        a: 'raw \\\\ backslashes'
        ---
        """)
        #expect(doc.fields["a"] == .scalar("raw \\\\ backslashes"))
    }

    @Test func commentsAndBlankLinesIgnored() throws {
        let doc = try FrontmatterParser.parse("""
        ---
        # A comment
        id: x

        version: 1
        ---
        """)
        #expect(doc.fields.count == 2)
        #expect(doc.fieldLines["version"] == 5)
    }

    @Test func missingOpeningFenceFails() {
        #expect(throws: FrontmatterError.self) {
            try FrontmatterParser.parse("id: x\n---\n")
        }
    }

    @Test func missingClosingFenceFailsWithLine() {
        do {
            _ = try FrontmatterParser.parse("---\nid: x\n")
            Issue.record("expected an error")
        } catch let error as FrontmatterError {
            #expect(error.message.contains("closing"))
        } catch {
            Issue.record("unexpected error type")
        }
    }

    @Test func unterminatedQuoteFailsWithLineNumber() {
        do {
            _ = try FrontmatterParser.parse("---\nid: x\nsummary: \"oops\n---\n")
            Issue.record("expected an error")
        } catch let error as FrontmatterError {
            #expect(error.line == 3)
            #expect(error.message.contains("unterminated"))
        } catch {
            Issue.record("unexpected error type")
        }
    }

    @Test func rejectsYamlAnchors() {
        #expect(throws: FrontmatterError.self) {
            try FrontmatterParser.parse("---\nid: &anchor value\n---\n")
        }
    }

    @Test func rejectsMixedBlockListAndMap() {
        #expect(throws: FrontmatterError.self) {
            try FrontmatterParser.parse("""
            ---
            when:
              app: [a]
              - item
            ---
            """)
        }
    }

    @Test func rejectsDeeperNesting() {
        #expect(throws: FrontmatterError.self) {
            try FrontmatterParser.parse("""
            ---
            when:
              nested:
                too: deep
            ---
            """)
        }
    }
}
