import SwiftUI

@MainActor
@Observable
final class AppState {
    let promptStore = PromptStore()
    let providerStore = ProviderStore()
    let chatGPTTokenManager = ChatGPTTokenManager.shared
    let hotkeyService = HotkeyService()
    let settings = AppSettings.shared
    let syncService = CloudSyncService()
    let findBarState = FindBarState()

    // Session state
    var currentSession: TransformationSession?
    var isPopupVisible = false
    var isProcessing = false
    var streamingText = ""
    var errorMessage: String?
    var showCopiedFeedback = false
    var showSelectionCopiedFeedback = false

    // Navigation state
    var navigationPath: [PromptNode] = []
    var selectedHistoryStepIndex: Int?

    // Edit mode
    var isEditing = false
    var editingText = ""

    // Original item view mode (which representation to show for the original text)
    var originalViewMode: RichTextMode = .plainText
    // Runtime display format (independent from settings default)
    var activeEditorMode: EditorMode = .markdown
    // Display mode for the original item — initialized from settings, updated by user
    var originalDisplayMode: EditorMode = .markdown
    // Lazy caches for original text conversions
    @ObservationIgnored private var cachedOriginalMarkdown: String?
    @ObservationIgnored private var cachedOriginalMarkdownAI: String?

    // Settings navigation
    var settingsSelectedTab = 0

    // Window references — not observed by views, excluded from @Observable tracking
    @ObservationIgnored private var popupWindow: PopupWindow?
    @ObservationIgnored private var settingsWindow: NSWindow?
    @ObservationIgnored private var aboutWindow: NSWindow?
    @ObservationIgnored private var onboardingWindow: OnboardingWindow?
    @ObservationIgnored private var permissionAlertWindow: PermissionAlertWindow?
    @ObservationIgnored private var currentTask: Task<Void, Never>?

    var currentPrompts: [PromptNode] {
        if let last = navigationPath.last {
            return last.children ?? []
        }
        return promptStore.prompts
    }

    var breadcrumb: [String] {
        navigationPath.map(\.name)
    }

    var currentDisplayText: String {
        guard let session = currentSession else { return "" }
        if let index = selectedHistoryStepIndex {
            if index < 0 {
                return originalTextForCurrentMode
            }
            if index < session.steps.count {
                return session.steps[index].outputText
            }
        }
        // No steps yet — show original in selected view mode
        if !session.hasSteps {
            return originalTextForCurrentMode
        }
        return session.currentText
    }

    /// Returns the original text in the representation selected by `originalViewMode`.
    var originalTextForCurrentMode: String {
        guard let session = currentSession else { return "" }
        switch originalViewMode {
        case .plainText:
            return session.originalText
        case .html:
            return session.originalHTML ?? session.originalText
        case .markdown:
            if let cached = cachedOriginalMarkdown { return cached }
            if let html = session.originalHTML,
               let md = MarkdownConverter.markdown(fromHTML: html), !md.isEmpty {
                cachedOriginalMarkdown = md
                return md
            }
            return session.originalText
        case .markdownAI:
            // AI conversion is triggered lazily — show cached or original until ready
            return cachedOriginalMarkdownAI ?? session.originalText
        }
    }

    /// Trigger lazy AI conversion for the original item.
    func convertOriginalWithAI() {
        guard cachedOriginalMarkdownAI == nil,
              let session = currentSession,
              let html = session.originalHTML
        else { return }

        let prompt = settings.customConversionPrompt.isEmpty
            ? AppSettings.defaultConversionPrompt
            : settings.customConversionPrompt

        guard let provider = providerStore.defaultProvider else {
            openSettingsToProviders()
            return
        }

        isProcessing = true
        streamingText = ""
        let service = AIServiceFactory.service(for: provider.providerType)
        let config = provider

        currentTask = Task {
            do {
                let result = try await service.process(text: html, systemPrompt: prompt, config: config)
                cachedOriginalMarkdownAI = result
                isProcessing = false
                streamingText = ""
            } catch {
                let wasCancelled = error is CancellationError || Task.isCancelled
                if !wasCancelled {
                    errorMessage = error.localizedDescription
                }
                isProcessing = false
                streamingText = ""
            }
        }
    }

    // MARK: - Lifecycle

    func setup() {
        hotkeyService.onTrigger = { [weak self] in
            self?.triggerFromSelection()
        }
        hotkeyService.onTriggerFromClipboard = { [weak self] in
            self?.triggerFromClipboard()
        }
        hotkeyService.onTriggerBlankEditor = { [weak self] in
            self?.triggerBlankEditor()
        }
        hotkeyService.onTriggerScreenCapture = { [weak self] in
            self?.triggerFromScreenCapture()
        }
        hotkeyService.onTriggerOCRToClipboard = { [weak self] in
            self?.triggerOCRToClipboard()
        }
        hotkeyService.register()

        // Wire iCloud sync — deferred by 2s so menu bar renders first
        promptStore.onPromptsChanged = { [weak self] data in
            self?.syncService.handleLocalChange(data: data)
        }
        if settings.iCloudSyncEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self else { return }
                self.syncService.start(promptStore: self.promptStore)
            }
        }

        if !settings.hasCompletedOnboarding {
            showOnboarding()
        } else {
            checkPermissionsAfterUpdate()
        }

        // Listen for reopen requests (dock click when menu bar is hidden)
        NotificationCenter.default.addObserver(
            forName: .clipSlopOpenSettings,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.openSettings()
        }
    }

    // MARK: - Onboarding

    func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 780, height: 800),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = Loc.shared.t("window.settings")
            window.contentView = NSHostingView(rootView: SettingsView(appState: self))
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 700, height: 400)
            window.center()
            settingsWindow = window
        }

        // Defer window presentation to next run loop to avoid "Publishing changes
        // from within view updates" — setActivationPolicy and activate() trigger
        // notifications that can fire during the current SwiftUI update cycle.
        let window = settingsWindow
        let hideDock = settings.hideDockIcon
        DispatchQueue.main.async {
            window?.level = .floating
            if !hideDock {
                NSApplication.shared.setActivationPolicy(.regular)
            }
            window?.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    func openSettingsToProviders() {
        settingsSelectedTab = 1
        openSettings()
    }

    func showAbout() {
        if aboutWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 440),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = Loc.shared.t("window.about")
            window.titlebarAppearsTransparent = true
            window.contentView = NSHostingView(rootView: AboutView())
            window.isReleasedWhenClosed = false
            window.isMovableByWindowBackground = true
            window.center()
            aboutWindow = window
        }

        let window = aboutWindow
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        }
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            onboardingWindow = OnboardingWindow(appState: self)
        }
        onboardingWindow?.center()
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func completeOnboarding() {
        settings.hasCompletedOnboarding = true
        UserDefaults.standard.removeObject(forKey: "onboardingStep")
        onboardingWindow?.close()
        onboardingWindow = nil
    }

    // MARK: - Permission Alert

    private func checkPermissionsAfterUpdate() {
        guard !settings.suppressPermissionAlert else { return }

        let accessibilityOK = PermissionService.isAccessibilityGranted
        let screenRecordingOK = PermissionService.isScreenRecordingGranted

        if !accessibilityOK || !screenRecordingOK {
            showPermissionAlert()
        }
    }

    func showPermissionAlert() {
        if permissionAlertWindow == nil {
            permissionAlertWindow = PermissionAlertWindow(appState: self)
        }
        permissionAlertWindow?.center()

        let window = permissionAlertWindow
        DispatchQueue.main.async {
            window?.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    func movePermissionAlertAside() {
        permissionAlertWindow?.moveAside()
    }

    func dismissPermissionAlert() {
        permissionAlertWindow?.close()
        permissionAlertWindow = nil
    }

    // MARK: - Triggers

    func triggerFromSelection() {
        // Simulate Cmd+C first — preserves rich text (HTML/RTF) in clipboard
        let oldClipboard = ClipboardService.getText()
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            let plainText = ClipboardService.getText()
            let html = ClipboardService.getHTML()

            if let text = plainText, !text.isEmpty, text != oldClipboard {
                self.startSession(text: text, html: html, source: .selectedText)
                return
            }

            // Fallback: Accessibility API (for apps where Cmd+C didn't work)
            if let text = TextCaptureService.captureSelectedText(), !text.isEmpty {
                self.startSession(text: text, source: .selectedText)
                return
            }

            // Last resort: use whatever is in the clipboard
            if let text = plainText, !text.isEmpty {
                self.startSession(text: text, html: html, source: .clipboard)
            } else {
                self.showError(Loc.shared.t("error.no_text"))
            }
        }
    }

    func triggerBlankEditor() {
        // Reset all state before showing popup to prevent stale session flash
        resetSessionState()
        currentSession = TransformationSession(originalText: "", inputSource: .clipboard)
        cachedOriginalMarkdown = nil
        cachedOriginalMarkdownAI = nil
        activeEditorMode = settings.editorMode
        isEditing = true
        editingText = ""
        showPopup()
    }

    func triggerFromClipboard() {
        let plainText = ClipboardService.getText()
        let html = ClipboardService.getHTML()
        guard let text = plainText, !text.isEmpty else {
            showError(Loc.shared.t("error.clipboard_empty"))
            return
        }
        startSession(text: text, html: html, source: .clipboard)
    }

    func triggerFromScreenCapture() {
        Task {
            do {
                let text = try await ScreenCaptureService.captureAndRecognize()
                startSession(text: text, source: .screenCapture)
            } catch let captureError as ScreenCaptureService.CaptureError {
                if case .userCancelled = captureError { return }
                showError(captureError.localizedDescription)
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    func triggerOCRToClipboard() {
        Task {
            do {
                let text = try await ScreenCaptureService.captureAndRecognize()
                ClipboardService.setText(text)
                // Brief visual feedback if popup is visible
                showCopiedFeedback = true
                try? await Task.sleep(for: .seconds(1.5))
                showCopiedFeedback = false
            } catch let captureError as ScreenCaptureService.CaptureError {
                if case .userCancelled = captureError { return }
                // No popup to show error — silently fail
            } catch {
                // Silently fail — no popup open
            }
        }
    }

    // MARK: - Session Management

    private func startSession(text: String, html: String? = nil, source: TransformationSession.InputSource) {
        currentSession = TransformationSession(
            originalText: text,
            originalHTML: html,
            inputSource: source
        )
        navigationPath = []
        selectedHistoryStepIndex = nil
        isEditing = false
        editingText = ""
        errorMessage = nil
        streamingText = ""
        isProcessing = false

        // Reset lazy caches
        cachedOriginalMarkdown = nil
        cachedOriginalMarkdownAI = nil

        // Pre-select modes from settings (runtime copies, independent from settings)
        originalViewMode = settings.richTextMode
        activeEditorMode = settings.editorMode
        originalDisplayMode = settings.editorMode

        showPopup()

        // If markdownAI is pre-selected and we have HTML, trigger lazy conversion
        if originalViewMode == .markdownAI, html != nil, source != .screenCapture {
            let shouldConvert = !settings.markdownAIOnlyRichText || html != nil
            if shouldConvert {
                convertOriginalWithAI()
            }
        }
    }

    // MARK: - Navigation

    func navigateInto(_ node: PromptNode) {
        if node.isFolder {
            navigationPath.append(node)
        } else if node.isPrompt, let prompt = node.systemPrompt {
            applyPrompt(name: node.name, systemPrompt: prompt, providerID: node.providerID)
            // Switch display mode if prompt specifies one
            if let mode = node.displayMode {
                activeEditorMode = mode
            }
        }
    }

    func navigateBack() {
        if !navigationPath.isEmpty {
            navigationPath.removeLast()
        }
    }

    func navigateToRoot() {
        navigationPath = []
    }

    @discardableResult
    func handleMnemonicKey(_ key: String, modifiers: MnemonicModifiers = []) -> Bool {
        if let node = currentPrompts.first(where: {
            $0.mnemonicKey.lowercased() == key.lowercased()
                && ($0.mnemonicModifiers ?? []) == modifiers
        }) {
            navigateInto(node)
            return true
        }
        return false
    }

    // MARK: - Processing

    func applyPrompt(name: String, systemPrompt: String, providerID: UUID? = nil) {
        guard var session = currentSession else { return }

        // Use prompt-specific provider if set, otherwise fall back to default
        let provider: AIProviderConfig
        if let id = providerID,
           let specific = providerStore.providers.first(where: { $0.id == id }) {
            provider = specific
        } else if let defaultProvider = providerStore.defaultProvider {
            provider = defaultProvider
        } else {
            openSettingsToProviders()
            return
        }

        // If viewing a history step, truncate to that step first
        if let index = selectedHistoryStepIndex, index >= 0 {
            session = session.steppingTo(index: index)
            currentSession = session
        }

        let inputText = currentDisplayText

        isProcessing = true
        streamingText = ""
        errorMessage = nil

        let service = AIServiceFactory.service(for: provider.providerType)
        let config = provider

        currentTask = Task {
            do {
                if settings.streamingEnabled {
                    var accumulated = ""
                    var lastUIUpdate = ContinuousClock.now
                    let throttleInterval = Duration.milliseconds(50)
                    for try await chunk in service.stream(text: inputText, systemPrompt: systemPrompt, config: config) {
                        accumulated += chunk
                        let now = ContinuousClock.now
                        if now - lastUIUpdate >= throttleInterval {
                            streamingText = accumulated
                            lastUIUpdate = now
                        }
                    }
                    // Final flush to ensure all text is shown
                    streamingText = accumulated
                    guard !accumulated.isEmpty else {
                        throw AIServiceError.emptyResponse
                    }
                    currentSession = session.addingStep(promptName: name, outputText: accumulated, displayMode: activeEditorMode)
                } else {
                    let result = try await service.process(text: inputText, systemPrompt: systemPrompt, config: config)
                    currentSession = session.addingStep(promptName: name, outputText: result, displayMode: activeEditorMode)
                }
                selectedHistoryStepIndex = nil
                navigationPath = []
                isProcessing = false
                streamingText = ""
            } catch {
                let wasCancelled = error is CancellationError || Task.isCancelled
                if !wasCancelled {
                    errorMessage = error.localizedDescription
                }
                isProcessing = false
                streamingText = ""
            }
        }
    }

    func cancelProcessing() {
        currentTask?.cancel()
        currentTask = nil
        isProcessing = false
        streamingText = ""
        errorMessage = nil
    }

    // MARK: - Actions

    func undoLastStep() {
        guard let session = currentSession else { return }
        currentSession = session.undoingLastStep()
        selectedHistoryStepIndex = nil
    }

    func removeHistoryStep(at index: Int) {
        guard let session = currentSession else { return }
        currentSession = session.removingStep(at: index)
        // Reset selection if we deleted the selected step
        if selectedHistoryStepIndex == index {
            selectedHistoryStepIndex = nil
        } else if let selected = selectedHistoryStepIndex, selected > index {
            selectedHistoryStepIndex = selected - 1
        }
    }

    func selectHistoryStep(at index: Int) {
        selectedHistoryStepIndex = index
        // Restore the display mode for this step
        guard let session = currentSession else { return }
        if index < 0 {
            activeEditorMode = originalDisplayMode
        } else if index < session.steps.count {
            activeEditorMode = session.steps[index].displayMode
        }
    }

    /// Move to a newer step (towards latest result). In sidebar: up direction.
    func navigateHistoryNewer() {
        guard let session = currentSession, session.hasSteps else { return }
        let maxIndex = session.steps.count - 1
        let current = selectedHistoryStepIndex ?? maxIndex

        if current < maxIndex {
            selectedHistoryStepIndex = current + 1
        }
    }

    /// Move to an older step (towards original). In sidebar: down direction.
    func navigateHistoryOlder() {
        guard let session = currentSession, session.hasSteps else { return }
        let maxIndex = session.steps.count - 1
        let current = selectedHistoryStepIndex ?? maxIndex

        if current > -1 {
            selectedHistoryStepIndex = current - 1
        }
    }

    // MARK: - Edit Mode

    func startEditing() {
        editingText = currentDisplayText
        isEditing = true
    }

    func saveEdit() {
        guard isEditing, let session = currentSession else { return }
        let text = editingText
        guard !text.isEmpty else {
            isEditing = false
            return
        }

        // If original text is empty (blank editor), set it as the original
        if session.originalText.isEmpty {
            currentSession = TransformationSession(originalText: text, inputSource: session.inputSource)
        } else if text != currentDisplayText {
            currentSession = session.addingStep(promptName: Loc.shared.t("misc.manual_edit"), outputText: text, displayMode: activeEditorMode)
        }
        selectedHistoryStepIndex = nil
        isEditing = false
    }

    func cancelEdit() {
        isEditing = false
        editingText = ""
    }

    func openInTextEdit() {
        let text = currentDisplayText
        guard !text.isEmpty else { return }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipSlop-\(UUID().uuidString.prefix(8))")
            .appendingPathExtension("txt")
        try? text.write(to: tempURL, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(tempURL)
    }

    func saveToFile() {
        let text = currentDisplayText
        guard !text.isEmpty else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ClipSlop output.txt"
        panel.allowedContentTypes = [.plainText]

        // Show as sheet on the popup window so it's not hidden behind it
        if let window = popupWindow {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    func selectAllText() {
        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
    }

    func copyCurrentText() {
        switch activeEditorMode {
        case .markdown:
            ClipboardService.setRichText(currentDisplayText)
        case .html:
            ClipboardService.setHTMLContent(currentDisplayText)
        case .plainText:
            ClipboardService.setText(currentDisplayText)
        }
        showCopiedFeedback = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            showCopiedFeedback = false
        }
    }

    func pasteCurrentText() {
        switch activeEditorMode {
        case .markdown:
            ClipboardService.setRichText(currentDisplayText)
        case .html:
            ClipboardService.setHTMLContent(currentDisplayText)
        case .plainText:
            ClipboardService.setText(currentDisplayText)
        }
        dismissPopup()
        ClipboardService.simulatePaste()
    }

    func transformAgain() {
        // If viewing a history step, truncate to that step first
        if let index = selectedHistoryStepIndex, let session = currentSession, index >= 0 {
            currentSession = session.steppingTo(index: index)
        }
        selectedHistoryStepIndex = nil
        navigationPath = []
    }

    // MARK: - Popup

    func showPopup() {
        if popupWindow == nil {
            popupWindow = PopupWindow(appState: self)
        }
        popupWindow?.showAtCenter()
        isPopupVisible = true
    }

    func dismissPopup() {
        findBarState.dismiss()
        popupWindow?.close()
        isPopupVisible = false
        cancelProcessing()
        resetSessionState()
    }

    private func resetSessionState() {
        navigationPath = []
        selectedHistoryStepIndex = nil
        errorMessage = nil
        streamingText = ""
        isProcessing = false
        isEditing = false
        editingText = ""
    }

    // MARK: - Error

    func showError(_ message: String) {
        errorMessage = message
        showPopup()
    }

    func clearError() {
        errorMessage = nil
    }
}
