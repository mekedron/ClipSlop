import Foundation

/// Default engine content, written to `~/.clipslop/` on first run. Seeds are
/// string literals rather than bundle resources: SwiftPM's `.process` rule
/// flattens resource subdirectories, and the content ends up as plain files
/// on disk anyway — this way there is no bundle-lookup failure mode.
///
/// A seed is written only when its file does not exist. User edits are never
/// overwritten.
enum EngineSeedContent {
    static func seedIfNeeded() {
        Constants.Engine.ensureDirectoriesExist()
        for (relativePath, content) in seeds {
            let url = Constants.Engine.rootDirectory.appendingPathComponent(relativePath)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static let seeds: [(path: String, content: String)] = [
        ("config.yaml", engineConfig),
        ("core/identity.md", identity),
        ("core/writing-style.md", writingStyle),
        ("core/constraints.md", constraints),
        ("core/aliases.md", aliases),
        ("workflows/base/base.generation.md", baseGeneration),
        ("workflows/base/base.reply.md", baseReply),
        ("workflows/base/base.write.md", baseWrite),
        ("workflows/base/base.continue.md", baseContinue),
        ("workflows/base/base.instruct.md", baseInstruct),
        ("workflows/base/base.rewrite.md", baseRewrite),
        ("workflows/reply.thread.md", replyThread),
        ("workflows/reply.thread.web.md", replyThreadWeb),
        ("workflows/comment.social.md", commentSocial),
        ("workflows/continue.draft.md", continueDraft),
        ("workflows/instruct.selection.md", instructSelection),
        ("workflows/rewrite.selection.md", rewriteSelection),
        ("workflows/adapt.selection.md", adaptSelection),
    ]

    // MARK: - Engine config

    static let engineConfig = """
    ---
    # Magic Button engine tuning. Values outside their safe range are clamped;
    # unknown keys are ignored (both show as warnings in Settings → Magic).
    # Delete a line to fall back to its default. "Reset to Default" restores
    # this whole file.

    # Snapshot capture: total deadline for reading the screen on a press.
    capture_deadline_ms: 1600

    # Accessibility call budgets. Native apps need few calls; web pages
    # (Chromium wraps everything in groups) need many.
    ax_call_budget: 350
    web_call_budget: 900

    # Tree traversal depths and widths.
    max_gather_depth: 6
    max_web_depth: 30
    max_siblings_per_level: 16
    max_web_children_per_node: 60

    # How much surrounding text reaches the prompt, and how the web walk
    # splits it: text before the field (a chat's newest messages) vs after.
    surrounding_max_chars: 6000
    web_before_keep_chars: 4500
    web_after_keep_chars: 1000

    # Cap on reading the focused field's own content.
    field_value_max_chars: 50000

    # Post-insert toast auto-dismiss, in seconds.
    toast_dismiss_seconds: 8

    # Character ceiling for generated output when the routed workflow card
    # sets no output.max_chars of its own. The model is told this number and
    # the verifier warns when the output exceeds it. A card's explicit
    # output.max_chars always wins over this default.
    output_max_chars_default: 1200

    # Warm frontmost-app observer: keeps cheap context (URL, window title,
    # focused field) fresh between presses and pre-builds Chromium's
    # accessibility tree on app switch. Set warm_observer_enabled: 0 to turn
    # the subsystem off entirely.
    warm_observer_enabled: 1
    warm_context_ttl_seconds: 30
    observer_debounce_ms: 200

    # Fast-mode chip planner: when routing is ambiguous (the press would
    # show chips), one tiny capped model call may pick the obvious chip for
    # you — an empty field on a conversation view means "reply", and the
    # model can see that where the routing rules cannot. Hard time cap in
    # milliseconds; on timeout / unsure / error the chip panel shows as
    # usual. 0 disables the planner (always ask). The always-ask hotkey
    # (forced chips) never uses the planner.
    planner_timeout_ms: 900

    # Full-content debug log: one markdown file per press in logs/debug/
    # with the complete snapshot, the exact prompt, and the raw model
    # output. Unlike the always-on contentless traces these files contain
    # your REAL screen content and drafts — that is the privacy tradeoff.
    # Pruned automatically after 7 days. Same switch as the checkbox in
    # Settings -> Magic (this file is the authority).
    debug_log_enabled: 0

    # Apps/domains whose text must never reach a cloud model (P7).
    # Entries match the app bundle id as a substring, or the page's domain
    # exactly / by suffix. A press there uses a local provider from the
    # role's chain, or refuses with a clear message when none exists.
    # Example: [telegram, com.tinyspeck.slackmacgap, gmail.com]
    no_cloud: []
    ---
    """

    // MARK: - Core files

    static let identity = """
    # Who I am

    <!-- ClipSlop reads this file into every Magic Button generation.
         Edit freely — it is yours. Short, factual lines work best. -->

    - Name:
    - Role:
    - Company / context:
    - Languages I write in:
    """

    static let writingStyle = """
    # How I write

    <!-- Voice rules per language and channel. Rules only — concrete example
         messages are picked up separately. Keep each rule one line. -->

    ## General
    - Match the formality of the conversation; when unsure, professional-warm.
    - Get to the point in the first sentence.

    ## Email
    - Short greeting, no throat-clearing openers.

    ## Chat (Slack, messengers)
    - Casual, compact, no sign-offs.

    ## Social (LinkedIn, X)
    - One or two sentences. No hashtag spam, no exclamation stacking.
    """

    static let constraints = """
    # Hard constraints

    <!-- These rules apply to EVERY generation. Two bullet shapes are also
         machine-checked before any text is inserted:

           - never say: "some exact phrase"
           - never match: /some regular expression/

         Everything else in this file is prose the model must follow but the
         checker ignores. -->

    - Never commit me to payments, meetings, or deadlines that are not in my draft.
    - Never invent facts, numbers, or names that are not in the context.

    <!-- Examples of checkable rules (remove the comment markers to enable):
    - never say: "as an AI"
    - never match: /\\bbest regards\\b/
    -->
    """

    static let aliases = """
    # People and names

    <!-- Map short names or nicknames to who they actually are, so drafts
         address people correctly. One per line:

           - Vika = Viktoria Lahtinen (design lead at Aikamatkat)
    -->
    """

    // MARK: - Base workflow layer

    /// Header comment included in every seeded workflow file.
    private static let workflowHeader = """
    # ClipSlop workflow. The frontmatter between the --- fences uses a simple
    # YAML subset: `key: value`, flow lists [a, b], flow maps {k: v}, and one
    # level of nesting under `when:`. The markdown body below the fences is
    # the instruction text the model receives when this workflow runs.
    """

    static let baseGeneration = """
    ---
    \(workflowHeader)
    id: base.generation
    kind: workflow
    mode: direct
    version: 1
    abstract: true
    ---
    ## Rules
    - You write AS the user, in their voice, ready to send. Never mention AI, drafts, or these instructions.
    - Write in the language of the conversation on screen. If the user's draft or note is in a different language, translate it — the output must fit the conversation — unless the user explicitly asks otherwise.
    - Match the register and tone of the surface: email reads like email, chat like chat.
    - Never repeat back what is already written in the field or the thread.
    - Never introduce facts, numbers, names, or commitments that are not in the provided context.
    - Output plain text only: no markdown headers, no code fences, no surrounding quotes.
    """

    static let baseReply = """
    ---
    \(workflowHeader)
    id: base.reply
    kind: workflow
    mode: direct
    version: 1
    extends: base.generation
    summary: "Reply to what's on screen"
    intents: [reply]
    when:
      field.state: [empty]
    ---
    ## Rules
    - The surrounding content is a conversation or post; write the user's reply to it.
    - Address the most recent message directed at the user.
    - Keep the reply proportionate: a short message earns a short reply.
    """

    static let baseWrite = """
    ---
    \(workflowHeader)
    id: base.write
    kind: workflow
    mode: direct
    version: 1
    extends: base.generation
    summary: "Write from scratch"
    intents: [write]
    when:
      field.state: [empty]
    ---
    ## Rules
    - The field is empty and there is no clear conversation to answer; draft what this field is for (use its placeholder and the page as cues).
    - Prefer a complete, minimal first version over an outline.
    """

    static let baseContinue = """
    ---
    \(workflowHeader)
    id: base.continue
    kind: workflow
    mode: direct
    version: 1
    extends: base.generation
    summary: "Continue my draft"
    intents: [continue]
    when:
      field.state: [draft]
    ---
    ## Rules
    - The field holds the user's unfinished draft. Continue it in the same direction and voice.
    - Continue in the language the draft itself is written in — a continuation must read as one text — even when the conversation around it is in another language.
    - Output ONLY the continuation — do not repeat any part of the existing draft.
    - Your output is glued directly onto the draft's last character: begin with whatever space or punctuation the seam needs to read correctly.
    - If the draft ends mid-sentence, complete that sentence first.
    """

    static let baseInstruct = """
    ---
    \(workflowHeader)
    id: base.instruct
    kind: workflow
    mode: direct
    version: 1
    extends: base.generation
    summary: "Do what my selection says"
    intents: [instruct]
    when:
      field.state: [selection]
      selection: [instruction, mixed]
    ---
    ## Rules
    - The selected text is the user's request TO YOU — an instruction, material, or both. It will be replaced by your output.
    - Obey its directives, incorporate its material, and discard the request's own wording unless it is clearly meant to appear verbatim.
    - Your output must fit the spot where the selection sits: it replaces exactly the selected text inside the surrounding draft.
    """

    static let baseRewrite = """
    ---
    \(workflowHeader)
    id: base.rewrite
    kind: workflow
    mode: direct
    version: 1
    extends: base.generation
    summary: "Rewrite my selection"
    intents: [rewrite]
    when:
      field.state: [selection]
      selection: [material]
    ---
    ## Rules
    - The selected text is rough content the user wants rewritten against the context. Your output replaces it.
    - Preserve the meaning and all facts; improve clarity, flow, and tone for this surface.
    - Write in the language of the conversation on screen — if the selection is in another language, translating it IS the job. Only keep the selection's language when there is no conversation to match or the user asks for it.
    - Keep roughly the same length unless the selection is obviously bloated.
    """

    // MARK: - Named workflows

    static let replyThread = """
    ---
    \(workflowHeader)
    id: reply.thread
    kind: workflow
    mode: direct
    version: 1
    extends: base.reply
    priority: 70
    summary: "Reply in this thread"
    intents: [reply]
    when:
      app: [com.apple.mail, com.tinyspeck.slackmacgap]
      field.state: [empty, draft]
    ---
    ## Rules
    - This is a mail or team-chat thread: answer every question the last message asks, in order.
    - Mirror the sender's greeting/sign-off conventions; in chat, use neither.
    - If the thread asks for something the user has not decided, leave a clearly marked gap ("…") rather than inventing an answer.
    """

    static let replyThreadWeb = """
    ---
    \(workflowHeader)
    id: reply.thread.web
    kind: workflow
    mode: direct
    version: 1
    extends: reply.thread
    priority: 70
    summary: "Reply in this thread"
    intents: [reply]
    when:
      url: "(mail\\\\.google\\\\.com|outlook\\\\.(live|office)\\\\.com)"
      field.state: [empty, draft]
    ---
    """

    static let commentSocial = """
    ---
    \(workflowHeader)
    id: comment.social
    kind: workflow
    mode: direct
    version: 1
    extends: base.generation
    priority: 70
    surface: public
    summary: "Comment in your voice"
    intents: [comment, reply, instruct]
    when:
      url: "(linkedin\\\\.com/(feed|posts|pulse)|x\\\\.com/|twitter\\\\.com/)"
      field.state: [empty, draft, selection]
    output: {lang: match_context, max_chars: 400, format: plain}
    ---
    ## Rules
    - One or two sentences that add something: a perspective, a concrete experience, a sharp question. Never bare agreement.
    - Professional-warm. No hashtag spam, no emoji stacking, no "Great post!".
    - If the field holds a selected note, treat it as the user's brief for the comment: obey it, replace it.

    ## Anti-examples
    - "Great post! 🔥 Totally agree!!" — never.
    - "As someone passionate about innovation…" — never.
    """

    static let continueDraft = """
    ---
    \(workflowHeader)
    id: continue.draft
    kind: workflow
    mode: direct
    version: 1
    extends: base.continue
    priority: 60
    summary: "Continue my draft"
    intents: [continue]
    when:
      field.state: [draft]
    ---
    ## Rules
    - Read the draft's trajectory: what point is it building toward? Continue toward that point, not sideways.
    - Finish the thought in as little text as does it justice; do not pad toward a "complete essay".
    - Stop where the user would plausibly want to take over again.
    """

    static let instructSelection = """
    ---
    \(workflowHeader)
    id: instruct.selection
    kind: workflow
    mode: direct
    version: 1
    extends: base.instruct
    priority: 60
    summary: "Do what my selection says"
    intents: [instruct]
    when:
      field.state: [selection]
      selection: [instruction, mixed]
    ---
    ## Rules
    - Most seeds are MIXED: directives plus material in one note («согласен + упомяни бенчмарки», "agree + mention the benchmarks"). Obey the directives, weave in the material, drop the note's own phrasing.
    - Honor placement words ("сюда", "here", "tähän"): the output lands exactly where the selection sits.
    - Write in the language of the conversation on screen; with no conversation, the language of the draft around the selection — never the language of the instruction itself.
    """

    static let rewriteSelection = """
    ---
    \(workflowHeader)
    id: rewrite.selection
    kind: workflow
    mode: direct
    version: 1
    extends: base.rewrite
    priority: 60
    summary: "Rewrite my selection"
    intents: [rewrite]
    when:
      field.state: [selection]
      selection: [material]
    ---
    ## Rules
    - When the selection is the entire field, this is a full rewrite: restructure freely, keep every fact.
    - When it is a fragment, splice cleanly: the rewritten text must read naturally against what surrounds it.
    """

    static let adaptSelection = """
    ---
    \(workflowHeader)
    id: adapt.selection
    kind: workflow
    mode: direct
    version: 1
    extends: base.generation
    priority: 65
    summary: "Fit my selection to this page"
    intents: [adapt, rewrite]
    when:
      field.state: [selection]
      selection: [material, mixed]
    ---
    ## Rules
    - The selection is the user's finished message — it already says what they want to say. Deliver the SAME message, fitted to where it is about to be sent. Never an answer to it, never a reaction.
    - Fit the language: when the conversation or page around the field is in another language, translate so the reader never suspects the message was drafted in a different one.
    - Fit the register and format: chat stays compact and casual, email keeps its greeting and sign-off conventions, a comment matches the thread's tone.
    - Keep every fact, name, number, and link, and the message's order and intent. No additions, no summarizing, no new arguments.
    - With no readable context around the field, stay in the selection's own language and just make it clean and natural.

    ## Anti-examples
    - Replying to the selected message instead of adapting it — never.
    - "Improving" the argument, or adding politeness the user did not write — never.
    """
}
