import AppKit
import KeyboardShortcuts

@MainActor
final class PromptShortcutService {

    // MARK: - Dependencies (set by AppState after init)

    weak var appState: AppState?

    // MARK: - Registered names tracking

    private var registeredNames: [KeyboardShortcuts.Name] = []

    // MARK: - Inline processing guard

    private(set) var isProcessingInline = false
    private var inlineTask: Task<Void, Never>?

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
    func syncToModel(promptID: UUID) {
        guard let appState, !isSyncing,
              var node = appState.promptStore.findNode(byID: promptID)
        else { return }

        isSyncing = true
        defer { isSyncing = false }

        let qp = KeyboardShortcuts.getShortcut(for: Self.quickPasteName(for: promptID))
        let or = KeyboardShortcuts.getShortcut(for: Self.openRunName(for: promptID))

        node.quickPasteShortcut = qp.map { ShortcutConfig(carbonKeyCode: $0.carbonKeyCode, carbonModifiers: $0.carbonModifiers) }
        node.openRunShortcut = or.map { ShortcutConfig(carbonKeyCode: $0.carbonKeyCode, carbonModifiers: $0.carbonModifiers) }

        appState.promptStore.updateNode(node)
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
            KeyboardShortcuts.disable(name)
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
        guard let appState, !isProcessingInline else { return }
        guard let prompt = appState.promptStore.findNode(byID: promptID),
              prompt.isPrompt,
              let systemPrompt = prompt.systemPrompt
        else { return }

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
        let shouldSelectAll = prompt.selectAllBeforeCapture == true

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
                    await self.processAndPaste(
                        text: accessibilityText,
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
        guard let appState else { return }
        guard let prompt = appState.promptStore.findNode(byID: promptID),
              prompt.isPrompt
        else { return }

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
