// Kanban — the .kanban/ board as a pane, and a button that hands a task to an agent.
//
// The board is already how agents in this repo tell each other what they are doing. This
// makes it an attention surface: which column is full, which task is claimed, and one
// click to put an agent on a task in a real PTY.
//
// Plugin-only on purpose. Nothing here reaches a host type: files arrive through the
// filesystem intent, the tree is a CONTRIBUTION, the watch is a RESOURCE this pane owns,
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
    error: "",
    selectedTask: null,
    detail: null,
    // Bumped on every refresh so a slow read that lands after a newer one is dropped
    // instead of overwriting it.
    generation: 0
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

function parseBoard(text) {
  var columns = [];
  var current = null;
  var lines = String(text).split("\n");
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    var heading = /^##\s+(.+?)\s*$/.exec(line);
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

async function readFile(path, call) {
  var input = { path: path };
  var result = call
    ? await call.send("filesystem.file.read.v1", input)
    : await tenon.intents.send("filesystem.file.read.v1", input);
  if (!result.ok) return null;
  var content = result.value && result.value.content;
  if (!content || content.kind !== "inline") return null;
  return content.text || "";
}

async function owningWorkspace(instanceID, call) {
  var result = call
    ? await call.send("workspace.state.v1", { limit: 256 })
    : await tenon.intents.send("workspace.state.v1", { limit: 256 });
  if (!result.ok) return { id: null, path: "" };
  var nodes = result.value.nodes || [];
  var workspacePaths = {};
  var tabWorkspace = {};
  var paneTab = null;
  for (var i = 0; i < nodes.length; i++) {
    var node = nodes[i];
    if (node.kind === "workspace") workspacePaths[node.id] = node.path || "";
    if (node.kind === "tab") tabWorkspace[node.id] = node.workspaceID;
    if (node.kind === "pane" && node.id === instanceID) paneTab = node.tabID;
  }
  var workspaceId = paneTab ? tabWorkspace[paneTab] : null;
  if (!workspaceId) return { id: null, path: "" };
  return { id: workspaceId, path: workspacePaths[workspaceId] || "" };
}

async function refresh(st, call) {
  if (!st.boardPath) return;
  st.generation += 1;
  var generation = st.generation;
  var text = await readFile(st.boardPath, call);
  // A read that resolves after a newer one, or after this pane closed, must not publish.
  if (panes[st.id] !== st || generation !== st.generation) return;

  if (text === null) {
    st.columns = [];
    st.error = "No board at " + st.boardPath;
  } else {
    st.columns = parseBoard(text);
    st.error = "";
  }

  if (st.selectedTask) {
    var still = findTask(st, st.selectedTask);
    if (!still) {
      st.selectedTask = null;
      st.detail = null;
    } else {
      var detailText = await readFile(
        tenon.path.join(st.workspacePath, KANBAN_DIR, still.path.replace(/^\.\//, "")),
        call
      );
      if (panes[st.id] !== st || generation !== st.generation) return;
      st.detail = detailText === null ? null : parseTask(detailText);
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

// --- Rendering ----------------------------------------------------------------------

var TASK_MENU = [{ id: "start", label: "Start an agent on this task" }];

function render(st) {
  if (panes[st.id] !== st) return;
  var rows = [];

  if (st.error) {
    rows.push({ id: "error", label: st.error, depth: 0, icon: "exclamationmark.triangle" });
  }

  for (var i = 0; i < st.columns.length; i++) {
    var column = st.columns[i];
    var shown = column.tasks.slice(0, MAX_ROWS_PER_COLUMN);
    rows.push({
      id: "column:" + column.name,
      label: column.name + "  (" + column.tasks.length + ")",
      depth: 0,
      icon: "square.stack"
    });
    for (var j = 0; j < shown.length; j++) {
      var task = shown[j];
      var label = task.id + "  " + task.title;
      if (task.meta) label += "  ·  " + task.meta;
      rows.push({
        id: "task:" + task.id,
        label: clip(label, MAX_LABEL),
        depth: 1,
        icon: "circle",
        selected: st.selectedTask === task.id,
        menu: TASK_MENU
      });
      if (st.selectedTask === task.id) appendDetail(st, rows);
    }
    if (column.tasks.length > shown.length) {
      rows.push({
        id: "more:" + column.name,
        label: "… " + (column.tasks.length - shown.length) + " more",
        depth: 1,
        icon: "ellipsis"
      });
    }
  }

  tenon.views.set(VIEW, {
    title: "Kanban",
    subtitle: st.boardPath,
    items: rows
  }, st.id);
}

function appendDetail(st, rows) {
  var detail = st.detail;
  if (!detail) return;
  if (detail.description) {
    rows.push({
      id: "detail:description",
      label: detail.description,
      depth: 2,
      icon: "text.alignleft"
    });
  }
  if (detail.priority || detail.effort) {
    rows.push({
      id: "detail:fields",
      label: "priority " + (detail.priority || "—") + "  ·  effort " + (detail.effort || "—"),
      depth: 2,
      icon: "tag"
    });
  }
  for (var i = 0; i < detail.criteria.length; i++) {
    var criterion = detail.criteria[i];
    rows.push({
      id: "detail:criterion:" + i,
      label: criterion.text,
      depth: 2,
      icon: criterion.done ? "checkmark.circle.fill" : "circle"
    });
  }
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
  st.watchDir = "";
}

// --- Actions ------------------------------------------------------------------------

function shellQuote(text) {
  return "'" + String(text).replace(/'/g, "'\\''") + "'";
}

async function startAgent(st, task) {
  var relative = tenon.path.join(KANBAN_DIR, task.path.replace(/^\.\//, ""));
  var prompt =
    "Do task " + task.id + " described in " + relative +
    ". Follow the workflow protocol in CLAUDE.md: claim it on the board before " +
    "touching a file, and release the claim when you finish.";
  return await tenon.intents.send("terminal.open.v1", {
    command: "claude " + shellQuote(prompt),
    workingDirectory: st.workspacePath
  });
}

tenon.views.onSelect(VIEW, async function (action, value, instanceID) {
  var st = panes[instanceID];
  if (!st) return;
  if (action === "start" && value && value.indexOf("task:") === 0) {
    var task = findTask(st, value.slice("task:".length));
    if (task) await startAgent(st, task);
    return;
  }
  if (action.indexOf("task:") === 0) {
    var id = action.slice("task:".length);
    st.selectedTask = st.selectedTask === id ? null : id;
    st.detail = null;
    await refresh(st);
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
    st.selectedTask = null;
    st.detail = null;
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
