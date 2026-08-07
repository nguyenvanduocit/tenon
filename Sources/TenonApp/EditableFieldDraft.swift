// @domain: field-draft
import Foundation

/// Who owns the characters in a text field, and when an owner's value takes the field back.
///
/// A field has two writers: the person typing in it, and whatever publishes its value — a
/// plugin republishing its view, a navigation finishing, a status tick that happens to rebuild
/// the same tree. They collide constantly, because a republish is exactly what a background
/// task does while someone edits an address bar.
///
/// The rule is that focus decides. While the field is focused the person owns it; an arriving
/// value is remembered, not applied. When focus leaves, the field goes back to showing what its
/// owner says it is. Nothing is silently dropped and nothing is silently overwritten.
///
/// The type is a value with no SwiftUI in it so the rule can be asserted without a window;
/// views bind to `text` and forward the two events.
struct EditableFieldDraft: Equatable {
    /// What the field shows and what a submit sends.
    var text: String

    /// A value that arrived while the person was typing, waiting for them to leave.
    private(set) var deferredValue: String?

    init(value: String = "") {
        text = value
    }

    /// The owner published a value.
    mutating func externalValueChanged(to newValue: String, isFocused: Bool) {
        guard isFocused else {
            text = newValue
            deferredValue = nil
            return
        }
        // Applying now would delete characters mid-word. Remembering it costs one string and
        // keeps the field truthful the moment editing ends.
        deferredValue = newValue == text ? nil : newValue
    }

    /// Focus moved. Leaving the field hands it back to its owner if the owner spoke while the
    /// person was typing.
    mutating func focusChanged(to isFocused: Bool) {
        guard !isFocused, let deferredValue else { return }
        text = deferredValue
        self.deferredValue = nil
    }
}
