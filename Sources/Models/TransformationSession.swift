import Foundation

struct TransformationStep: Identifiable, Sendable {
    let id: UUID
    let promptName: String
    let inputText: String
    let outputText: String
    let timestamp: Date

    init(
        id: UUID = UUID(),
        promptName: String,
        inputText: String,
        outputText: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.promptName = promptName
        self.inputText = inputText
        self.outputText = outputText
        self.timestamp = timestamp
    }
}

struct TransformationSession: Identifiable, Sendable {
    let id: UUID
    let originalText: String
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
        inputSource: InputSource = .clipboard,
        steps: [TransformationStep] = []
    ) {
        self.id = id
        self.originalText = originalText
        self.inputSource = inputSource
        self.steps = steps
    }

    var currentText: String {
        steps.last?.outputText ?? originalText
    }

    var stepCount: Int { steps.count }
    var hasSteps: Bool { !steps.isEmpty }

    func addingStep(promptName: String, outputText: String) -> TransformationSession {
        var copy = self
        copy.steps.append(
            TransformationStep(
                promptName: promptName,
                inputText: currentText,
                outputText: outputText
            )
        )
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
}
