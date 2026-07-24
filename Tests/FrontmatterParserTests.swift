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

    // MARK: Block lists of maps (providers.yaml / roles.yaml records)

    @Test func parsesBlockListOfMaps() throws {
        let doc = try FrontmatterParser.parse("""
        ---
        providers:
          - id: aaa
            name: "First One"
            fallbacks: [bbb, ccc]
          # a comment between records
          - id: bbb
            temperature: 0.7
        ---
        """)
        guard case .mapList(let items) = doc.fields["providers"] else {
            Issue.record("expected mapList, got \(String(describing: doc.fields["providers"]))")
            return
        }
        #expect(items.count == 2)
        #expect(items[0]["id"] == .scalar("aaa"))
        #expect(items[0]["name"] == .scalar("First One"))
        #expect(items[0]["fallbacks"] == .list(["bbb", "ccc"]))
        #expect(items[1]["id"] == .scalar("bbb"))
        #expect(items[1]["temperature"] == .scalar("0.7"))
        // Line numbers survive for per-record validation errors.
        #expect(doc.fieldLines["providers.0.id"] == 3)
        #expect(doc.fieldLines["providers.1.temperature"] == 8)
    }

    @Test func urlListItemsStayScalars() throws {
        // "https://x.com" contains a colon but is not `key: value` (no space
        // after the colon) — it must remain a plain scalar list item.
        let doc = try FrontmatterParser.parse("""
        ---
        sources:
          - https://example.com/a
          - https://example.com/b
        ---
        """)
        #expect(doc.fields["sources"] == .list(["https://example.com/a", "https://example.com/b"]))
    }

    @Test func rejectsMixingRecordsWithPlainItems() {
        #expect(throws: FrontmatterError.self) {
            try FrontmatterParser.parse("""
            ---
            providers:
              - id: aaa
              - plain item
            ---
            """)
        }
    }

    @Test func rejectsUnindentedRecordContinuation() {
        #expect(throws: FrontmatterError.self) {
            try FrontmatterParser.parse("""
            ---
            providers:
              - id: aaa
              name: not indented under the dash
            ---
            """)
        }
    }

    @Test func rejectsBlockNestingInsideRecord() {
        #expect(throws: FrontmatterError.self) {
            try FrontmatterParser.parse("""
            ---
            providers:
              - id: aaa
                nested:
            ---
            """)
        }
    }
}
