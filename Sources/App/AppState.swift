import SwiftUI

@MainActor
@Observable
final class AppState {
    let promptStore = PromptStore()
    let providerStore = ProviderStore()
    let hotkeyService = HotkeyService()
    let settings = AppSettings.shared
    let syncService = CloudSyncService()

    // Session state
    var currentSession: TransformationSession?
    var isPopupVisible = false
    var isProcessing = false
    var streamingText = ""
    var errorMessage: String?
    var showCopiedFeedback = false

    // Navigation state
    var navigationPath: [PromptNode] = []
    var selectedHistoryStepIndex: Int?

    // Edit mode
    var isEditing = false
    var editingText = ""

    // Settings navigation
    var settingsSelectedTab = 0

    // Window references — not observed by views, excluded from @Observable tracking
    @ObservationIgnored private var popupWindow: PopupWindow?
    @ObservationIgnored private var settingsWindow: NSWindow?
    @ObservationIgnored private var aboutWindow: NSWindow?
    @ObservationIgnored private var onboardingWindow: OnboardingWindow?
    @ObservationIgnored private var currentTask: Task<Void, Never>?

    var currentPrompts: [PromptNode] {
        if let last = navigationPath.last {
            return last.sortedChildren
        }
        return promptStore.prompts.sorted { $0.mnemonicKey < $1.mnemonicKey }
    }

    var breadcrumb: [String] {
        navigationPath.map(\.name)
    }

    var currentDisplayText: String {
        guard let session = currentSession else { return "" }
        if let index = selectedHistoryStepIndex {
            if index < 0 {
                return session.originalText
            }
            if index < session.steps.count {
                return session.steps[index].outputText
            }
        }
        return session.currentText
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
        onboardingWindow?.close()
        onboardingWindow = nil
    }

    // MARK: - Triggers

    func triggerFromSelection() {
        // First try Accessibility API (works in native apps)
        if let text = TextCaptureService.captureSelectedText(), !text.isEmpty {
            startSession(text: text, source: .selectedText)
            return
        }

        // Fallback: simulate Cmd+C to grab selection (works in Chrome, Electron, etc.)
        let oldClipboard = ClipboardService.getText()
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            let newClipboard = ClipboardService.getText()
            if let text = newClipboard, !text.isEmpty, text != oldClipboard {
                self?.startSession(text: text, source: .selectedText)
            } else if let text = newClipboard, !text.isEmpty {
                // Clipboard didn't change — use whatever is there
                self?.startSession(text: text, source: .clipboard)
            } else {
                self?.showError(Loc.shared.t("error.no_text"))
            }
        }
    }

    func triggerBlankEditor() {
        currentSession = TransformationSession(originalText: "", inputSource: .clipboard)
        navigationPath = []
        selectedHistoryStepIndex = nil
        errorMessage = nil
        streamingText = ""
        isProcessing = false
        isEditing = true
        editingText = ""
        showPopup()
    }

    func triggerFromClipboard() {
        guard let text = ClipboardService.getText(), !text.isEmpty else {
            showError(Loc.shared.t("error.clipboard_empty"))
            return
        }
        startSession(text: text, source: .clipboard)
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

    // MARK: - Session Management

    private func startSession(text: String, source: TransformationSession.InputSource) {
        currentSession = TransformationSession(originalText: text, inputSource: source)
        navigationPath = []
        selectedHistoryStepIndex = nil
        isEditing = false
        editingText = ""
        errorMessage = nil
        streamingText = ""
        isProcessing = false
        showPopup()
    }

    // MARK: - Navigation

    func navigateInto(_ node: PromptNode) {
        if node.isFolder {
            navigationPath.append(node)
        } else if node.isPrompt, let prompt = node.systemPrompt {
            applyPrompt(name: node.name, systemPrompt: prompt)
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

    func applyPrompt(name: String, systemPrompt: String) {
        guard let session = currentSession else { return }

        guard let provider = providerStore.defaultProvider else {
            openSettingsToProviders()
            return
        }


        isProcessing = true
        streamingText = ""
        errorMessage = nil

        let service = AIServiceFactory.service(for: provider.providerType)
        let inputText = session.currentText
        let config = provider

        currentTask = Task {
            do {
                if settings.streamingEnabled {
                    var accumulated = ""
                    for try await chunk in service.stream(text: inputText, systemPrompt: systemPrompt, config: config) {
                        accumulated += chunk
                        streamingText = accumulated
                    }
                    guard !accumulated.isEmpty else {
                        throw AIServiceError.emptyResponse
                    }
                    currentSession = session.addingStep(promptName: name, outputText: accumulated)
                } else {
                    let result = try await service.process(text: inputText, systemPrompt: systemPrompt, config: config)
                    currentSession = session.addingStep(promptName: name, outputText: result)
                }
                selectedHistoryStepIndex = nil
                navigationPath = []
                isProcessing = false
                streamingText = ""
            } catch {
                if !(error is CancellationError) {
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
            currentSession = session.addingStep(promptName: Loc.shared.t("misc.manual_edit"), outputText: text)
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
        ClipboardService.setText(currentDisplayText)
        showCopiedFeedback = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            showCopiedFeedback = false
        }
    }

    func pasteCurrentText() {
        ClipboardService.setText(currentDisplayText)
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
        popupWindow?.close()
        isPopupVisible = false
        cancelProcessing()
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
