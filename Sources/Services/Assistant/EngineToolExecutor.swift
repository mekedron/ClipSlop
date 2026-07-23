import Foundation

/// Runs the Settings Assistant's Magic-engine tool calls. Mirrors
/// `PromptLibraryToolExecutor`: read-only tools execute directly, mutating
/// tools go through `makeProposal` (the Approve/Reject card) and `perform`
/// on approval.
///
/// Files-first (§15): every operation targets the engine tree under `root`
/// (the same `Constants.Engine` tree the press path hot-reloads by mtime),
/// and every write is validated with the engine's own parser BEFORE the file
/// is touched — a validation failure returns the line-numbered error to the
/// model and writes nothing. Store references are optional: when present
/// they are poked after a write so Settings badges refresh immediately;
/// tests pass none and point `root` at a temp directory.
@MainActor
final class EngineToolExecutor {

    struct Stores {
        var workflowStore: WorkflowStore?
        var coreStore: CoreFileStore?
        var configStore: EngineConfigStore?
        var roleStore: EngineRoleStore?
        var providerStore: ProviderStore?

        init(
            workflowStore: WorkflowStore? = nil,
            coreStore: CoreFileStore? = nil,
            configStore: EngineConfigStore? = nil,
            roleStore: EngineRoleStore? = nil,
            providerStore: ProviderStore? = nil
        ) {
            self.workflowStore = workflowStore
            self.coreStore = coreStore
            self.configStore = configStore
            self.roleStore = roleStore
            self.providerStore = providerStore
        }
    }

    private let root: URL
    private let logsDirectory: URL
    private let stores: Stores

    private var workflowsDirectory: URL { root.appendingPathComponent("workflows") }
    private var coreDirectory: URL { root.appendingPathComponent("core") }

    init(
        root: URL = Constants.Engine.rootDirectory,
        logsDirectory: URL? = nil,
        stores: Stores = Stores()
    ) {
        self.root = root
        self.logsDirectory = logsDirectory ?? root.appendingPathComponent("logs")
        self.stores = stores
    }

    // MARK: - Proposals (mutating tools)

    func makeProposal(for call: ToolCallRequest) throws -> ToolProposal {
        let args = arguments(call)
        switch call.name {
        case "write_workflow":
            let path = try requireString(args, "path")
            let content = try requireString(args, "content")
            let url = try EngineTools.confineWorkflow(path, under: root)
            let validation = Self.validateWorkflow(
                content: content, target: url, workflowsDirectory: workflowsDirectory
            )
            guard validation.errors.isEmpty else {
                throw ToolError(message: "Validation failed — nothing written:\n" + validation.errors.joined(separator: "\n"))
            }
            let existing = try? String(contentsOf: url, encoding: .utf8)
            var warnings: [String] = validation.warnings
            if path.hasPrefix("workflows/base/") {
                warnings.append("This edits the generic base layer that guarantees the button works everywhere.")
            }
            return ToolProposal(
                call: call,
                title: existing == nil
                    ? "Create workflow “\(validation.id ?? path)”"
                    : "Edit workflow “\(validation.id ?? path)”",
                fields: [ProposalField(label: path, oldValue: existing, newValue: content)],
                isDestructive: false,
                warning: warnings.isEmpty ? nil : warnings.joined(separator: " ")
            )

        case "delete_workflow":
            let path = try requireString(args, "path")
            let url = try EngineTools.confineWorkflow(path, under: root)
            guard let existing = try? String(contentsOf: url, encoding: .utf8) else {
                throw ToolError(message: "No workflow file at '\(path)'. Call list_engine_files for current paths.")
            }
            var warnings: [String] = []
            if let id = Self.workflowID(of: existing) {
                let dependents = Self.workflowsExtending(
                    id, in: workflowsDirectory, excluding: url
                )
                if !dependents.isEmpty {
                    warnings.append("Workflows extending '\(id)' will be disabled: \(dependents.joined(separator: ", ")).")
                }
            }
            if path.hasPrefix("workflows/base/") {
                warnings.append("This deletes part of the base layer.")
            }
            return ToolProposal(
                call: call,
                title: "Delete workflow file “\(path)”",
                fields: [ProposalField(label: path, oldValue: existing, newValue: nil)],
                isDestructive: true,
                warning: warnings.isEmpty ? nil : warnings.joined(separator: " ")
            )

        case "write_core_file":
            let name = try requireCoreFileName(args)
            let content = try requireString(args, "content")
            let url = coreFileURL(name)
            let existing = try? String(contentsOf: url, encoding: .utf8)
            var warning: String?
            if name == "constraints.md" {
                let rules = CoreFileStore.parseConstraints(content)
                warning = "constraints.md holds your hard rules — the verifier enforces them on every generation. This version defines \(rules.count) machine-checkable rule\(rules.count == 1 ? "" : "s")."
            } else if name == "system-prompt.md" {
                warning = "A non-empty system-prompt.md replaces the engine's built-in generation system prompt entirely."
            }
            return ToolProposal(
                call: call,
                title: "\(existing == nil ? "Create" : "Edit") \(name == "system-prompt.md" ? "" : "core/")\(name)",
                fields: [ProposalField(label: name, oldValue: existing, newValue: content)],
                isDestructive: false,
                warning: warning
            )

        case "set_config":
            let sets = try requireConfigSets(args)
            let currentText = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
            let edit = try Self.applyConfigEdits(to: currentText, sets: sets)
            return ToolProposal(
                call: call,
                title: "Change engine config",
                fields: edit.display.map {
                    ProposalField(label: $0.key, oldValue: $0.old ?? "(default)", newValue: $0.new ?? "(reset to default)")
                },
                isDestructive: false,
                warning: nil
            )

        case "set_role":
            let change = try resolveRoleChange(args)
            var fields: [ProposalField] = []
            let names = { (id: UUID?) -> String in
                guard let id else { return "App default" }
                return change.providers.first { $0.id == id }?.name ?? id.uuidString
            }
            if change.new.provider != change.old.provider {
                fields.append(ProposalField(label: "Provider", oldValue: names(change.old.provider), newValue: names(change.new.provider)))
            }
            if change.new.fallbacks != change.old.fallbacks {
                fields.append(ProposalField(
                    label: "Fallbacks",
                    oldValue: change.old.fallbacks.isEmpty ? "None" : change.old.fallbacks.map(names).joined(separator: " → "),
                    newValue: change.new.fallbacks.isEmpty ? "None" : change.new.fallbacks.map(names).joined(separator: " → ")
                ))
            }
            if change.new.timeoutSeconds != change.old.timeoutSeconds {
                fields.append(ProposalField(
                    label: "Timeout",
                    oldValue: change.old.timeoutSeconds.map { "\($0) s" } ?? "Default",
                    newValue: change.new.timeoutSeconds.map { "\($0) s" } ?? "Default"
                ))
            }
            if change.new.minCostClass != change.old.minCostClass {
                fields.append(ProposalField(
                    label: "Min cost class",
                    oldValue: change.old.minCostClass?.rawValue ?? "None",
                    newValue: change.new.minCostClass?.rawValue ?? "None"
                ))
            }
            guard !fields.isEmpty else {
                throw ToolError(message: "Nothing would change — the binding already has these values.")
            }
            return ToolProposal(
                call: call,
                title: "Change role “\(change.role.rawValue)”",
                fields: fields,
                isDestructive: false,
                warning: change.warning
            )

        case "set_provider_metadata":
            let change = try resolveProviderMetadataChange(args)
            var fields: [ProposalField] = []
            if let locality = change.locality {
                fields.append(ProposalField(
                    label: "Locality",
                    oldValue: change.current.locality?.rawValue ?? "derived (\(change.current.effectiveLocality.rawValue))",
                    newValue: locality.map(\.rawValue) ?? "derived"
                ))
            }
            if let costClass = change.costClass {
                fields.append(ProposalField(
                    label: "Cost class",
                    oldValue: change.current.costClass?.rawValue ?? "derived (\(change.current.effectiveCostClass.rawValue))",
                    newValue: costClass.map(\.rawValue) ?? "derived"
                ))
            }
            guard !fields.isEmpty else {
                throw ToolError(message: "Provide locality and/or cost_class to change.")
            }
            return ToolProposal(
                call: call,
                title: "Edit provider “\(change.current.name)” metadata",
                fields: fields,
                isDestructive: false,
                warning: change.locality != nil
                    ? "Locality is the privacy data path: no_cloud surfaces only accept providers whose locality is local."
                    : nil
            )

        default:
            throw ToolError(message: "Unknown tool '\(call.name)'.")
        }
    }

    // MARK: - Execution

    func perform(_ call: ToolCallRequest) throws -> String {
        let args = arguments(call)
        switch call.name {
        // MARK: Read-only
        case "list_engine_files":
            return listEngineFiles()

        case "read_engine_file":
            let path = try requireString(args, "path")
            let url = try EngineTools.confineReadable(path, under: root)
            guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                throw ToolError(message: "'\(path)' does not exist. Call list_engine_files for what does.")
            }
            return content

        case "engine_status":
            return engineStatus()

        case "read_traces":
            return readTraces(args)

        case "explain_press":
            let (traces, _) = TraceInspector.loadTraces(from: logsDirectory)
            guard !traces.isEmpty else {
                throw ToolError(message: "No press traces recorded yet — press the Magic Button first.")
            }
            let idPrefix = args["trace_id"]?.stringValue
            guard let trace = TraceInspector.find(idPrefix, in: traces) else {
                throw ToolError(message: "No trace matches id '\(idPrefix ?? "")'. Call read_traces for current ids.")
            }
            return TraceInspector.explain(trace)

        case "trace_stats":
            return TraceStats.load(from: logsDirectory).markdown()

        case "spend_summary":
            return spendSummary()

        // MARK: Mutating (already approved by the user at this point)
        case "write_workflow":
            let path = try requireString(args, "path")
            let content = try requireString(args, "content")
            let url = try EngineTools.confineWorkflow(path, under: root)
            // Re-validate at execution time — the catalog may have changed
            // between the proposal and the approval.
            let validation = Self.validateWorkflow(
                content: content, target: url, workflowsDirectory: workflowsDirectory
            )
            guard validation.errors.isEmpty else {
                throw ToolError(message: "Validation failed — nothing written:\n" + validation.errors.joined(separator: "\n"))
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
            stores.workflowStore?.reloadIfChanged()
            return success(
                ["status": .string("written"), "path": .string(path), "id": .string(validation.id ?? "")],
                warnings: validation.warnings
            )

        case "delete_workflow":
            let path = try requireString(args, "path")
            let url = try EngineTools.confineWorkflow(path, under: root)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ToolError(message: "No workflow file at '\(path)'.")
            }
            try FileManager.default.removeItem(at: url)
            stores.workflowStore?.reloadIfChanged()
            return success(["status": .string("deleted"), "path": .string(path)])

        case "write_core_file":
            let name = try requireCoreFileName(args)
            let content = try requireString(args, "content")
            let url = coreFileURL(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
            stores.coreStore?.reloadIfChanged()
            var payload: [String: JSONValue] = ["status": .string("written"), "name": .string(name)]
            if name == "constraints.md" {
                payload["machine_checkable_rules"] = .int(CoreFileStore.parseConstraints(content).count)
            }
            return success(payload)

        case "set_config":
            let sets = try requireConfigSets(args)
            let currentText = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
            let edit = try Self.applyConfigEdits(to: currentText, sets: sets)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try edit.text.write(to: configURL, atomically: true, encoding: .utf8)
            stores.configStore?.reloadIfChanged()
            return success(
                ["status": .string("written"), "keys": .array(sets.map { .string($0.key) })],
                warnings: edit.unrelatedWarnings
            )

        case "set_role":
            let change = try resolveRoleChange(args)
            var bindings = change.allBindings
            if change.new.isEmpty {
                bindings.removeValue(forKey: change.role)
            } else {
                bindings[change.role] = change.new
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try RolesFile.serialize(bindings).write(to: rolesURL, atomically: true, encoding: .utf8)
            stores.roleStore?.reloadIfChanged()
            var payload: [String: JSONValue] = [
                "status": .string("written"), "role": .string(change.role.rawValue),
            ]
            if let warning = change.warning { payload["warnings"] = .array([.string(warning)]) }
            return JSONValue.object(payload).jsonString()

        case "set_provider_metadata":
            let change = try resolveProviderMetadataChange(args)
            var providers = change.allProviders
            guard let index = providers.firstIndex(where: { $0.id == change.current.id }) else {
                throw ToolError(message: "Provider disappeared while editing — call engine_status and retry.")
            }
            if let locality = change.locality { providers[index].locality = locality }
            if let costClass = change.costClass { providers[index].costClass = costClass }
            try ProvidersFile.serialize(providers).write(to: providersURL, atomically: true, encoding: .utf8)
            stores.providerStore?.reloadIfChanged()
            return success(["status": .string("written"), "provider": .string(change.current.name)])

        default:
            throw ToolError(message: "Unknown tool '\(call.name)'.")
        }
    }

    /// A short human-readable label for the read-only activity row.
    func activityLabel(for call: ToolCallRequest) -> String {
        switch call.name {
        case "list_engine_files": "Read engine file list"
        case "read_engine_file": "Read \(arguments(call)["path"]?.stringValue ?? "engine file")"
        case "engine_status": "Checked engine status"
        case "read_traces": "Read press traces"
        case "explain_press": "Explained a press from its trace"
        case "trace_stats": "Aggregated trace stats"
        case "spend_summary": "Read the spend ledger"
        default: call.name
        }
    }

    // MARK: - Read-only implementations

    private var configURL: URL { root.appendingPathComponent("config.yaml") }
    private var providersURL: URL { root.appendingPathComponent("providers.yaml") }
    private var rolesURL: URL { root.appendingPathComponent("roles.yaml") }

    private func coreFileURL(_ name: String) -> URL {
        name == "system-prompt.md"
            ? root.appendingPathComponent(name)
            : coreDirectory.appendingPathComponent(name)
    }

    private func listEngineFiles() -> String {
        var top: [JSONValue] = []
        for name in ["config.yaml", "system-prompt.md", "providers.yaml", "roles.yaml"] {
            let exists = FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
            top.append(.object(["path": .string(name), "exists": .bool(exists)]))
        }

        var core: [JSONValue] = []
        let coreNames = ((try? FileManager.default.contentsOfDirectory(atPath: coreDirectory.path)) ?? [])
            .filter { $0.hasSuffix(".md") }.sorted()
        for name in coreNames {
            core.append(.string("core/\(name)"))
        }

        // One shared load gives resolution errors (duplicates, broken
        // extends) on top of per-file parse errors.
        let (_, loadErrors) = WorkflowStore.load(from: workflowsDirectory)
        var errorsByPath: [String: [String]] = [:]
        for error in loadErrors where !error.isWarning {
            guard let fileURL = error.fileURL else { continue }
            errorsByPath[fileURL.standardizedFileURL.path, default: []].append(
                (error.line.map { "line \($0): " } ?? "") + error.message
            )
        }

        var workflows: [JSONValue] = []
        for fileURL in WorkflowStore.markdownFiles(in: workflowsDirectory) {
            let relative = "workflows/" + fileURL.standardizedFileURL.path
                .replacingOccurrences(of: workflowsDirectory.standardizedFileURL.path + "/", with: "")
            var entry: [String: JSONValue] = ["path": .string(relative)]
            if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
                if let id = Self.workflowID(of: text) {
                    entry["id"] = .string(id)
                }
                if Self.isAbstract(text) {
                    entry["abstract"] = .bool(true)
                }
            }
            if let errors = errorsByPath[fileURL.standardizedFileURL.path] {
                entry["disabled"] = .bool(true)
                entry["errors"] = .array(errors.map { .string($0) })
            }
            workflows.append(.object(entry))
        }

        return JSONValue.object([
            "top_level": .array(top),
            "core": .array(core),
            "workflows": .array(workflows),
        ]).jsonString()
    }

    private func engineStatus() -> String {
        var status: [String: JSONValue] = [:]

        // Workflows.
        let (catalog, loadErrors) = WorkflowStore.load(from: workflowsDirectory)
        status["workflows_loaded"] = .int(catalog.workflows.count)
        let problems = loadErrors.map { error -> JSONValue in
            var text = error.message
            if let line = error.line { text = "line \(line): \(text)" }
            if let file = error.fileURL?.lastPathComponent { text = "\(file): \(text)" }
            return .string((error.isWarning ? "warning: " : "") + text)
        }
        if !problems.isEmpty { status["workflow_problems"] = .array(problems) }

        // Config.
        if let text = try? String(contentsOf: configURL, encoding: .utf8) {
            let (_, warnings) = MagicEngineConfig.parse(text)
            if !warnings.isEmpty {
                status["config_warnings"] = .array(warnings.map { .string($0) })
            }
        } else {
            status["config_warnings"] = .array([.string("config.yaml missing — defaults in effect")])
        }

        // Providers (no secrets: providers.yaml never contains keys).
        let providersResult = parsedProviders()
        status["providers"] = .array(providersResult.providers.map { provider in
            .object([
                "id": .string(provider.id.uuidString),
                "name": .string(provider.name),
                "type": .string(provider.providerType.rawValue),
                "model": .string(provider.modelID),
                "default": .bool(provider.isDefault),
                "locality": .string(provider.locality?.rawValue ?? "derived:\(provider.effectiveLocality.rawValue)"),
                "cost_class": .string(provider.costClass?.rawValue ?? "derived:\(provider.effectiveCostClass.rawValue)"),
                "tool_calling": .bool(provider.providerType.supportsToolCalling),
            ])
        })
        if !providersResult.warnings.isEmpty {
            status["provider_warnings"] = .array(providersResult.warnings.map { .string($0) })
        }

        // Roles.
        let rolesResult = parsedRoles()
        var roles: [String: JSONValue] = [:]
        for role in EngineRole.allCases {
            let binding = rolesResult.bindings[role] ?? RoleBinding()
            var entry: [String: JSONValue] = [:]
            switch EngineRoleStore.resolve(role: role, binding: binding, providers: providersResult.providers) {
            case .resolved(let provider):
                entry["resolves_to"] = .string(provider.name)
            case .refusedBelowMinCost(let min):
                entry["resolves_to"] = .string("REFUSES: nothing in the chain meets min_cost_class \(min.rawValue)")
            case .noneAvailable:
                entry["resolves_to"] = .string("REFUSES: no capable provider configured")
            }
            if let provider = binding.provider {
                entry["bound_provider"] = .string(
                    providersResult.providers.first { $0.id == provider }?.name ?? provider.uuidString
                )
            }
            if !binding.fallbacks.isEmpty {
                entry["fallbacks"] = .array(binding.fallbacks.map { id in
                    .string(providersResult.providers.first { $0.id == id }?.name ?? id.uuidString)
                })
            }
            if let timeout = binding.timeoutSeconds { entry["timeout_seconds"] = .int(timeout) }
            if let min = binding.minCostClass { entry["min_cost_class"] = .string(min.rawValue) }
            roles[role.rawValue] = .object(entry)
        }
        status["roles"] = .object(roles)
        if !rolesResult.warnings.isEmpty {
            status["role_warnings"] = .array(rolesResult.warnings.map { .string($0) })
        }

        return JSONValue.object(status).jsonString()
    }

    private func readTraces(_ args: [String: JSONValue]) -> String {
        let (traces, skipped) = TraceInspector.loadTraces(from: logsDirectory)
        var filter = TraceInspector.Filter()
        if case .int(let count)? = args["count"] { filter.limit = count }
        filter.app = args["app"]?.stringValue
        filter.outcomePrefix = args["outcome_prefix"]?.stringValue
        filter.presentation = args["presentation"]?.stringValue
        filter.situationContains = args["situation_contains"]?.stringValue
        filter.verifierFailed = args["verifier_failed"]?.boolValue
        let matched = TraceInspector.filter(traces, filter)

        struct Payload: Encodable {
            let total_stored: Int
            let matched: Int
            let skipped_old_schema: Int
            let traces: [PressTrace]
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = Payload(
            total_stored: traces.count, matched: matched.count,
            skipped_old_schema: skipped, traces: matched
        )
        guard let data = try? encoder.encode(payload),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    private func spendSummary() -> String {
        let records = SpendLedger.load(from: logsDirectory)
        guard !records.isEmpty else { return "No spend recorded yet." }
        let totals = SpendLedger.totals(records: records)
        var out = "| role | today in/out | month in/out | |\n|---|---|---|---|\n"
        for (role, t) in totals.sorted(by: { $0.key < $1.key }) {
            out += "| \(role) | \(t.todayInput)/\(t.todayOutput) | \(t.monthInput)/\(t.monthOutput) | \(t.anyEstimated ? "≈ some estimated" : "") |\n"
        }
        out += "\nTokens only — ClipSlop keeps no dollar price tables. \(records.count) generation(s) recorded."
        return out
    }

    // MARK: - Workflow validation (pure)

    /// Validates a workflow write with the engine's own load path: parse the
    /// new content, then re-resolve the whole catalog with it overlaid.
    /// `errors` non-empty → the write must be rejected. Errors that would
    /// appear on *other* files (a child losing its parent because this file's
    /// id changed) come back as warnings — those files become visibly
    /// disabled, which is the engine's normal failure mode, but the user
    /// should hear about it.
    nonisolated static func validateWorkflow(
        content: String,
        target: URL,
        workflowsDirectory: URL
    ) -> (id: String?, errors: [String], warnings: [String]) {
        // 1. The file itself must parse — same path as WorkflowStore.load.
        let newRaw: RawWorkflow
        var warnings: [String] = []
        do {
            let document = try FrontmatterParser.parse(content)
            let (card, explicitKeys, cardWarnings) = try WorkflowCardParser.make(from: document)
            warnings.append(contentsOf: cardWarnings)
            newRaw = RawWorkflow(
                card: card, explicitKeys: explicitKeys,
                body: document.body, fileURL: target
            )
        } catch let error as FrontmatterError {
            return (nil, ["line \(error.line): \(error.message)"], warnings)
        } catch {
            return (nil, [error.localizedDescription], warnings)
        }

        // 2. Resolve the catalog with the new file overlaid (and once
        // without, to attribute pre-existing breakage correctly).
        let targetPath = target.standardizedFileURL.path
        var others: [RawWorkflow] = []
        for fileURL in WorkflowStore.markdownFiles(in: workflowsDirectory)
        where fileURL.standardizedFileURL.path != targetPath {
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8),
                  let document = try? FrontmatterParser.parse(text),
                  let (card, explicitKeys, _) = try? WorkflowCardParser.make(from: document)
            else { continue }  // Already disabled; not this write's problem.
            others.append(RawWorkflow(
                card: card, explicitKeys: explicitKeys,
                body: document.body, fileURL: fileURL
            ))
        }

        let baseline = Set(WorkflowResolver.resolve(others).errors.map { "\($0.workflowID ?? ""):\($0.message)" })
        let combined = WorkflowResolver.resolve(others + [newRaw]).errors

        var errors: [String] = []
        for error in combined where !error.isWarning {
            let key = "\(error.workflowID ?? ""):\(error.message)"
            let isTargets = error.fileURL?.standardizedFileURL.path == targetPath
                || error.workflowID == newRaw.card.id
            if isTargets {
                errors.append(error.message)
            } else if !baseline.contains(key) {
                let file = error.fileURL?.lastPathComponent ?? "?"
                warnings.append("side effect — \(file): \(error.message)")
            }
        }
        return (newRaw.card.id, errors, warnings)
    }

    /// The `id:` of a workflow file, if it parses at all.
    nonisolated static func workflowID(of content: String) -> String? {
        guard let document = try? FrontmatterParser.parse(content),
              case .scalar(let id)? = document.fields["id"]
        else { return nil }
        return id
    }

    private nonisolated static func isAbstract(_ content: String) -> Bool {
        guard let document = try? FrontmatterParser.parse(content),
              case .scalar("true")? = document.fields["abstract"]
        else { return false }
        return true
    }

    /// Ids of workflows that directly `extends` `id` (for delete warnings).
    nonisolated static func workflowsExtending(
        _ id: String, in workflowsDirectory: URL, excluding excluded: URL
    ) -> [String] {
        var dependents: [String] = []
        let excludedPath = excluded.standardizedFileURL.path
        for fileURL in WorkflowStore.markdownFiles(in: workflowsDirectory)
        where fileURL.standardizedFileURL.path != excludedPath {
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8),
                  let document = try? FrontmatterParser.parse(text),
                  case .scalar(let parent)? = document.fields["extends"], parent == id,
                  case .scalar(let childID)? = document.fields["id"]
            else { continue }
            dependents.append(childID)
        }
        return dependents.sorted()
    }

    // MARK: - Config editing (pure)

    struct ConfigEdit: Sendable {
        let text: String
        /// Per-key before→after for the proposal card (nil = default).
        let display: [(key: String, old: String?, new: String?)]
        /// Pre-existing warnings unrelated to this edit (surfaced, not fatal).
        let unrelatedWarnings: [String]
    }

    /// Applies `sets` to config.yaml text line-by-line (comments and
    /// ordering preserved), then validates the result with
    /// `MagicEngineConfig.parse` — the engine's own parser. Any warning
    /// naming an edited key (unknown key, wrong type, out-of-range clamp)
    /// rejects the whole edit; the message carries the valid range.
    nonisolated static func applyConfigEdits(
        to text: String,
        sets: [(key: String, value: JSONValue)]
    ) throws -> ConfigEdit {
        var lines = text.isEmpty ? ["---", "---", ""] : text.components(separatedBy: "\n")
        var display: [(key: String, old: String?, new: String?)] = []

        for (key, value) in sets {
            let newScalar = try configValueString(key: key, value: value)
            let existingIndex = lines.firstIndex {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(key):")
            }
            let oldScalar = existingIndex.map {
                lines[$0].trimmingCharacters(in: .whitespaces)
                    .dropFirst("\(key):".count)
                    .trimmingCharacters(in: .whitespaces)
            }

            switch (existingIndex, newScalar) {
            case (let index?, let scalar?):
                lines[index] = "\(key): \(scalar)"
            case (let index?, nil):
                lines.remove(at: index)
            case (nil, let scalar?):
                // Insert before the closing fence when the file has one.
                let closing = lines.lastIndex { $0.trimmingCharacters(in: .whitespaces) == "---" }
                if let closing, closing > 0 {
                    lines.insert("\(key): \(scalar)", at: closing)
                } else {
                    lines.append("\(key): \(scalar)")
                }
            case (nil, nil):
                break  // Removing an absent key is a no-op, not an error.
            }
            display.append((key: key, old: oldScalar, new: newScalar))
        }

        let newText = lines.joined(separator: "\n")
        let (_, warnings) = MagicEngineConfig.parse(newText)
        let editedKeys = sets.map(\.key)
        var fatal: [String] = []
        var unrelated: [String] = []
        for warning in warnings {
            if warning.hasPrefix("line ") {
                fatal.append(warning)  // Whole-file parse failure.
            } else if editedKeys.contains(where: { warning.contains("'\($0)'") }) {
                fatal.append(warning)
            } else {
                unrelated.append(warning)
            }
        }
        guard fatal.isEmpty else {
            throw ToolError(message: "Config validation failed — nothing written:\n" + fatal.joined(separator: "\n"))
        }
        return ConfigEdit(text: newText, display: display, unrelatedWarnings: unrelated)
    }

    private nonisolated static func configValueString(key: String, value: JSONValue) throws -> String? {
        if case .null = value { return nil }
        if key == "no_cloud" {
            let items: [String]
            switch value {
            case .array(let values):
                items = values.compactMap(\.stringValue)
                guard items.count == values.count else {
                    throw ToolError(message: "'no_cloud' entries must be strings.")
                }
            case .string(let single):
                items = [single]
            default:
                throw ToolError(message: "'no_cloud' must be a list of app bundle ids / domains.")
            }
            return "[\(items.joined(separator: ", "))]"
        }
        switch value {
        case .int(let number):
            return "\(number)"
        case .number(let number) where number == number.rounded():
            return "\(Int(number))"
        case .string(let text) where Int(text) != nil:
            return text
        case .bool(let flag):
            return flag ? "1" : "0"  // warm_observer_enabled style toggles.
        default:
            throw ToolError(message: "'\(key)' must be an integer (or null to reset to default).")
        }
    }

    // MARK: - Roles / providers helpers

    private func parsedProviders() -> ProvidersFile.ParseResult {
        guard let text = try? String(contentsOf: providersURL, encoding: .utf8) else {
            return ProvidersFile.ParseResult()
        }
        return ProvidersFile.parse(text)
    }

    private func parsedRoles() -> RolesFile.ParseResult {
        guard let text = try? String(contentsOf: rolesURL, encoding: .utf8) else {
            return RolesFile.ParseResult()
        }
        return RolesFile.parse(text)
    }

    private struct RoleChange {
        let role: EngineRole
        let old: RoleBinding
        let new: RoleBinding
        let allBindings: [EngineRole: RoleBinding]
        let providers: [AIProviderConfig]
        let warning: String?
    }

    private func resolveRoleChange(_ args: [String: JSONValue]) throws -> RoleChange {
        guard let roleText = args["role"]?.stringValue, let role = EngineRole(rawValue: roleText) else {
            let valid = EngineRole.allCases.map(\.rawValue).joined(separator: ", ")
            throw ToolError(message: "Unknown role '\(args["role"]?.stringValue ?? "")'. Valid roles: \(valid).")
        }

        let rolesResult = parsedRoles()
        // Never rewrite a file whose records were partially dropped by the
        // parser — serializing would silently discard them.
        if rolesResult.warnings.contains(where: { $0.contains("skipped") }) {
            throw ToolError(message: "roles.yaml has broken records the parser skipped — a rewrite would drop them. Fix the file first (see engine_status):\n" + rolesResult.warnings.joined(separator: "\n"))
        }
        let providersResult = parsedProviders()
        let old = rolesResult.bindings[role] ?? RoleBinding()
        var new = old
        var warning: String?

        if let providerText = args["provider"]?.stringValue {
            if providerText.lowercased() == "default" {
                new.provider = nil
            } else {
                let provider = try resolveProvider(providerText, in: providersResult.providers)
                new.provider = provider.id
                if role.requiresToolCalling && !provider.providerType.supportsToolCalling {
                    warning = "'\(provider.name)' does not support tool calling; the \(role.rawValue) role will skip it and fall through the chain."
                }
            }
        }
        if let fallbacks = args["fallbacks"]?.arrayValue {
            new.fallbacks = try fallbacks.map {
                guard let text = $0.stringValue else {
                    throw ToolError(message: "'fallbacks' must be provider names or ids.")
                }
                return try resolveProvider(text, in: providersResult.providers).id
            }
        }
        if case .int(let seconds)? = args["timeout_seconds"] {
            if seconds == 0 {
                new.timeoutSeconds = nil
            } else if (1...600).contains(seconds) {
                new.timeoutSeconds = seconds
            } else {
                throw ToolError(message: "timeout_seconds must be 1–600 (or 0 to clear).")
            }
        }
        if let minText = args["min_cost_class"]?.stringValue {
            if minText.lowercased() == "none" {
                new.minCostClass = nil
            } else if let minClass = ProviderCostClass(rawValue: minText) {
                new.minCostClass = minClass
            } else {
                throw ToolError(message: "min_cost_class must be local, mid, premium, or none.")
            }
        }

        return RoleChange(
            role: role, old: old, new: new,
            allBindings: rolesResult.bindings,
            providers: providersResult.providers,
            warning: warning
        )
    }

    private struct ProviderMetadataChange {
        let current: AIProviderConfig
        let allProviders: [AIProviderConfig]
        /// `.some(nil)` = reset to derived; `nil` = leave unchanged.
        let locality: ProviderLocality??
        let costClass: ProviderCostClass??
    }

    private func resolveProviderMetadataChange(_ args: [String: JSONValue]) throws -> ProviderMetadataChange {
        let providersResult = parsedProviders()
        if providersResult.warnings.contains(where: { $0.contains("skipped") }) {
            throw ToolError(message: "providers.yaml has broken records the parser skipped — a rewrite would drop them. Fix the file first (see engine_status):\n" + providersResult.warnings.joined(separator: "\n"))
        }
        let provider = try resolveProvider(try requireString(args, "provider"), in: providersResult.providers)

        var locality: ProviderLocality??
        if let raw = args["locality"]?.stringValue {
            if raw == "derived" {
                locality = .some(nil)
            } else if let parsed = ProviderLocality(rawValue: raw) {
                locality = .some(parsed)
            } else {
                throw ToolError(message: "locality must be local, cloud, or derived.")
            }
        }
        var costClass: ProviderCostClass??
        if let raw = args["cost_class"]?.stringValue {
            if raw == "derived" {
                costClass = .some(nil)
            } else if let parsed = ProviderCostClass(rawValue: raw) {
                costClass = .some(parsed)
            } else {
                throw ToolError(message: "cost_class must be local, mid, premium, or derived.")
            }
        }

        return ProviderMetadataChange(
            current: provider,
            allProviders: providersResult.providers,
            locality: locality,
            costClass: costClass
        )
    }

    private func resolveProvider(_ nameOrID: String, in providers: [AIProviderConfig]) throws -> AIProviderConfig {
        if let id = UUID(uuidString: nameOrID), let match = providers.first(where: { $0.id == id }) {
            return match
        }
        if let match = providers.first(where: { $0.name.lowercased() == nameOrID.lowercased() }) {
            return match
        }
        let available = providers.map(\.name).joined(separator: ", ")
        throw ToolError(message: "No provider named '\(nameOrID)' in providers.yaml. Available: \(available.isEmpty ? "none — configure one in Settings first" : available).")
    }

    // MARK: - Argument helpers

    private func arguments(_ call: ToolCallRequest) -> [String: JSONValue] {
        JSONValue.parse(call.argumentsJSON).objectValue ?? [:]
    }

    private func requireString(_ args: [String: JSONValue], _ key: String) throws -> String {
        guard let value = args[key]?.stringValue, !value.isEmpty else {
            throw ToolError(message: "Missing required argument '\(key)'.")
        }
        return value
    }

    private func requireCoreFileName(_ args: [String: JSONValue]) throws -> String {
        let name = try requireString(args, "name")
        guard EngineTools.coreFileNames.contains(name) else {
            throw ToolError(message: "name must be one of: \(EngineTools.coreFileNames.joined(separator: ", ")).")
        }
        return name
    }

    /// Stable ordering so proposals and writes are deterministic.
    private func requireConfigSets(_ args: [String: JSONValue]) throws -> [(key: String, value: JSONValue)] {
        guard let values = args["values"]?.objectValue, !values.isEmpty else {
            throw ToolError(message: "Missing required argument 'values' (an object of config key → new value).")
        }
        return values.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    private func success(_ dict: [String: JSONValue], warnings: [String] = []) -> String {
        var payload = dict
        if !warnings.isEmpty {
            payload["warnings"] = .array(warnings.map { .string($0) })
        }
        return JSONValue.object(payload).jsonString()
    }
}
