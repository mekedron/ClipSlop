import Testing
@testable import ClipSlop

/// The CLI invocation shape — argv is the whole contract with the external
/// tool, so it is pinned here: model/effort passthrough, the MCP lockout,
/// and the `tool/model` identity split every consumer resolves through.
@Suite("CLI tool invocation")
struct CLIToolInvocationTests {

    private var claude: CLIToolDefinition { CLIToolDefinition.find(byID: "claude")! }

    @Test func modelIDSplitsIntoToolAndModel() {
        #expect(CLIToolDefinition.parseModelID("claude") == ("claude", nil))
        #expect(CLIToolDefinition.parseModelID("claude/sonnet") == ("claude", "sonnet"))
        #expect(CLIToolDefinition.parseModelID("claude/") == ("claude", nil))
        // The model part may itself contain slashes (vendor-prefixed ids).
        #expect(CLIToolDefinition.parseModelID("codex/openai/gpt-5.4") == ("codex", "openai/gpt-5.4"))
    }

    @Test func findResolvesTheToolThroughACombinedID() {
        #expect(CLIToolDefinition.find(byID: "claude/sonnet")?.id == "claude")
        #expect(CLIToolDefinition.find(byID: "nonexistent/sonnet") == nil)
    }

    @Test func claudeArgsAlwaysLockOutMCPServers() {
        let args = claude.buildArguments("hi", "sys", nil, nil, nil)
        #expect(args.contains("--strict-mcp-config"))
        #expect(args.first == "-p")
        #expect(!args.contains("--model"))
        #expect(!args.contains("--effort"))
    }

    @Test func claudeArgsCarryModelAndEffortWhenSet() throws {
        let args = claude.buildArguments("hi", "sys", nil, "sonnet", "low")
        let modelIndex = try #require(args.firstIndex(of: "--model"))
        #expect(args[modelIndex + 1] == "sonnet")
        let effortIndex = try #require(args.firstIndex(of: "--effort"))
        #expect(args[effortIndex + 1] == "low")
    }

    @Test func claudeArgsOmitTheEffortFlagForNone() {
        // "none" means "the tool's own default", not a literal flag value the
        // CLI would reject.
        let args = claude.buildArguments("hi", "sys", nil, "sonnet", "none")
        #expect(!args.contains("--effort"))
    }

    @Test func cliToolEffortValidatesThroughTheSharedField() {
        var config = AIProviderConfig(name: "Claude Code", providerType: .cliTool, modelID: "claude/sonnet")
        config.reasoningEffort = .low
        #expect(config.effectiveReasoningEffort == "low")
        // `.max` is not a claude `--effort` level — the shared validation
        // refuses it, so an invalid value can never fail a whole press.
        config.reasoningEffort = .max
        #expect(config.effectiveReasoningEffort == nil)
    }
}
