import XCTest
@testable import ma

final class EditorBridgeTests: XCTestCase {
    @MainActor
    func testFormattingRequiresKnownActionReadySessionAndFreshSequence() async {
        let document = MarkdownDocument()
        let session = EditorSession(document: document)
        var actions: [MarkdownEditAction] = []
        session.onFormat = { actions.append($0) }
        func format(_ action: String, sequence: Int, epoch: Int = 0) -> [String: Any] {
            ["version": 1, "sessionID": session.id, "epoch": epoch,
             "seq": sequence, "type": "format", "action": action]
        }
        session.receiveEnvelope(format("bold", sequence: 1))
        XCTAssertTrue(actions.isEmpty)
        session.receiveEnvelope(["version": 1, "sessionID": session.id, "epoch": 0,
                                 "seq": 2, "type": "ready"])
        session.receiveEnvelope(format("unknown", sequence: 3))
        session.receiveEnvelope(format("bold", sequence: 3, epoch: 1))
        XCTAssertTrue(actions.isEmpty)
        session.receiveEnvelope(format("bold", sequence: 3))
        session.receiveEnvelope(format("bold", sequence: 3))
        XCTAssertEqual(actions.count, 1)
        guard case .bold = actions.first else { return XCTFail("굵게 동작이 전달되지 않음") }
        await session.dispose()
        session.receiveEnvelope(format("italic", sequence: 4))
        XCTAssertEqual(actions.count, 1)
    }

    @MainActor
    func testModeToggleRequiresReadyCurrentSessionAndFreshSequence() async {
        let document = MarkdownDocument()
        let session = EditorSession(document: document)
        var toggles = 0
        session.onToggleViewMode = { toggles += 1 }
        func envelope(_ type: String, sequence: Int, epoch: Int = 0) -> [String: Any] {
            ["version": 1, "sessionID": session.id, "epoch": epoch,
             "seq": sequence, "type": type]
        }
        session.receiveEnvelope(envelope("modeToggle", sequence: 1))
        XCTAssertEqual(toggles, 0)
        session.receiveEnvelope(envelope("ready", sequence: 2))
        session.receiveEnvelope(envelope("modeToggle", sequence: 3, epoch: 1))
        XCTAssertEqual(toggles, 0)
        session.receiveEnvelope(envelope("modeToggle", sequence: 3))
        session.receiveEnvelope(envelope("modeToggle", sequence: 3))
        XCTAssertEqual(toggles, 1)
        await session.dispose()
        session.receiveEnvelope(envelope("modeToggle", sequence: 4))
        XCTAssertEqual(toggles, 1)
    }

    @MainActor
    func testEnvelopeRejectsStaleEpochSequenceAndInvalidRanges() {
        let document = MarkdownDocument()
        let session = EditorSession(document: document)
        func state(_ seq: Any, epoch: Int = 0, location: Any = 2) -> [String: Any] {
            ["version": 1, "sessionID": session.id, "epoch": epoch, "seq": seq,
             "type": "state", "text": "😀한글", "selection": ["location": location, "length": 2]]
        }
        session.receiveEnvelope(state(1))
        XCTAssertEqual(document.editableContent, "😀한글")
        XCTAssertEqual(session.selection, NSRange(location: 2, length: 2))
        document.editableContent = "승인 상태"
        for body in [state(1), state(2, epoch: 1), state(2.5), state(true), state(2, location: 99)] {
            session.receiveEnvelope(body)
            XCTAssertEqual(document.editableContent, "승인 상태")
        }
    }

    @MainActor
    func testSessionlessBarrierPreservesExistingSavePath() async throws {
        let document = MarkdownDocument()
        let success = await document.withEditorSnapshot { document.editableContent = "한글😀\r\n" }
        XCTAssertTrue(success)
        XCTAssertEqual(document.editableContent, "한글😀\r\n")
    }
}
