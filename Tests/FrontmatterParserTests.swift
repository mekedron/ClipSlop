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

    /// The `]`/`}` checks used to run before any comment was stripped, so the
    /// documented style below threw "flow list is missing its closing ']'" and
    /// disabled the whole card.
    @Test func flowCollectionsAcceptTrailingComments() throws {
        let doc = try FrontmatterParser.parse("""
        ---
        intents: [reply] # note
        output: {lang: en, max_chars: 400}   # another note
        ---
        """)
        #expect(doc.fields["intents"] == .list(["reply"]))
        #expect(doc.fields["output"] == .map([
            "lang": .scalar("en"), "max_chars": .scalar("400"),
        ]))
    }

    /// A '#' only opens a comment outside quotes and brackets.
    @Test func flowCollectionsKeepHashInsideBracketsAndQuotes() throws {
        let doc = try FrontmatterParser.parse("""
        ---
        tags: [c#, "a # b"]
        nested: {url: "x#y"} # trailing
        ---
        """)
        #expect(doc.fields["tags"] == .list(["c#", "a # b"]))
        #expect(doc.fields["nested"] == .map(["url": .scalar("x#y")]))
    }

    /// `stripFlowComment` runs on the same text as `splitFlowItems`, but only
    /// the latter tracked backslash escapes — so the two disagreed about where
    /// a quote ends. On the list below the comment stripper read the escaped
    /// `"` as CLOSING the quote, the `]` inside that entry as ending the flow
    /// list, and the ` #` in the next entry as starting a comment: a correctly
    /// escaped file was cut down to `["quote\"a]", "hash` and rejected with
    /// "missing its closing ']'", disabling the whole card.
    @Test func flowCollectionsTrackEscapedQuotesWhenStrippingComments() throws {
        let doc = try FrontmatterParser.parse("""
        ---
        no_cloud: ["quote\\"a]", "hash # b"]
        pair: {a: "x\\"]", b: "y # z"}
        ---
        """)
        #expect(doc.fields["no_cloud"] == .list(["quote\"a]", "hash # b"]))
        #expect(doc.fields["pair"] == .map(["a": .scalar("x\"]"), "b": .scalar("y # z")]))
    }

    /// Escapes must not cost the flow collections their real trailing comment:
    /// the `#` below still sits outside every quote and bracket.
    @Test func escapedQuotesStillAllowATrailingComment() throws {
        let doc = try FrontmatterParser.parse("""
        ---
        intents: ["say \\"hi\\"", other] # note
        output: {greeting: "say \\"hi\\" #1", lang: en}   # another note
        ---
        """)
        #expect(doc.fields["intents"] == .list(["say \"hi\"", "other"]))
        #expect(doc.fields["output"] == .map([
            "greeting": .scalar("say \"hi\" #1"), "lang": .scalar("en"),
        ]))
    }

    /// Only DOUBLE quotes process escapes — `parseScalar` documents
    /// single-quoted scalars as verbatim, so a `\\` inside them does not hide
    /// the closing `'` from the comment stripper either.
    @Test func singleQuotedFlowItemsAreVerbatimForCommentStripping() throws {
        let doc = try FrontmatterParser.parse("""
        ---
        paths: ['a\\', b] # note
        ---
        """)
        #expect(doc.fields["paths"] == .list(["a\\", "b"]))
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

    /// Last-wins on a repeated key lets a duplicated `when:` or `no_cloud:`
    /// change engine behaviour while the file still reports as valid — the
    /// opposite of the fail-visible contract.
    @Test func rejectsDuplicateTopLevelKeys() {
        do {
            _ = try FrontmatterParser.parse("---\nid: x\nsummary: \"a\"\nid: y\n---\n")
            Issue.record("expected an error")
        } catch let error as FrontmatterError {
            #expect(error.line == 4)
            #expect(error.message.contains("duplicate key 'id'"))
            #expect(error.message.contains("line 2"))
        } catch {
            Issue.record("unexpected error type")
        }
        // Block form counts too.
        #expect(throws: FrontmatterError.self) {
            try FrontmatterParser.parse("---\nwhen:\n  app: [a]\nwhen:\n  app: [b]\n---\n")
        }
    }

    /// Only TOP-LEVEL keys can duplicate each other. `fieldLines` doubles as the
    /// reporting namespace for nested entries and records them under dotted
    /// paths ("when.url"), while `splitKey` allows a dot in a key — so reading
    /// the duplicate check out of that same map refuses a file whose only sin is
    /// spelling a key the way a nested path happens to be spelled.
    @Test func aDottedTopLevelKeyIsNotADuplicateOfANestedPath() throws {
        let document = try FrontmatterParser.parse(
            "---\nwhen:\n  url: [a]\nwhen.url: literal\n---\n"
        )
        #expect(document.fields["when.url"] == .scalar("literal"))
        guard case .map(let when)? = document.fields["when"] else {
            Issue.record("expected 'when' to parse as a block map")
            return
        }
        #expect(when["url"] == .list(["a"]))
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

    /// A tab-indented nested key does not arrive as an indented line at all:
    /// block structure is decided by a two-SPACE prefix, so the tab ends its
    /// parent's block and the line is re-read as a brand-new top-level key.
    /// The file then means something the author never wrote, with no error
    /// anywhere — the one outcome a hot-reloaded, hand-edited tree may not
    /// produce. Named explicitly instead.
    @Test func rejectsTabIndentation() {
        let error = #expect(throws: FrontmatterError.self) {
            try FrontmatterParser.parse("""
            ---
            when:
            \turl: gmail.com
            ---
            """)
        }
        #expect(error?.line == 3)
        #expect(error?.message.contains("tab") == true)

        // Two spaces for the same document is the supported spelling.
        let parsed = try? FrontmatterParser.parse("""
        ---
        when:
          url: gmail.com
        ---
        """)
        #expect(parsed?.fields["when"] == .map(["url": .scalar("gmail.com")]))
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
