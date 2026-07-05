import AppKit
import KeyboardShortcuts

/// Describes a pending cross-prompt shortcut collision awaiting user resolution.
struct PendingShortcutConflict: Identifiable, Hashable, Sendable {
    let id: UUID
    let newShortcut: ShortcutConfig
    let newPromptID: UUID
    let newField: ShortcutField
    let conflictingPromptID: UUID
    let conflictingPromptName: String
    let conflictingField: ShortcutField

    init(
        newShortcut: ShortcutConfig,
        newPromptID: UUID,
        newField: ShortcutField,
        conflictingPromptID: UUID,
        conflictingPromptName: String,
        conflictingField: ShortcutField
    ) {
        self.id = UUID()
        self.newShortcut = newShortcut
        self.newPromptID = newPromptID
        self.newField = newField
        self.conflictingPromptID = conflictingPromptID
        self.conflictingPromptName = conflictingPromptName
        self.conflictingField = conflictingField
    }
}

@MainActor
@Observable
final class PromptShortcutService {

    /// Set when `syncToModel` detects a cross-prompt shortcut collision. The
    /// editor view observes this and presents a "Replace / Cancel" dialog.
    var pendingShortcutConflict: PendingShortcutConflict?


    // MARK: - Dependencies (set by AppState after init)

    weak var appState: AppState?

    // MARK: - Registered names tracking

    private var registeredNames: [KeyboardShortcuts.Name] = []

    // MARK: - Inline processing guard

    private(set) var isProcessingInline = false
    private var inlineTask: Task<Void, Never>?

    /// The last inline paste and when it happened. Used as a fallback when the
    /// user triggers a follow-up prompt right after a paste, before making a new
    /// selection (at that point the clipboard still holds the pasted result and
    /// Cmd+C captures nothing new). Consumed on use; ignored once stale.
    private var lastPaste: (text: String, date: Date)?

    /// How long after an inline paste a follow-up trigger may re-process it.
    private static let followUpWindow: TimeInterval = 30

    // MARK: - HUD

    private var hudWindow: ProcessingHUDWindow?

    /// Re-entrancy guard for syncFromModel to prevent onPromptsChanged feedback loops.
    private var isSyncing = false

    // MARK: - Name constructors

    static func quickPasteName(for promptID: UUID) -> KeyboardShortcuts.Name {
        KeyboardShortcuts.Name("prompt_quickPaste_\(promptID.uuidString)")
    }

    static func openRunName(for promptID: UUID) -> KeyboardShortcuts.Name {
        KeyboardShortcuts.Name("prompt_openRun_\(promptID.uuidString)")
    }

    // MARK: - Model ↔ KeyboardShortcuts sync

    /// Push shortcuts from the PromptNode model into KeyboardShortcuts (UserDefaults).
    /// Called on app launch and after import.
    func syncFromModel() {
        guard let appState, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        for prompt in appState.promptStore.allPromptNodes() {
            let qpName = Self.quickPasteName(for: prompt.id)
            let orName = Self.openRunName(for: prompt.id)

            if let config = prompt.quickPasteShortcut {
                KeyboardShortcuts.setShortcut(
                    .init(carbonKeyCode: config.carbonKeyCode, carbonModifiers: config.carbonModifiers),
                    for: qpName
                )
            }
            if let config = prompt.openRunShortcut {
                KeyboardShortcuts.setShortcut(
                    .init(carbonKeyCode: config.carbonKeyCode, carbonModifiers: config.carbonModifiers),
                    for: orName
                )
            }
        }
        // Also migrate any existing UserDefaults shortcuts into the model
        migrateFromUserDefaults()
    }

    /// Pull current shortcut from KeyboardShortcuts back into the PromptNode model and save.
    /// Called when the user changes a shortcut via the Recorder widget.
    ///
    /// If the newly recorded shortcut is already used by another prompt, the
    /// new assignment is **not** committed. Instead `pendingShortcutConflict`
    /// is set so the editor can show a Replace / Cancel dialog, and the
    /// Recorder is rolled back to the prompt's previous value.
    func syncToModel(promptID: UUID) {
        guard let appState, !isSyncing,
              let existingNode = appState.promptStore.findNode(byID: promptID)
        else { return }

        isSyncing = true
        defer { isSyncing = false }

        let qpName = Self.quickPasteName(for: promptID)
        let orName = Self.openRunName(for: promptID)

        let newQP = KeyboardShortcuts.getShortcut(for: qpName).map {
            ShortcutConfig(carbonKeyCode: $0.carbonKeyCode, carbonModifiers: $0.carbonModifiers)
        }
        let newOR = KeyboardShortcuts.getShortcut(for: orName).map {
            ShortcutConfig(carbonKeyCode: $0.carbonKeyCode, carbonModifiers: $0.carbonModifiers)
        }

        if newQP != existingNode.quickPasteShortcut,
           let candidate = newQP,
           let conflict = appState.promptStore
               .prompts(matchingShortcut: candidate, excluding: promptID)
               .first {
            applyShortcut(existingNode.quickPasteShortcut, to: qpName)
            pendingShortcutConflict = PendingShortcutConflict(
                newShortcut: candidate,
                newPromptID: promptID,
                newField: .quickPaste,
                conflictingPromptID: conflict.prompt.id,
                conflictingPromptName: conflict.prompt.name,
                conflictingField: conflict.field
            )
            return
        }

        if newOR != existingNode.openRunShortcut,
           let candidate = newOR,
           let conflict = appState.promptStore
               .prompts(matchingShortcut: candidate, excluding: promptID)
               .first {
            applyShortcut(existingNode.openRunShortcut, to: orName)
            pendingShortcutConflict = PendingShortcutConflict(
                newShortcut: candidate,
                newPromptID: promptID,
                newField: .openRun,
                conflictingPromptID: conflict.prompt.id,
                conflictingPromptName: conflict.prompt.name,
                conflictingField: conflict.field
            )
            return
        }

        var node = existingNode
        node.quickPasteShortcut = newQP
        node.openRunShortcut = newOR
        appState.promptStore.updateNode(node)
    }

    /// Resolve a pending shortcut conflict. When `replace` is true the
    /// conflicting prompt's matching shortcut is cleared and the new shortcut
    /// is committed to the editing prompt. When false the new assignment is
    /// discarded — it was already rolled back when the conflict was detected.
    func resolveShortcutConflict(replace: Bool) {
        guard let conflict = pendingShortcutConflict, let appState else {
            pendingShortcutConflict = nil
            return
        }
        pendingShortcutConflict = nil

        guard replace else { return }

        isSyncing = true
        defer { isSyncing = false }

        if var other = appState.promptStore.findNode(byID: conflict.conflictingPromptID) {
            let otherName: KeyboardShortcuts.Name
            switch conflict.conflictingField {
            case .quickPaste:
                other.quickPasteShortcut = nil
                otherName = Self.quickPasteName(for: other.id)
            case .openRun:
                other.openRunShortcut = nil
                otherName = Self.openRunName(for: other.id)
            }
            KeyboardShortcuts.reset(otherName)
            appState.promptStore.updateNode(other)
        }

        if var node = appState.promptStore.findNode(byID: conflict.newPromptID) {
            let newName: KeyboardShortcuts.Name
            switch conflict.newField {
            case .quickPaste:
                node.quickPasteShortcut = conflict.newShortcut
                newName = Self.quickPasteName(for: node.id)
            case .openRun:
                node.openRunShortcut = conflict.newShortcut
                newName = Self.openRunName(for: node.id)
            }
            applyShortcut(conflict.newShortcut, to: newName)
            appState.promptStore.updateNode(node)
        }
    }

    private func applyShortcut(_ config: ShortcutConfig?, to name: KeyboardShortcuts.Name) {
        if let config {
            KeyboardShortcuts.setShortcut(
                .init(carbonKeyCode: config.carbonKeyCode, carbonModifiers: config.carbonModifiers),
                for: name
            )
        } else {
            KeyboardShortcuts.reset(name)
        }
    }

    /// Migrate shortcuts that exist in UserDefaults but not yet in the model (upgrade path).
    private func migrateFromUserDefaults() {
        guard let appState else { return }
        var didMigrate = false

        for prompt in appState.promptStore.allPromptNodes() {
            var node = prompt
            var changed = false

            if node.quickPasteShortcut == nil,
               let shortcut = KeyboardShortcuts.getShortcut(for: Self.quickPasteName(for: node.id)) {
                node.quickPasteShortcut = ShortcutConfig(carbonKeyCode: shortcut.carbonKeyCode, carbonModifiers: shortcut.carbonModifiers)
                changed = true
            }
            if node.openRunShortcut == nil,
               let shortcut = KeyboardShortcuts.getShortcut(for: Self.openRunName(for: node.id)) {
                node.openRunShortcut = ShortcutConfig(carbonKeyCode: shortcut.carbonKeyCode, carbonModifiers: shortcut.carbonModifiers)
                changed = true
            }
            // Migrate selectAll from UserDefaults to model
            let udKey = "prompt_selectAll_\(node.id.uuidString)"
            if node.selectAllBeforeCapture == nil && UserDefaults.standard.bool(forKey: udKey) {
                node.selectAllBeforeCapture = true
                UserDefaults.standard.removeObject(forKey: udKey)
                changed = true
            }

            if changed {
                appState.promptStore.updateNode(node)
                didMigrate = true
            }
        }

        if didMigrate {
            appState.promptStore.save()
        }
    }

    // MARK: - Registration

    func registerAll() {
        guard let appState else { return }
        unregisterAll()
        let prompts = appState.promptStore.allPromptNodes()
        registerHandlers(for: prompts)
    }

    func refreshShortcuts() {
        guard let appState else { return }
        unregisterAll()
        let prompts = appState.promptStore.allPromptNodes()
        registerHandlers(for: prompts)
        cleanupOrphaned()
        appState.promptShortcutsVersion += 1
    }

    func unregisterAll() {
        for name in registeredNames {
            KeyboardShortcuts.removeHandler(for: name)
        }
        registeredNames.removeAll()
    }

    // MARK: - Private registration

    private func registerHandlers(for prompts: [PromptNode]) {
        for prompt in prompts {
            let qpName = Self.quickPasteName(for: prompt.id)
            let orName = Self.openRunName(for: prompt.id)

            let promptID = prompt.id

            KeyboardShortcuts.onKeyUp(for: qpName) { [weak self] in
                self?.handleQuickPaste(promptID: promptID)
            }
            registeredNames.append(qpName)

            KeyboardShortcuts.onKeyUp(for: orName) { [weak self] in
                self?.handleOpenRun(promptID: promptID)
            }
            registeredNames.append(orName)
        }
    }

    // MARK: - Cleanup orphaned shortcuts from UserDefaults

    private func cleanupOrphaned() {
        guard let appState else { return }
        let validIDs = appState.promptStore.allPromptIDs()
        let defaults = UserDefaults.standard
        let allKeys = defaults.dictionaryRepresentation().keys

        for key in allKeys {
            guard key.hasPrefix("KeyboardShortcuts_prompt_") || key.hasPrefix("prompt_selectAll_") else { continue }
            let components = key.split(separator: "_")
            guard components.count >= 3,
                  let uuid = UUID(uuidString: String(components.last ?? ""))
            else { continue }
            if !validIDs.contains(uuid) {
                defaults.removeObject(forKey: key)
            }
        }
    }

    // MARK: - Quick Paste handler

    func handleQuickPaste(promptID: UUID) {
        guard let appState,
              let prompt = appState.promptStore.findNode(byID: promptID),
              prompt.isPrompt
        else { return }
        runInline(prompt: prompt)
    }

    /// - Parameter selectAllOverride: When `nil` (default) honors `prompt.selectAllBeforeCapture`.
    ///   Pass `false` from invocation paths that should never simulate Cmd+A first (e.g. Quick Access tiles).
    func runInline(prompt: PromptNode, selectAllOverride: Bool? = nil) {
        guard let appState, !isProcessingInline else { return }
        guard prompt.isPrompt, let systemPrompt = prompt.systemPrompt else { return }

        let provider: AIProviderConfig
        if let id = prompt.providerID,
           let specific = appState.providerStore.providers.first(where: { $0.id == id }) {
            provider = specific
        } else if let defaultProvider = appState.providerStore.defaultProvider {
            provider = defaultProvider
        } else {
            return
        }

        isProcessingInline = true
        let shouldSelectAll = selectAllOverride ?? (prompt.selectAllBeforeCapture == true)

        // Save original clipboard
        let originalClipboard = ClipboardService.getText()

        // Optionally simulate Cmd+A first to select all text
        if shouldSelectAll {
            let source = CGEventSource(stateID: .combinedSessionState)
            let aDown = CGEvent(keyboardEventSource: source, virtualKey: 0x00, keyDown: true)
            let aUp = CGEvent(keyboardEventSource: source, virtualKey: 0x00, keyDown: false)
            aDown?.flags = .maskCommand
            aUp?.flags = .maskCommand
            aDown?.post(tap: .cghidEventTap)
            aUp?.post(tap: .cghidEventTap)
        }

        inlineTask = Task { [weak self] in
            guard let self else { return }

            if shouldSelectAll {
                try? await Task.sleep(for: .milliseconds(100))
            }

            // Simulate Cmd+C to capture selection
            let source = CGEventSource(stateID: .combinedSessionState)
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
            keyDown?.flags = .maskCommand
            keyUp?.flags = .maskCommand
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)

            // Wait for clipboard update
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else {
                self.finishInlineProcessing()
                return
            }

            let capturedText = ClipboardService.getText()

            // Restore original clipboard
            if let original = originalClipboard {
                ClipboardService.setText(original)
            }

            guard let text = capturedText, !text.isEmpty, text != originalClipboard else {
                if let accessibilityText = TextCaptureService.captureSelectedText(), !accessibilityText.isEmpty {
                    // Accessibility API found a selection — use it.
                    await self.processAndPaste(
                        text: accessibilityText,
                        systemPrompt: systemPrompt,
                        promptName: prompt.name,
                        provider: provider,
                        displayMode: prompt.displayMode
                    )
                } else if let lastPaste = self.lastPaste,
                          originalClipboard == lastPaste.text,
                          Date().timeIntervalSince(lastPaste.date) < Self.followUpWindow {
                    // No new selection was made and the clipboard still holds the result
                    // we pasted moments ago — treat this as a follow-up prompt on that
                    // text. Consume the stored paste so it can't fire again when stale.
                    self.lastPaste = nil
                    await self.processAndPaste(
                        text: lastPaste.text,
                        systemPrompt: systemPrompt,
                        promptName: prompt.name,
                        provider: provider,
                        displayMode: prompt.displayMode
                    )
                }
                self.finishInlineProcessing()
                return
            }

            await self.processAndPaste(
                text: text,
                systemPrompt: systemPrompt,
                promptName: prompt.name,
                provider: provider,
                displayMode: prompt.displayMode
            )
            self.finishInlineProcessing()
        }
    }

    private func processAndPaste(
        text: String,
        systemPrompt: String,
        promptName: String,
        provider: AIProviderConfig,
        displayMode: EditorMode?
    ) async {
        showHUD(promptName: promptName)

        let service = AIServiceFactory.service(for: provider.providerType)

        do {
            let result = try await service.process(
                text: text,
                systemPrompt: systemPrompt,
                config: provider
            )

            guard !Task.isCancelled, !result.isEmpty else {
                dismissHUD()
                return
            }

            let mode = displayMode ?? appState?.settings.editorMode ?? .plainText
            lastPaste = (text: result, date: Date())
            switch mode {
            case .markdown:
                ClipboardService.setRichText(result)
            case .html:
                ClipboardService.setHTMLContent(result)
            case .plainText:
                ClipboardService.setText(result)
            }

            dismissHUD()

            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            ClipboardService.simulatePaste()
        } catch {
            dismissHUD()
        }
    }

    private func finishInlineProcessing() {
        isProcessingInline = false
        inlineTask = nil
    }

    // MARK: - Open & Run handler

    func handleOpenRun(promptID: UUID) {
        guard let appState,
              let prompt = appState.promptStore.findNode(byID: promptID),
              prompt.isPrompt
        else { return }
        runOpenInPopup(prompt: prompt)
    }

    func runOpenInPopup(prompt: PromptNode) {
        guard let appState, prompt.isPrompt else { return }

        if appState.isPopupVisible {
            appState.navigateInto(prompt)
        } else {
            appState.pendingPromptNode = prompt
            appState.triggerFromSelection()
            // Ensure the popup gets focus once it appears (triggerFromSelection has a 0.2s delay)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NSApplication.shared.activate()
            }
        }
    }

    // MARK: - HUD

    private func showHUD(promptName: String) {
        dismissHUD()
        let hud = ProcessingHUDWindow(promptName: promptName) { [weak self] in
            self?.cancelInlineProcessing()
        }
        hud.showAtCenter()
        hudWindow = hud
    }

    private func dismissHUD() {
        hudWindow?.close()
        hudWindow = nil
    }

    func cancelInlineProcessing() {
        inlineTask?.cancel()
        inlineTask = nil
        isProcessingInline = false
        dismissHUD()
    }

    // MARK: - Query helpers

    func promptsWithShortcuts() -> [(prompt: PromptNode, quickPaste: KeyboardShortcuts.Shortcut?, openRun: KeyboardShortcuts.Shortcut?)] {
        guard let appState else { return [] }
        var result: [(prompt: PromptNode, quickPaste: KeyboardShortcuts.Shortcut?, openRun: KeyboardShortcuts.Shortcut?)] = []

        for prompt in appState.promptStore.allPromptNodes() {
            let qp = KeyboardShortcuts.getShortcut(for: Self.quickPasteName(for: prompt.id))
            let or = KeyboardShortcuts.getShortcut(for: Self.openRunName(for: prompt.id))
            if qp != nil || or != nil {
                result.append((prompt: prompt, quickPaste: qp, openRun: or))
            }
        }
        return result
    }
}
