# What only a human can confirm — 2026-07-31

Sixteen commits landed between `3c06770` and `0e57918`. The suite is green at 730/0 and
every claim in those commits was checked against the tree. This file lists what the suite
**cannot** reach: pixels, sounds, memory, and the behaviour of a real relaunch.

Nothing here is known to be broken. These are unverified, which is a different thing, and
saying so is the point — several bugs tonight survived for weeks precisely because
something unverified was recorded as done.

**The app is not running.** `dev.sh` was terminated by SIGTERM at 22:17. Start it with
`./dev.sh ~/p/tenon` before working through this list. Tenon is a true singleton, so close
any other instance first, and note that starting it will make any agent's launch smoke
check exit silently.

## Fastest path — one launch covers most of it

1. **Title bar** — the mark should render, not a blank 14×14 gap. Drag an empty part of the
   bar; the window moves with system snapping. Double-click it; the window zooms, or does
   whatever System Settings ▸ Desktop & Dock says. The tab strip should sit on the traffic
   lights' row rather than below it. *(T-022, T-034)*
2. **Launcher `+`** — the popover opens and is searchable. Press ↓ repeatedly and watch the
   highlight: it must land on the row directly beneath the previous one, every time. This
   is the defect that was fixed; use the launcher a few times first so frecency interleaves
   the categories, which is when the old bug appeared. *(T-022)*
3. **Pane header menu** — right-click a pane header: `Split · Stack · Duplicate · Close`,
   with no type submenu anywhere. Duplicate should place the copy in free space rather than
   refusing. *(T-026)*
4. **Double-click a pane header** — the pane grows to the panes sharing its rows, or to the
   canvas edge. Nothing else shrinks. *(T-025)*
5. **Terminal keys** — press Backspace, the arrows, Return and Escape in a focused terminal.
   The shell behaves as before **and there is no alert sound**. Then trigger a genuinely
   unhandled key somewhere else and confirm it still beeps: the fix was scoped so real
   unhandled input keeps its feedback, and silence there would mean it was scoped too wide.
   *(T-035)*
6. **File Browser across workspaces** — open it in workspace A, expand a directory, switch
   to B, switch back. A's expansion and selection must be exactly as you left them. Repeat
   with the git panel and the sessions panel; all three had the same defect. *(T-036)*
7. **Editor** — open a file, scroll, switch panes, come back: the scroll position and
   selection survive. Then, with the pane **clean**, edit the file outside Tenon
   (`echo >> file`) — the pane reloads and keeps your place. Then make an edit **inside**
   Tenon, leave it unsaved, and change the file outside again — your buffer must survive
   untouched and a "Changed on disk — ⌘S keeps your version" badge must appear. That second
   case is the one that could cost someone work. *(T-016)*
8. **Quit and relaunch** — with several workspaces, tabs and a split open, quit Tenon and
   start it again. The tree comes back as you left it, including any pinned project root.
   Then try the failure paths: delete a workspace's folder and relaunch (that one workspace
   drops, the rest survive), and delete an open file and relaunch (that one pane degrades to
   empty). *(T-027)*
9. **A large diff** — open a diff of a heavily-rewritten file. It should appear immediately.
   The measurement was 65772 ms to about 100 ms on a 2700-line file with 2565 lines changed.
   *(T-028)*

## Needs a measurement, not just a look

10. **Unviewed panes cost nothing** — open roughly twenty terminal tabs without viewing
    them, then view them all, then leave one visible. Watch memory in Activity Monitor, and
    GPU/renderer cost with `powermetrics`. The claim is that never-viewed panes hold no
    surface, no PTY and no renderer buffers, and that nothing is ever torn down once viewed.
    The method is written up in `.kanban/tasks/T-031-unviewed-panes-claim-no-renderer.md`;
    the numbers were deliberately not claimed because the session was headless. *(T-031)*

## Developer-facing change worth knowing

11. **`TENON_PLUGINS_DIR` now prompts.** A plugin directory named by that variable is no
    longer trusted as if it shipped in the app bundle — that was a fail-open default. Add
    `TENON_TRUST_PLUGIN_INVENTORY=1`, matched exactly, to get the old behaviour. `"true"`
    deliberately does not count. *(T-033)*

## Landed after this list was first written

12. **Attention dots** — run something long in one pane and let a command finish in another,
    then look: the working pane and the finished-but-unseen pane are marked differently, the
    tab chip and sidebar row go bold with a count, and the title bar carries the total. Look
    at a pane and its mark clears; nothing re-marks it while you watch. Then switch away from
    Tenon entirely and let a command finish — **from the installed `.app`**, one notification
    banner per burst, and clicking it lands you on that pane even across workspaces.
    `swift run` deliberately no-ops the banner (`UNUserNotificationCenter` needs a bundle id),
    so this half needs the packaged app. *(T-029)*

13. **Settings ▸ CLI ▸ Install, from the installed app** — open Settings in
    `/Applications/Tenon.app` (not `swift run`), go to CLI, and click Install. The button
    must be enabled, not the *"No tenon-cli binary is available in this build"* message.
    Then, in a fresh terminal, `tenon-cli ping` against the running app. The bundled binary
    is verified self-contained by the installer, and it runs from an unrelated directory —
    what a person still has to confirm is the button and the round trip. *(T-045)*

14. **A real supervised fleet** — copy `examples/fleet-review/` into `plugins/`,
    restart, and run "Fleet Review" from the palette with a real `claude` on PATH. Three
    panes should appear and work *at the same time* — that concurrency is what the
    `terminalWait` lane change bought, and the headless test can only prove the intents
    overlap, not that three agents really run side by side. Watch the attention dots while
    they think, then read one transcript in full in its own pane. *(T-048)*

## Carries no human-visible surface

T-023 (build cache), T-037 (plugin global scope closure), T-019 and T-021 (verification
only, no behaviour change), T-020 (audit only).
