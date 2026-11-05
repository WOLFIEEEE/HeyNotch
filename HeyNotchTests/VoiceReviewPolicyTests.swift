import XCTest

final class VoiceReviewPolicyTests: XCTestCase {
    func testProcessingFailureCanRetryBeforeAnyPasteAttempt() {
        XCTAssertTrue(VoiceReviewPolicy.canRetryCleanup(phase: .review, hasTranscript: true, pasteAttempted: false))
    }

    func testInsertionFailureCannotOfferRetryOrRepeatPaste() {
        XCTAssertFalse(VoiceReviewPolicy.canRetryCleanup(phase: .review, hasTranscript: true, pasteAttempted: true))
    }

    func testRetryRequiresTranscriptAndReviewPhase() {
        XCTAssertFalse(VoiceReviewPolicy.canRetryCleanup(phase: .review, hasTranscript: false, pasteAttempted: false))
        for phase: VoicePhase in [.idle, .preparing, .recording, .transcribing, .processing, .inserting, .finished] {
            XCTAssertFalse(VoiceReviewPolicy.canRetryCleanup(phase: phase, hasTranscript: true, pasteAttempted: false))
        }
    }
}
