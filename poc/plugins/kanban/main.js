// Kanban — the .kanban/ board as native columns and cards, buttons that move a card to
// the adjacent column, and a button that hands a task to an agent.
//
// The board is already how agents in this repo tell each other what they are doing. This
// makes it an attention surface: which column is full, which task is claimed, one click
// to put an agent on a task in a real PTY, and one click to move a card — a rewrite of
// the shared board file that every watcher sees as exactly one change.
//
// Plugin-only on purpose. Nothing here reaches a host type: files arrive through the
// filesystem intents, the tree is a CONTRIBUTION, the watch is a RESOURCE this pane owns,
// and Start is `terminal.open.v1`. If that is not enough to build a real feature, the
// boundary is too narrow — that is the claim this plugin exists to test.

var VIEW = "board";
var KANBAN_DIR = ".kanban";
var BOARD_FILE = "board.md";

// Bounds (invariant 10). A board is written by many agents and Done grows without limit,
// so the snapshot the host renders is capped rather than however long the file got.
var MAX_ROWS_PER_COLUMN = 12;
var MAX_LABEL = 160;
var MAX_CRITERIA = 12;
var DEBOUNCE_MS = 250;

// A card is a column wide, not a pane wide: what reads as a title on one line of the
// file becomes six wrapped lines in a card, and agents append status prose after the
// second " — " that would render as a badge the size of a paragraph. Text nodes do not
// truncate, so the card states its own limits.
var MAX_CARD_TITLE = 96;
var MAX_CARD_META = 24;

// A column is a fixed width and the board scrolls sideways past the pane edge. Sharing
// the pane equally made five columns on a narrow pane five unreadable slivers, and every
// card inside them wrapped to single words; a board is columns you scroll to instead.
var COLUMN_WIDTH = 260;

// Following a started agent (T-066). One bounded viewport read per tick answers "what is
// it doing now" however long the run gets — the alternative, paging the whole scrollback,
// costs more every minute the agent stays alive. Both bounds are the pane's, not the
// agent's: a run outlives the modal, the polling does not.
var TRACK_INTERVAL_MS = 1200;
var MAX_TAIL_LINES = 15;
var MAX_TAIL_LINE = 160;

var panes = {};

tenon.views.register(VIEW, { title: "Kanban", instanced: true });

function makePane(instanceID) {
  return {
    id: instanceID,
    workspaceId: null,
    workspacePath: "",
    boardPath: "",
    watchDir: "",
    watch: null,
    debounceHandle: null,
    columns: [],
    rawBoard: undefined,
    error: "",
    writeError: "",
    // The task whose detail sheet is open, and that task's parsed file.
    openTask: null,
    detail: null,
    // Agent runs this pane started, keyed by task id: { paneID, exited, tail, error }.
    // A run survives closing the sheet — reopening a task shows the agent still going.
    runs: {},
    trackHandle: null,
    // Bumped on every refresh so a slow read that lands after a newer one is dropped
    // instead of overwriting it.
    generation: 0,
    // Moves on this pane, serialized: the tail of the chain and how many sit in it.
    movesInFlight: null,
    queuedMoves: 0
  };
}

function paneList() {
  var out = [];
  for (var key in panes) {
    if (Object.prototype.hasOwnProperty.call(panes, key)) out.push(panes[key]);
  }
  return out;
}

function clip(text, limit) {
  if (typeof text !== "string") return "";
  if (text.length <= limit) return text;
  return text.slice(0, limit - 1) + "…";
}

// --- The format (aio-kanban v3), parsed verbatim -----------------------------------
//
// Every parser below is fail-soft by construction: a line that does not match is skipped
// and the rest of the board still renders. A board half-written by another agent is the
// normal case here, not the exception, so a strict parser would blank the pane exactly
// when the human most wants to look at it.

// The one heading predicate, shared by parseBoard and relocateTaskLine: both must
// enumerate exactly the same columns, or a move computes its target against columns the
// pane never drew. A bare "## " stub — a board half-written by another agent — is not a
// column for either.
var COLUMN_HEADING = /^##\s+(.+?)\s*$/;

function parseBoard(text) {
  var columns = [];
  var current = null;
  var lines = String(text).split("\n");
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    var heading = COLUMN_HEADING.exec(line);
    if (heading) {
      current = { name: heading[1], tasks: [] };
      columns.push(current);
      continue;
    }
    if (!current) continue;
    var row = /^-\s+\[(T-\d+)\]\(([^)]+)\)\s*(.*)$/.exec(line);
    if (!row) continue;
    current.tasks.push({
      id: row[1],
      path: row[2],
      title: titleOf(row[3]),
      meta: metaOf(row[3])
    });
  }
  return columns;
}

// A board line is `Title — priority/effort`, but a line may carry further ` — ` segments
// (agents append status notes). The first separator ends the title; the segment after it
// is the meta. Everything beyond is deliberately dropped rather than shown as a title.
function splitOnFirstDash(rest) {
  var index = rest.indexOf(" — ");
  if (index < 0) return [rest, ""];
  return [rest.slice(0, index), rest.slice(index + 3)];
}

function titleOf(rest) {
  return clip(splitOnFirstDash(rest)[0].trim(), MAX_LABEL);
}

function metaOf(rest) {
  var tail = splitOnFirstDash(rest)[1];
  if (!tail) return "";
  return clip(splitOnFirstDash(tail)[0].trim(), MAX_LABEL);
}

function parseTask(text) {
  var lines = String(text).split("\n");
  var detail = { title: "", description: "", priority: "", effort: "", criteria: [] };
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    var heading = /^#\s+(T-\d+):\s*(.+?)\s*$/.exec(line);
    if (heading && !detail.title) {
      detail.title = clip(heading[2], MAX_LABEL);
      continue;
    }
    var quote = /^>\s*(.+?)\s*$/.exec(line);
    if (quote && !detail.description) {
      detail.description = clip(quote[1], MAX_LABEL);
      continue;
    }
    var field = /^-\s+\*\*(priority|effort)\*\*:\s*(.+?)\s*$/.exec(line);
    if (field) {
      detail[field[1]] = clip(field[2], 32);
      continue;
    }
    var criterion = /^\s*-\s+\[([ xX])\]\s*(.+?)\s*$/.exec(line);
    if (criterion && detail.criteria.length < MAX_CRITERIA) {
      detail.criteria.push({
        done: criterion[1] !== " ",
        text: clip(criterion[2], MAX_LABEL)
      });
    }
  }
  return detail;
}

// --- Reading ------------------------------------------------------------------------

// Bounds on one file read (invariant 10). The host serves at most one inline page
// (48 KiB) per reply, so MAX_PAGES caps a read near 1 MB — past that the pane reports
// the size instead of holding a cursor loop open forever. A page can also come back
// invalidated when another agent rewrites the file mid-read; the whole read restarts,
// at most MAX_READ_RESTARTS times, because concurrent writers are the normal case here.
var MAX_PAGES = 24;
var MAX_READ_RESTARTS = 3;

// Resolves to { text } on success, { missing: true } when the path does not exist, and
// { reason } for every other failure. The distinction keeps the pane honest: only a
// missing file may render as "No board"; anything else names what actually went wrong.
async function readFile(path, call = tenon.intents) {
  for (var attempt = 0; attempt < MAX_READ_RESTARTS; attempt++) {
    var text = "";
    var input = { path: path };
    var invalidated = false;
    for (var page = 0; page < MAX_PAGES; page++) {
      var result = await call.send("filesystem.file.read.v1", input);
      if (!result.ok) return readFailure(result);
      var value = result.value || {};
      if (value.invalidated) {
        invalidated = true;
        break;
      }
      var content = value.content;
      if (!content || content.kind !== "inline") {
        return { reason: "unexpected-content-shape" };
      }
      text += content.text || "";
      if (!value.cursor) return { text: text };
      input = { path: path, cursor: value.cursor };
    }
    if (!invalidated) return { reason: "file-larger-than-" + MAX_PAGES + "-pages" };
  }
  return { reason: "file-kept-changing-mid-read" };
}

function readFailure(result) {
  var error = result.error || {};
  if (error.code === "dev.tenon.core.path-not-found") return { missing: true };
  var reason = error.details && error.details.reason;
  return { reason: String(reason || error.code || "unknown") };
}

// The workspace that owns a pane, resolved by the host.
async function owningWorkspace(instanceID, call = tenon.intents) {
  var result = await call.send("workspace.pane.owner.v1", { paneID: instanceID });
  if (!result.ok) return { id: null, path: "" };
  return { id: result.value.workspaceID, path: result.value.workspacePath };
}

async function refresh(st, call = tenon.intents) {
  if (!st.boardPath) return;
  st.generation += 1;
  var generation = st.generation;
  var read = await readFile(st.boardPath, call);
  // A read that resolves after a newer one, or after this pane closed, must not publish.
  if (panes[st.id] !== st || generation !== st.generation) return;

  if (read.text === undefined) {
    st.columns = [];
    st.error = read.missing
      ? "No board at " + st.boardPath
      : "Board read failed: " + read.reason;
  } else {
    var previous = st.rawBoard;
    st.rawBoard = read.text;
    st.columns = parseBoard(read.text);
    st.error = "";
    // A fact, not a request: anyone who declared this channel hears, nobody has to, and
    // this plugin never learns who did. Only published when the board really changed, so
    // a watch that fires on an unrelated file in .kanban/ says nothing.
    if (previous !== undefined && previous !== read.text) {
      tenon.events.emit("board.changed", { path: st.boardPath });
    }
  }

  if (st.openTask) {
    var still = findTask(st, st.openTask);
    if (!still) {
      st.openTask = null;
      st.detail = null;
    } else {
      var detailRead = await readFile(
        tenon.path.join(st.workspacePath, KANBAN_DIR, still.path.replace(/^\.\//, "")),
        call
      );
      if (panes[st.id] !== st || generation !== st.generation) return;
      st.detail = detailRead.text === undefined ? null : parseTask(detailRead.text);
    }
  }
  render(st);
}

function findTask(st, id) {
  for (var i = 0; i < st.columns.length; i++) {
    var tasks = st.columns[i].tasks;
    for (var j = 0; j < tasks.length; j++) {
      if (tasks[j].id === id) return tasks[j];
    }
  }
  return null;
}

// --- Writing ------------------------------------------------------------------------

// Bounds on one file write (invariant 10), the mirror of the read bounds above. A page
// carries at most WRITE_PAGE_BYTES of UTF-8 — the host's inline bound — and the page
// count stays inside the host's 1 MiB staged-write budget (21 × 48 KiB < 1 MiB), so a
// board too big to stage is refused here with its size named instead of half-staged.
var WRITE_PAGE_BYTES = 48 * 1024;
var MAX_WRITE_PAGES = 21;

// Splits on code-point boundaries: a page that cut a character in half would not survive
// the string round-trip to the host, and the rewrite must be byte-exact.
function splitWritePages(text) {
  var pages = [];
  var page = "";
  var pageBytes = 0;
  for (var i = 0; i < text.length; i++) {
    var code = text.codePointAt(i);
    var unit = text[i];
    if (code > 0xffff) {
      unit += text[i + 1];
      i += 1;
    }
    var bytes = code <= 0x7f ? 1 : code <= 0x7ff ? 2 : code <= 0xffff ? 3 : 4;
    if (pageBytes + bytes > WRITE_PAGE_BYTES) {
      pages.push(page);
      page = "";
      pageBytes = 0;
    }
    page += unit;
    pageBytes += bytes;
  }
  pages.push(page);
  return pages;
}

// Resolves to null on success and { reason } on failure. One page publishes in a single
// atomic call — byte-identical to the pre-paging contract. More pages stream through the
// host staging: the first opens it, each later page carries the returned cursor, and the
// last page commits (the default), so the file on disk changes exactly once, at the
// rename. Any failed page ends the whole write; the host reclaims the staging.
async function writeFile(path, text) {
  var pages = splitWritePages(text);
  if (pages.length > MAX_WRITE_PAGES) {
    return { reason: "board-larger-than-" + MAX_WRITE_PAGES + "-pages" };
  }
  if (pages.length === 1) {
    var single = await tenon.intents.send("filesystem.file.write.v1", {
      path: path,
      content: { kind: "inline", text: pages[0] }
    });
    return single.ok ? null : writeFailure(single);
  }
  var cursor = null;
  for (var i = 0; i < pages.length; i++) {
    var input = { path: path, content: { kind: "inline", text: pages[i] } };
    if (cursor) input.cursor = cursor;
    var last = i === pages.length - 1;
    if (!last) input.commit = false;
    var result = await tenon.intents.send("filesystem.file.write.v1", input);
    if (!result.ok) return writeFailure(result);
    if (last) return null;
    cursor = (result.value || {}).cursor;
    if (!cursor) return { reason: "staged-write-lost-its-cursor" };
  }
  return null;
}

function writeFailure(result) {
  var error = result.error || {};
  var reason = error.details && error.details.reason;
  return { reason: String(reason || error.code || "unknown") };
}

// Relocates one verbatim board line to the adjacent column, preserving every other byte:
// the moved line lands after the target column's last task line, or directly under its
// heading when it has none. The line moved is the id's FIRST occurrence — the same one
// findTask resolves and the pane rendered the button on — so a stale duplicate later in
// the file (the workflow doc's "stale copy reads as free work") is never the one that
// moves. Returns { text } or { reason }.
function relocateTaskLine(text, id, direction) {
  var lines = String(text).split("\n");
  var headings = [];
  var lastTaskLine = [];
  var taskLine = -1;
  var taskColumn = -1;
  for (var i = 0; i < lines.length; i++) {
    if (COLUMN_HEADING.test(lines[i])) {
      headings.push(i);
      lastTaskLine.push(-1);
      continue;
    }
    if (headings.length === 0) continue;
    var row = /^-\s+\[(T-\d+)\]\(([^)]+)\)/.exec(lines[i]);
    if (!row) continue;
    lastTaskLine[lastTaskLine.length - 1] = i;
    if (taskLine < 0 && row[1] === id) {
      taskLine = i;
      taskColumn = headings.length - 1;
    }
  }
  if (taskLine < 0) return { reason: "task-not-found" };
  var target = taskColumn + direction;
  if (target < 0 || target >= headings.length) {
    return { reason: "no-adjacent-column" };
  }
  var moved = lines[taskLine];
  var insertAfter = lastTaskLine[target] >= 0 ? lastTaskLine[target] : headings[target];
  lines.splice(taskLine, 1);
  if (insertAfter > taskLine) insertAfter -= 1;
  lines.splice(insertAfter + 1, 0, moved);
  return { text: lines.join("\n") };
}

// Bounds one pane's move queue (invariant 10): a click past the bound is refused with
// its reason named — four queued rewrites of a 113 KB board is already more than a
// human meant.
var MAX_QUEUED_MOVES = 4;

// Moves on one pane run strictly one after another: a second click computes against the
// board the first one committed instead of racing it read-for-write, so ▶▶ is two
// columns over, always, never a coin flip on whose write lands last.
function moveTask(st, id, direction) {
  if (st.queuedMoves >= MAX_QUEUED_MOVES) {
    st.writeError = "Move refused: too-many-queued-moves";
    render(st);
    return;
  }
  st.queuedMoves += 1;
  var run = function () { return performMove(st, id, direction); };
  var chained = (st.movesInFlight ? st.movesInFlight.then(run, run) : run())
    .finally(function () { st.queuedMoves -= 1; });
  st.movesInFlight = chained;
  return chained;
}

// A move is read → relocate → write, all against the file as it is now, not as this pane
// last rendered it: another agent's edit in between must survive the rewrite untouched.
// Any failure is total — the target never holds a partial move — so the honest ending is
// the same either way: name what happened and re-read the board the disk actually holds.
async function performMove(st, id, direction) {
  st.writeError = "";
  // Captured once: `workspace.changed` can rebind st.boardPath while this move is
  // paging the board (T-036 moves the pane between workspaces). The move belongs to
  // the board that rendered the click — read and written at the same path — never
  // workspace A's board renamed over workspace B's.
  var path = st.boardPath;
  var read = await readFile(path);
  if (panes[st.id] !== st) return;
  if (read.text === undefined) {
    st.writeError = "Move failed: " + (read.missing ? "board-missing" : read.reason);
    await refresh(st);
    return;
  }
  var moved = relocateTaskLine(read.text, id, direction);
  if (moved.text === undefined) {
    st.writeError = "Move failed: " + moved.reason;
    await refresh(st);
    return;
  }
  var failure = await writeFile(path, moved.text);
  if (panes[st.id] !== st) return;
  if (failure) st.writeError = "Board write failed: " + failure.reason;
  await refresh(st);
}

// --- Rendering ----------------------------------------------------------------------

function render(st) {
  if (panes[st.id] !== st) return;
  var children = [];
  if (st.writeError) {
    children.push({ type: "text", value: clip(st.writeError, MAX_LABEL), color: "red" });
  }
  if (st.error) {
    children.push({ type: "text", value: clip(st.error, MAX_LABEL), color: "red" });
  }
  if (st.columns.length > 0) {
    var columns = [];
    for (var i = 0; i < st.columns.length; i++) {
      columns.push(columnNode(st, st.columns[i], i));
    }
    // Fixed columns overflow the pane by construction, and the pane itself only scrolls
    // down — so the row of them says where its own overflow goes.
    children.push({
      type: "scroll",
      axis: "horizontal",
      children: [{ type: "hstack", spacing: 12, children: columns }]
    });
  }
  // Which board this pane is showing goes in the pane's own chrome, beside its name. A
  // body publishing this used to say it into a void — nothing drew a view's metadata once
  // it had a `body` — so this is the first time the path is actually visible.
  var specification = {
    title: "Kanban",
    header: {
      leading: [
        {
          type: "label",
          id: "board",
          text: st.boardPath,
          color: "muted",
          truncation: "head"
        }
      ]
    },
    body: { type: "vstack", spacing: 10, children: children }
  };
  // The sheet is part of this view's published state: set it to open, omit it to close.
  var modal = modalNode(st);
  if (modal) specification.modal = modal;
  tenon.views.set(VIEW, specification, st.id);
}

// A column is a `box`: it is the one node that claims the full width offered to it, so
// every column takes an equal share of the pane — including an empty one, which as a
// bare vstack would collapse to the width of its own heading. The trailing `spacer`
// makes the column fill the row's height, which is what pins its cards to the top; row
// children are centred against each other otherwise, and a short column would float in
// the middle of the board beside a tall one.
function columnNode(st, column, index) {
  var children = [{
    type: "hstack",
    spacing: 6,
    children: [
      { type: "text", value: clip(column.name, MAX_LABEL), weight: "semibold" },
      { type: "spacer" },
      { type: "badge", value: String(column.tasks.length), tint: "muted" }
    ]
  }];
  var shown = column.tasks.slice(0, MAX_ROWS_PER_COLUMN);
  for (var i = 0; i < shown.length; i++) {
    children.push(cardNode(st, shown[i], index));
  }
  if (column.tasks.length > shown.length) {
    children.push({
      type: "text",
      value: "… " + (column.tasks.length - shown.length) + " more",
      style: "caption",
      color: "muted"
    });
  }
  children.push({ type: "spacer" });
  return {
    type: "box",
    padding: 10,
    background: true,
    cornerRadius: 10,
    width: COLUMN_WIDTH,
    children: children
  };
}

// Id and badge share the top line and the title owns the one below it: side by side,
// the title is squeezed between them into a column of single words.
function cardNode(st, task, columnIndex) {
  var top = [
    { type: "text", value: task.id, style: "code" },
    { type: "spacer" }
  ];
  if (task.meta) {
    top.push({ type: "badge", value: clip(task.meta, MAX_CARD_META), tint: "amber" });
  }
  var header = [
    { type: "hstack", spacing: 6, children: top },
    { type: "text", value: clip(task.title, MAX_CARD_TITLE) }
  ];
  var controls = [];
  if (columnIndex > 0) {
    controls.push({ type: "button", label: "◀", action: "move-left:" + task.id });
  }
  if (columnIndex < st.columns.length - 1) {
    controls.push({ type: "button", label: "▶", action: "move-right:" + task.id });
  }
  // Packed, not spread: a column is 260 points wide, and a spacer between these pushes
  // the last button past the edge, where the label truncates to "Det…".
  controls.push({ type: "button", label: "Start", action: "start:" + task.id });
  controls.push({ type: "button", label: "More", action: "more:" + task.id });
  // The card is the same height whichever task is open: the detail goes to the sheet,
  // where it has the width of the window instead of a fifth of a pane.
  return {
    type: "card",
    children: header.concat([{ type: "hstack", spacing: 6, children: controls }])
  };
}

// --- The detail sheet ------------------------------------------------------------------

// The modal the host presents over the whole shell while a task is open, or null. It
// carries the task's own file — description, priority/effort, criteria — and, once an
// agent has been started for that task, what that agent is doing right now.
function modalNode(st) {
  if (!st.openTask) return null;
  var task = findTask(st, st.openTask);
  if (!task) return null;
  var children = [];
  var detail = st.detail;
  if (detail && detail.description) {
    children.push({ type: "text", value: detail.description, color: "muted" });
  }
  if (detail && (detail.priority || detail.effort)) {
    children.push({
      type: "text",
      value: "priority " + (detail.priority || "—") + "  ·  effort " + (detail.effort || "—"),
      style: "caption",
      color: "muted"
    });
  }
  if (detail) {
    for (var i = 0; i < detail.criteria.length; i++) {
      var criterion = detail.criteria[i];
      children.push({
        type: "hstack",
        spacing: 6,
        children: [
          { type: "image", systemName: criterion.done ? "checkmark.circle.fill" : "circle" },
          { type: "text", value: criterion.text }
        ]
      });
    }
  }
  appendRun(st, task, children);
  return {
    type: "modal",
    title: task.id + " · " + clip(task.title, MAX_CARD_TITLE),
    dismissAction: "close-detail",
    body: { type: "vstack", spacing: 8, children: children }
  };
}

// The run block: what the agent this task started is doing, or the button that starts one.
// Every claim here is the pane's own current output, read this tick — the supervision the
// board exists for is worth nothing if the sheet shows a transcript from a minute ago.
function appendRun(st, task, children) {
  children.push({ type: "divider" });
  var run = st.runs[task.id];
  if (!run) {
    children.push({
      type: "text",
      value: "No agent started for this task yet.",
      style: "caption",
      color: "muted"
    });
    children.push({
      type: "hstack",
      spacing: 6,
      children: [{ type: "button", label: "Start agent", action: "start:" + task.id }]
    });
    return;
  }
  children.push({
    type: "hstack",
    spacing: 6,
    children: [
      {
        type: "badge",
        value: run.exited ? "exited" : "running",
        tint: run.exited ? "muted" : "green"
      },
      { type: "text", value: "pane " + run.paneID.slice(0, 8), style: "code", color: "muted" }
    ]
  });
  if (run.error) {
    children.push({ type: "text", value: "Tracking stopped: " + run.error, color: "red" });
  }
  if (run.tail) {
    children.push({ type: "text", value: run.tail, style: "code", color: "muted" });
  }
  children.push({
    type: "hstack",
    spacing: 6,
    children: [
      { type: "button", label: "Focus pane", action: "focus:" + task.id },
      { type: "spacer" },
      { type: "button", label: "Start again", action: "start:" + task.id }
    ]
  });
}

// --- Watching -----------------------------------------------------------------------

function debouncedRefresh(st) {
  if (st.debounceHandle !== null) tenon.timers.cancel(st.debounceHandle);
  st.debounceHandle = tenon.timers.after(DEBOUNCE_MS, function () {
    st.debounceHandle = null;
    refresh(st);
  });
}

function watchBoard(st) {
  var directory = tenon.path.join(st.workspacePath, KANBAN_DIR);
  if (st.watchDir === directory && st.watch) return;
  if (st.watch) st.watch.cancel();
  st.watch = tenon.fs.watch(directory, { recursive: true }, function () {
    // Many agents write this directory in bursts; coalesce or a board edit becomes a
    // re-parse storm.
    debouncedRefresh(st);
  });
  st.watchDir = st.watch ? directory : "";
}

function releasePane(st) {
  if (st.watch) {
    st.watch.cancel();
    st.watch = null;
  }
  if (st.debounceHandle !== null) {
    tenon.timers.cancel(st.debounceHandle);
    st.debounceHandle = null;
  }
  stopTracking(st);
  st.watchDir = "";
}

// --- Following a started agent -----------------------------------------------------

// Polling lives with the open sheet, never with the run: an agent nobody is watching
// costs nothing, and a pane that closes takes its timer with it (invariant 10).
function startTracking(st) {
  stopTracking(st);
  st.trackHandle = tenon.timers.every(TRACK_INTERVAL_MS, function () {
    trackOnce(st);
  });
  trackOnce(st);
}

function stopTracking(st) {
  if (st.trackHandle === null || st.trackHandle === undefined) return;
  tenon.timers.cancel(st.trackHandle);
  st.trackHandle = null;
}

async function trackOnce(st) {
  var run = st.openTask ? st.runs[st.openTask] : null;
  if (!run || run.exited) {
    stopTracking(st);
    return;
  }
  var taskID = st.openTask;
  var result = await tenon.intents.send(
    "terminal.viewport.read.v1",
    {},
    { scope: { paneID: run.paneID } }
  );
  // The sheet may have closed, or moved to another task, while the read was in flight.
  if (panes[st.id] !== st || st.openTask !== taskID || st.runs[taskID] !== run) return;
  if (!result.ok) {
    // A pane the user closed answers `terminal-unavailable`: the run is over, and saying
    // so beats leaving a green "running" badge on a terminal that no longer exists.
    run.exited = true;
    run.error = String((result.error && result.error.code) || "unknown");
    stopTracking(st);
    render(st);
    return;
  }
  var value = result.value || {};
  run.tail = tailOf(value.text);
  run.exited = value.exited === true;
  if (run.exited) stopTracking(st);
  render(st);
}

// The last few non-empty rows, which is what a viewport of a TUI agent is mostly not:
// claude paints a full screen of blanks around what it is saying.
function tailOf(text) {
  var lines = String(text || "").split("\n");
  var kept = [];
  for (var i = lines.length - 1; i >= 0 && kept.length < MAX_TAIL_LINES; i--) {
    var line = lines[i].replace(/\s+$/, "");
    if (line.length === 0) continue;
    kept.unshift(clip(line, MAX_TAIL_LINE));
  }
  return kept.join("\n");
}

// --- Actions ------------------------------------------------------------------------

function shellQuote(text) {
  return "'" + String(text).replace(/'/g, "'\\''") + "'";
}

// Opens the agent's pane and, on success, records the run so the sheet can follow it.
// The sheet opens either way: a start that failed is exactly when a human wants to look.
async function startAgent(st, task) {
  var relative = tenon.path.join(KANBAN_DIR, task.path.replace(/^\.\//, ""));
  var prompt =
    "Do task " + task.id + " described in " + relative +
    ". Follow the workflow protocol in CLAUDE.md: claim it on the board before " +
    "touching a file, and release the claim when you finish.";
  var result = await tenon.intents.send("terminal.open.v1", {
    command: "claude " + shellQuote(prompt),
    workingDirectory: st.workspacePath
  });
  if (panes[st.id] !== st) return result;
  var paneID = result.ok ? (result.value || {}).paneID : null;
  if (paneID) {
    st.runs[task.id] = { paneID: String(paneID), exited: false, tail: "", error: "" };
  } else {
    st.writeError = "Start failed: " +
      String((result.error && result.error.code) || "no-pane-returned");
  }
  await openDetail(st, task.id);
  return result;
}

// Opening the sheet re-reads the task file through `refresh`, so the criteria shown are
// the ones on disk right now — another agent may have ticked one since the board loaded.
async function openDetail(st, id) {
  st.openTask = id;
  st.detail = null;
  await refresh(st);
  if (panes[st.id] !== st || st.openTask !== id) return;
  if (st.runs[id] && !st.runs[id].exited) startTracking(st);
}

tenon.views.onSelect(VIEW, async function (action, value, instanceID) {
  var st = panes[instanceID];
  if (!st || typeof action !== "string") return;
  if (action.indexOf("start:") === 0) {
    var task = findTask(st, action.slice("start:".length));
    if (task) await startAgent(st, task);
    return;
  }
  if (action.indexOf("more:") === 0) {
    await openDetail(st, action.slice("more:".length));
    return;
  }
  if (action === "close-detail") {
    stopTracking(st);
    st.openTask = null;
    st.detail = null;
    render(st);
    return;
  }
  if (action.indexOf("focus:") === 0) {
    var run = st.runs[action.slice("focus:".length)];
    if (run) {
      await tenon.intents.send(
        "workspace.pane.focus.v1",
        {},
        { scope: { paneID: run.paneID } }
      );
    }
    return;
  }
  if (action.indexOf("move-left:") === 0) {
    await moveTask(st, action.slice("move-left:".length), -1);
    return;
  }
  if (action.indexOf("move-right:") === 0) {
    await moveTask(st, action.slice("move-right:".length), 1);
  }
});

tenon.views.onOpen(VIEW, async function (instanceID) {
  var st = makePane(instanceID);
  panes[instanceID] = st;
  var owner = await owningWorkspace(instanceID);
  if (panes[instanceID] !== st) return;
  st.workspaceId = owner.id;
  st.workspacePath = owner.path;
  st.boardPath = tenon.path.join(owner.path, KANBAN_DIR, BOARD_FILE);
  watchBoard(st);
  await refresh(st);
});

tenon.views.onClose(VIEW, function (instanceID) {
  var st = panes[instanceID];
  if (!st) return;
  releasePane(st);
  delete panes[instanceID];
});

// A pane moved between workspaces follows its new owner, per T-036: the board belongs to
// the workspace that owns the pane, never to whichever workspace is selected.
tenon.events.on("workspace.changed", async function () {
  var list = paneList();
  for (var i = 0; i < list.length; i++) {
    var st = list[i];
    var owner = await owningWorkspace(st.id);
    if (panes[st.id] !== st) continue;
    if (owner.id === st.workspaceId) continue;
    st.workspaceId = owner.id;
    st.workspacePath = owner.path;
    st.boardPath = tenon.path.join(owner.path, KANBAN_DIR, BOARD_FILE);
    // The open task belonged to the board this pane just left, and so did any agent it
    // was following: both go with it rather than sitting over another workspace's board.
    stopTracking(st);
    st.openTask = null;
    st.detail = null;
    st.runs = {};
    watchBoard(st);
    await refresh(st);
  }
});

tenon.intents.handle("dev.tenon.kanban.open.v1", async function (_, call) {
  await call.send("workspace.content.open.v1", {
    content: { kind: "plugin", pluginID: "dev.tenon.kanban", viewID: VIEW }
  });
  return {};
});
