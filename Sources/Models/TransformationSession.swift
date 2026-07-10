import Foundation

struct TransformationStep: Identifiable, Sendable {
    let id: UUID
    let promptName: String
    let inputText: String
    let outputText: String
    let timestamp: Date
    let displayMode: EditorMode
    /// True while this step's AI response hasn't finished yet. Lets the
    /// sidebar show a placeholder "tab" for it the instant a prompt starts
    /// running, instead of only inserting the step once the full response
    /// has come back.
    let isPending: Bool

    init(
        id: UUID = UUID(),
        promptName: String,
        inputText: String,
        outputText: String,
        timestamp: Date = Date(),
        displayMode: EditorMode = .markdown,
        isPending: Bool = false
    ) {
        self.id = id
        self.promptName = promptName
        self.inputText = inputText
        self.outputText = outputText
        self.timestamp = timestamp
        self.displayMode = displayMode
        self.isPending = isPending
    }
}

struct TransformationSession: Identifiable, Sendable {
    let id: UUID
    let originalText: String
    let originalHTML: String?
    let inputSource: InputSource
    private(set) var steps: [TransformationStep]

    enum InputSource: Sendable {
        case clipboard
        case selectedText
        case screenCapture
    }

    init(
        id: UUID = UUID(),
        originalText: String,
        originalHTML: String? = nil,
        inputSource: InputSource = .clipboard,
        steps: [TransformationStep] = []
    ) {
        self.id = id
        self.originalText = originalText
        self.originalHTML = originalHTML
        self.inputSource = inputSource
        self.steps = steps
    }

    var currentText: String {
        steps.last?.outputText ?? originalText
    }

    var stepCount: Int { steps.count }
    var hasSteps: Bool { !steps.isEmpty }

    func addingStep(promptName: String, outputText: String, displayMode: EditorMode = .markdown, isPending: Bool = false) -> TransformationSession {
        var copy = self
        copy.steps.append(
            TransformationStep(
                promptName: promptName,
                inputText: currentText,
                outputText: outputText,
                displayMode: displayMode,
                isPending: isPending
            )
        )
        return copy
    }

    /// Replaces the step matching `id`'s output/pending flag in place,
    /// wherever it currently sits — used to finalize the placeholder tab
    /// added optimistically when a prompt starts running. Looked up by id
    /// rather than position so it's still found correctly even if other
    /// history steps were edited or deleted while this one was in flight.
    func updatingStep(id: UUID, outputText: String, isPending: Bool) -> TransformationSession {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return self }
        var copy = self
        let existing = copy.steps[index]
        copy.steps[index] = TransformationStep(
            id: existing.id,
            promptName: existing.promptName,
            inputText: existing.inputText,
            outputText: outputText,
            timestamp: existing.timestamp,
            displayMode: existing.displayMode,
            isPending: isPending
        )
        return copy
    }

    /// Removes the step matching `id`, wherever it currently sits — used to
    /// drop a placeholder tab whose prompt failed or was cancelled, without
    /// disturbing other steps added/removed elsewhere in the meantime.
    func removingStep(id: UUID) -> TransformationSession {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return self }
        var copy = self
        copy.steps.remove(at: index)
        return copy
    }

    func undoingLastStep() -> TransformationSession {
        guard hasSteps else { return self }
        var copy = self
        copy.steps.removeLast()
        return copy
    }

    func steppingTo(index: Int) -> TransformationSession {
        guard index >= 0, index < steps.count else { return self }
        var copy = self
        copy.steps = Array(steps.prefix(index + 1))
        return copy
    }

    func removingStep(at index: Int) -> TransformationSession {
        guard index >= 0, index < steps.count else { return self }
        var copy = self
        copy.steps.remove(at: index)
        return copy
    }
}
