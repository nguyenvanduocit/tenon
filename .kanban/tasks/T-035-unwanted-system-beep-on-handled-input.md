# T-035: Handled input must not trigger the macOS system beep
> Actions such as Backspace work, but macOS also plays the alert sound associated with an
> input event that no responder accepted.

- **priority**: medium
- **effort**: S
- **owner**: UNCLAIMED

## Reproduction
1. Open an app surface that accepts keyboard or button-driven input.
2. Trigger Backspace; check other controls that use the same input path.
3. Observe that the requested action happens and the macOS system alert sound also plays.

## Actual
- The app accepts and performs the action.
- macOS plays an error/unhandled-input sound at the same time.

## Expected
- A handled action produces no system alert sound.
- Backspace and the other affected controls retain their current functional behaviour.

## Criteria
- [ ] Record a minimal reliable reproduction and the complete set of controls known to use
      the affected event path
- [ ] Identify why the responder/event path still reaches the system beep after Tenon has
      handled the action
- [ ] Consume or route only the affected handled events; do not suppress legitimate system
      feedback for truly invalid input
- [ ] Add focused regression coverage where the event-routing rule can be tested
- [ ] Verify Backspace and every other reproduced control manually in the running app
