# Evidence and claims

An agent tells you it fixed the bug and the tests pass. Do you believe it?

You cannot answer that from the sentence. You answer it from the diff, the
command output, the test receipt — and the cost of getting to those is what
determines whether you actually check or just nod.

Tenon's position: **compression is only safe when it is reversible.** Every
condensed claim keeps a direct path back to the thing it condensed.

## The rule

A context capsule and an attention signal are *navigation aids*. They do not
replace the terminal, transcript, diff, command result or test receipt. Those
remain the source evidence, always.

So every material claim carries:

- **source** — exactly which artifact it came from;
- **freshness** — when that was captured;
- **authority** — how strongly it is known;
- **a return path** — a direct way back to the raw thing.

The measured version of this, for the supervision experiment that is not yet
built: every material capsule claim must resolve to an exact source identity, an
immutable location and hash, capture time, freshness, and authority level.
Traceability errors and claims unsupported by their own cited evidence are
counted separately, with zero accepted in the reviewed sample.

## Reported is not observed

An agent *saying* it ran the tests, and Tenon *watching* a test command finish,
are two different facts. Flattening them into one row would be a lie of
formatting.

[Agent Lens](/guide/agent-lens) keeps them distinct. The timeline shows which
claims are reported by the agent and which were directly observed, because those
warrant different amounts of trust and the difference is exactly what a
supervisor is for.

## Folding, not deleting

Finished work collapses into one quiet row so the timeline stays scannable.
Expanding it returns **every original fact with its stable ID**.

Nothing is deleted to make a view tidy. A supervision surface that discards
detail to look calm has optimized for the wrong thing — it looks like less work
because it is showing you less, not because there is less.

Instructions get the same treatment from the other direction: system, developer,
project and skill instructions stay collapsed as *context*, because they explain
the agent rather than record what it did.

## Degrade explicitly, never guess

When Agent Lens cannot bind a pane to a provider session with authority, it says
so and hands you the terminal.

It would be easy to pick the newest transcript in the sessions directory by
modification time. It would usually be right. Tenon does not do it, because
"usually right" in an evidence tool is the same as untrustworthy: once you know
it guesses, you have to verify everything it says, and then it has saved you
nothing.

A stale process, a child-agent fact, a mismatched process group, or a rotated
surface token are all rejected for the same reason.

## Evidence is required to ask

The clearest place this principle is enforced rather than merely stated is
[`agent.ask.v1`](/reference/intents/agent-ask-v1).

Its input schema requires `evidence`, with a minimum of one entry. An agent
literally **cannot** ask you for a decision without attaching what the decision
should be made from.

```json
{
  "question": "Two callers depend on the old signature. Break them or adapt?",
  "choices": [ /* … */ ],
  "evidence": [
    {"label": "caller A", "url": "file:///Users/me/app/src/auth.ts"},
    {"label": "caller B", "url": "file:///Users/me/app/src/session.ts"}
  ],
  "recipient": {"kind": "human"},
  "timeoutMs": 55000
}
```

A question with nothing behind it is an interruption. A question with its
evidence attached is a request for judgment, and judgment is the thing you are
there to supply.

## The same standard, applied to this site

The intent reference here is generated from Tenon itself, not typed out. Where
the generator cannot see a contract's schema, the page **says so and sends you
to the runtime**, rather than printing a hand-copy that will quietly go stale.
Where the schemas came from a build older than the catalog beside them, the
index says which build and which contracts are affected.

Documentation is a compression of a codebase. The same rule applies to it.
