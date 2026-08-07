# T-075: Detecting an agent is not a decision to switch views
> The moment Agent Lens resolves a transcript it silently replaces the person's live terminal
> with the Session view. Detection is an observation; choosing the renderer is the person's.

- **priority**: high
- **effort**: XS

## Owner / files (agent lock)
DONE 2026-08-06 17:5x by session 6341cb8e — locks released, no files claimed.

## Why this is wrong
The pane the person is looking at is a live PTY they are typing into. Attaching a transcript
is host-side inference that can land mid-keystroke, and it yanks the renderer out from under
them — the same class of surprise as focus stealing. Nothing about resolving a transcript
tells us the person wanted to stop reading raw terminal output.

The affordance already exists without the automation: the moment an agent is detected, the
mode bar appears above the pane with the provider, its status, and the Session / Terminal /
Split picker. That bar *is* the offer. Taking the choice for the person adds nothing it does
not already say.

## Criteria
- [x] Detection never changes `AgentLensViewModel.mode`; the pane stays on `.terminal` until
      a person picks another renderer —
      `testLiveProcessTranscriptPipelineKeepsTheTerminalAndRoutesGuardedInput` drives a real
      process and a real transcript to an exact resolution and asserts `mode == .terminal`
- [x] The mode bar still appears as soon as an agent is detected, so the Session view is one
      click away — `AgentLensSlotView` keys it off `isAgentDetected`, untouched here
- [x] A mode the person picked survives re-attachment (a `/new` root session, a re-resolve) —
      structural: `attach` no longer writes `mode` at all, so no re-resolve can move it
- [x] Full suite green — 1195 / 0

## Left open
A failed send still forces the pane back to `.terminal` (`sendDraft`, `reportInputFailure`).
That is the same automatic renderer change in the other direction, and the error diagnostic
already surfaces in the mode bar. Raised with the user; not changed unilaterally.
