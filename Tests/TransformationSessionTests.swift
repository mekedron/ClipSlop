import Foundation
import Testing
@testable import ClipSlop

/// Pure-logic tests for `TransformationSession`'s optimistic "pending step"
/// support — added so the history sidebar can show a placeholder tab the
/// instant a prompt starts running, instead of only once the response
/// finishes. No UI, no async — pure value-type transformations.

@Suite("TransformationSession pending steps")
struct TransformationSessionPendingStepTests {

    @Test("addingStep defaults to not pending")
    func addingStepDefaultsToNotPending() {
        let session = TransformationSession(originalText: "hello")
        let updated = session.addingStep(promptName: "Fix Grammar", outputText: "Hello.")
        #expect(updated.steps.last?.isPending == false)
    }

    @Test("addingStep can mark the new step pending with empty output")
    func addingStepCanMarkPending() {
        let session = TransformationSession(originalText: "hello")
        let updated = session.addingStep(promptName: "Fix Grammar", outputText: "", isPending: true)
        #expect(updated.steps.count == 1)
        #expect(updated.steps.last?.isPending == true)
        #expect(updated.steps.last?.outputText == "")
        #expect(updated.steps.last?.promptName == "Fix Grammar")
    }

    @Test("updatingLastStep finalizes a pending step in place")
    func updatingLastStepFinalizes() {
        let session = TransformationSession(originalText: "hello")
            .addingStep(promptName: "Fix Grammar", outputText: "", isPending: true)
        let pendingID = session.steps.last?.id

        let finalized = session.updatingLastStep(outputText: "Hello.", isPending: false)

        #expect(finalized.steps.count == 1)
        #expect(finalized.steps.last?.id == pendingID)
        #expect(finalized.steps.last?.promptName == "Fix Grammar")
        #expect(finalized.steps.last?.outputText == "Hello.")
        #expect(finalized.steps.last?.isPending == false)
    }

    @Test("updatingLastStep on a session with no steps is a no-op")
    func updatingLastStepNoStepsIsNoOp() {
        let session = TransformationSession(originalText: "hello")
        let updated = session.updatingLastStep(outputText: "anything", isPending: false)
        #expect(updated.steps.isEmpty)
    }

    @Test("updatingLastStep only touches the last step, earlier steps are untouched")
    func updatingLastStepOnlyTouchesLastStep() {
        let session = TransformationSession(originalText: "hello")
            .addingStep(promptName: "Translate", outputText: "Bonjour")
            .addingStep(promptName: "Rewrite", outputText: "", isPending: true)

        let finalized = session.updatingLastStep(outputText: "Bonjour, mon ami.", isPending: false)

        #expect(finalized.steps.count == 2)
        #expect(finalized.steps[0].promptName == "Translate")
        #expect(finalized.steps[0].outputText == "Bonjour")
        #expect(finalized.steps[1].promptName == "Rewrite")
        #expect(finalized.steps[1].outputText == "Bonjour, mon ami.")
        #expect(finalized.steps[1].isPending == false)
    }

    @Test("undoingLastStep drops an optimistically-added pending step on cancel/error")
    func undoingLastStepDropsPendingStep() {
        let session = TransformationSession(originalText: "hello")
            .addingStep(promptName: "Translate", outputText: "Bonjour")
        let withPending = session.addingStep(promptName: "Rewrite", outputText: "", isPending: true)
        #expect(withPending.steps.count == 2)

        let reverted = withPending.undoingLastStep()

        #expect(reverted.steps.count == 1)
        #expect(reverted.steps.last?.promptName == "Translate")
        #expect(reverted.currentText == "Bonjour")
    }
}
