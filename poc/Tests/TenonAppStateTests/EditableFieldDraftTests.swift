import Foundation
@testable import TenonApp
import XCTest

/// T-093. A field being typed in belongs to the person typing in it.
///
/// The defect this pins is not hypothetical: a plugin republishes its whole view for any reason
/// — a navigation finishing, a status tick, a poll — and every one of those used to land as an
/// assignment straight into the draft of a focused field.
final class EditableFieldDraftTests: XCTestCase {
    func testAValuePublishedWhileTypingLeavesTheDraftAlone() {
        var draft = EditableFieldDraft(value: "https://old.example")
        draft.text = "https://user-is-ty"

        draft.externalValueChanged(to: "https://republished.example", isFocused: true)

        XCTAssertEqual(
            draft.text,
            "https://user-is-ty",
            "a republish must not overwrite characters being entered"
        )
    }

    func testTheHeldValueAppliesWhenFocusLeaves() {
        var draft = EditableFieldDraft(value: "https://old.example")
        draft.text = "https://user-is-ty"
        draft.externalValueChanged(to: "https://republished.example", isFocused: true)

        draft.focusChanged(to: false)

        XCTAssertEqual(
            draft.text,
            "https://republished.example",
            "once editing ends the field shows what its owner says it is"
        )
        XCTAssertNil(draft.deferredValue, "the held value is consumed, not replayed")
    }

    func testAValuePublishedWhileUnfocusedAppliesImmediately() {
        var draft = EditableFieldDraft(value: "https://old.example")

        draft.externalValueChanged(to: "https://new.example", isFocused: false)

        XCTAssertEqual(draft.text, "https://new.example")
        XCTAssertNil(draft.deferredValue)
    }

    /// Blur alone must not resurrect anything. Otherwise a field that was never republished
    /// would snap back to a stale value the moment the user clicked away.
    func testLeavingAFieldNobodyPublishedIntoKeepsWhatWasTyped() {
        var draft = EditableFieldDraft(value: "start")
        draft.text = "typed by hand"

        draft.focusChanged(to: false)

        XCTAssertEqual(draft.text, "typed by hand")
    }

    /// A republish carrying the value already on screen is not a pending change, so leaving the
    /// field must not undo what was typed after it.
    func testARepublishOfTheSameTextIsNotHeld() {
        var draft = EditableFieldDraft(value: "same")
        draft.text = "same"

        draft.externalValueChanged(to: "same", isFocused: true)
        draft.text = "same plus typing"
        draft.focusChanged(to: false)

        XCTAssertEqual(draft.text, "same plus typing")
    }

    /// The last publish wins; a focused field does not accumulate a queue of stale values.
    func testOnlyTheMostRecentHeldValueSurvives() {
        var draft = EditableFieldDraft(value: "a")
        draft.text = "typing"

        draft.externalValueChanged(to: "b", isFocused: true)
        draft.externalValueChanged(to: "c", isFocused: true)
        draft.focusChanged(to: false)

        XCTAssertEqual(draft.text, "c")
    }

    /// Regaining focus is not an apply point — the person is typing again.
    func testFocusReturningDoesNotApplyTheHeldValue() {
        var draft = EditableFieldDraft(value: "a")
        draft.text = "typing"
        draft.externalValueChanged(to: "b", isFocused: true)

        draft.focusChanged(to: true)

        XCTAssertEqual(draft.text, "typing")
        XCTAssertEqual(draft.deferredValue, "b")
    }
}
