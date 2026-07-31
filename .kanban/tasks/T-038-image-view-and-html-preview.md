# T-038: Support image view, HTML preview
> Open image files in an image viewer pane and HTML files in a rendered preview pane inside the workspace.

- **priority**: medium
- **effort**: M

## Owner / files (agent lock)
session 247281cf — **DONE 11:3x, LOCKS RELEASED.** NEW `TenonCore/FilePaneKind.swift`,
NEW `TenonApp/FilePreviewSlotViews.swift`, `TenonApp/BuiltInSlotViews.swift` (one branch),
NEW `Tests/TenonCoreTests/FilePaneKindTests.swift`, boundary doc.

## Criteria
- [x] Images render as pictures — `ImageSlotView`, decoded off the main actor so a large
      file does not stutter the window
- [x] HTML renders as a page — `WebPreviewSlotView`
- [x] Classified before implementation — same-owner DIRECT, recorded in the boundary doc's
      DIRECT inventory. `SlotContent.file(path:)` and its native editor were already
      host-owned, so a second renderer for the same content kind crosses nothing: no new
      intent, no new plugin, no new `tenon` member
- [x] Broken or unsupported files degrade — an image that will not decode says so and names
      the file; a missing HTML file renders a message; anything unrecognised keeps the
      editor, which is legible for everything
- [x] Headless tests — `FilePaneKindTests`, 7 cases, no window

## The one design decision worth recording

The HTML preview deliberately does **not** reuse `PluginWebSurfacePool`, which the card
suggested. That pool keys surfaces by plugin installation precisely so each plugin owns a
persistent browser profile; a file preview belongs to no plugin, and minting a fake
installation to borrow the pool would hand a host pane a plugin's identity and its cookie
jar. The preview is a renderer, not a browser: JavaScript off, ephemeral data store, read
access scoped to the file's own directory, and any navigation away from the file refused —
a pane that silently became a browser would be a browser with none of a browser's controls.

## 🐞 Mutation testing caught a comment that was simply false

The first version hand-guarded leading dots, with a comment asserting that
`NSString.pathExtension` "reports gitignore for .gitignore". Two mutations — deleting that
guard, and deciding on the whole path instead of the file name — **reddened nothing**, which
said the lines were doing no work.

Measured instead of assumed: `pathExtension` returns `""` for `.gitignore` and `.png`, and
already reads only the last path component. So the guard was dead where it agreed with
Foundation — and **wrong** where it did not: it would have forced `.hidden.png`, a real PNG,
to the editor. Both lines deleted, the false comment replaced with the measurement, and a
case added for `.hidden.png`. The rule is now three lines, and the mutations redden it.

## Evidence
`swift build` exit 0 (warnings-as-errors) + full `swift test` **876 / 0** (869 before).
Human-verify: the pixels — an actual image and an actual page in a pane.

## Notes
- The browser plugin + `PluginWebSurfacePool` already exist — HTML preview likely reuses that surface path rather than adding a new native view.
- Decide whether these ship as plugins (canonical intents + contributions) or host-native panes; the boundary law selects the mechanism.
