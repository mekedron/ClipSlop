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

    @Test("updatingStep(id:) finalizes a pending step in place")
    func updatingStepFinalizes() {
        let session = TransformationSession(originalText: "hello")
            .addingStep(promptName: "Fix Grammar", outputText: "", isPending: true)
        let pendingID = session.steps[0].id

        let finalized = session.updatingStep(id: pendingID, outputText: "Hello.", isPending: false)

        #expect(finalized.steps.count == 1)
        #expect(finalized.steps[0].id == pendingID)
        #expect(finalized.steps[0].promptName == "Fix Grammar")
        #expect(finalized.steps[0].outputText == "Hello.")
        #expect(finalized.steps[0].isPending == false)
    }

    @Test("updatingStep(id:) for an unknown id is a no-op")
    func updatingStepUnknownIDIsNoOp() {
        let session = TransformationSession(originalText: "hello")
            .addingStep(promptName: "Fix Grammar", outputText: "Hello.")
        let updated = session.updatingStep(id: UUID(), outputText: "anything", isPending: false)
        #expect(updated.steps.count == session.steps.count)
        #expect(updated.steps[0].id == session.steps[0].id)
        #expect(updated.steps[0].outputText == session.steps[0].outputText)
    }

    @Test("updatingStep(id:) only touches the matching step, others are untouched")
    func updatingStepOnlyTouchesMatchingStep() {
        let session = TransformationSession(originalText: "hello")
            .addingStep(promptName: "Translate", outputText: "Bonjour")
            .addingStep(promptName: "Rewrite", outputText: "", isPending: true)
        let pendingID = session.steps[1].id

        let finalized = session.updatingStep(id: pendingID, outputText: "Bonjour, mon ami.", isPending: false)

        #expect(finalized.steps.count == 2)
        #expect(finalized.steps[0].promptName == "Translate")
        #expect(finalized.steps[0].outputText == "Bonjour")
        #expect(finalized.steps[1].promptName == "Rewrite")
        #expect(finalized.steps[1].outputText == "Bonjour, mon ami.")
        #expect(finalized.steps[1].isPending == false)
    }

    @Test("updatingStep(id:) still finds the step after an earlier step was removed")
    func updatingStepFindsStepAfterReordering() {
        // Simulates: a prompt is running (pending, tracked by id) while the
        // user deletes an earlier, unrelated history row from the sidebar —
        // the pending step's position shifts, but it must still be found
        // and finalized correctly by id once the response comes back.
        let session = TransformationSession(originalText: "hello")
            .addingStep(promptName: "Translate", outputText: "Bonjour")
            .addingStep(promptName: "Rewrite", outputText: "", isPending: true)
        let pendingID = session.steps[1].id

        let afterDeletion = session.removingStep(at: 0)
        #expect(afterDeletion.steps.count == 1)
        #expect(afterDeletion.steps[0].id == pendingID)

        let finalized = afterDeletion.updatingStep(id: pendingID, outputText: "Réécrit.", isPending: false)

        #expect(finalized.steps.count == 1)
        #expect(finalized.steps[0].id == pendingID)
        #expect(finalized.steps[0].outputText == "Réécrit.")
        #expect(finalized.steps[0].isPending == false)
    }

    @Test("removingStep(id:) drops an optimistically-added pending step on cancel/error")
    func removingStepByIDDropsPendingStep() {
        let session = TransformationSession(originalText: "hello")
            .addingStep(promptName: "Translate", outputText: "Bonjour")
        let withPending = session.addingStep(promptName: "Rewrite", outputText: "", isPending: true)
        let pendingID = withPending.steps[1].id
        #expect(withPending.steps.count == 2)

        let reverted = withPending.removingStep(id: pendingID)

        #expect(reverted.steps.count == 1)
        #expect(reverted.steps.last?.promptName == "Translate")
        #expect(reverted.currentText == "Bonjour")
    }

    @Test("removingStep(id:) for an unknown id is a no-op")
    func removingStepByIDUnknownIsNoOp() {
        let session = TransformationSession(originalText: "hello")
            .addingStep(promptName: "Translate", outputText: "Bonjour")
        let updated = session.removingStep(id: UUID())
        #expect(updated.steps.count == session.steps.count)
        #expect(updated.steps[0].id == session.steps[0].id)
    }

    @Test("undoingLastStep still works for the general undo action")
    func undoingLastStepDropsLastStep() {
        let session = TransformationSession(originalText: "hello")
            .addingStep(promptName: "Translate", outputText: "Bonjour")
            .addingStep(promptName: "Rewrite", outputText: "Bonjour, mon ami.")

        let reverted = session.undoingLastStep()

        #expect(reverted.steps.count == 1)
        #expect(reverted.steps.last?.promptName == "Translate")
    }
}
