// claude-sessions — lists the Claude Code conversations recorded for the directory
// you are working in, and resumes one in the terminal.
//
// Claude Code writes one JSONL transcript per session to
// `<claudeHome>/projects/<slug>/<sessionID>.jsonl`, where the slug is the project
// path with every non-alphanumeric character replaced by "-". This plugin reads
// those transcripts through canonical intents plus settings and view contributions.
//
// Instanced (T-012 model): every pane owns an independent list bound to the project of
// the workspace that OWNS the pane, resolved through `workspace.state.v1`, so the global
// selection can change without touching an inactive pane's list.
//
// Scanning is two passes, so only the sessions actually shown are read:
//   1. `stat` over the directory  → id, last activity, size — cheap, sorts the list;
//   2. `awk` over just the newest N → title, prompt/reply counts, git branch.

var VIEW = "sessions";

// One pass per transcript, matching only the first 300 characters of each line: for a
// user/assistant/ai-title record the `type`/`role` field lives there, while the huge
// records (tool results, attachments, base64 images) are skipped without being scanned.
// A "prompt" is a user record that is not a tool result; `t` keeps the LAST ai-title,
// which is the session's current name.
var AWK =
  'FNR == 1 { if (f != "") emit(); f = FILENAME; p = 0; r = 0; t = ""; first = "" }\n' +
  '{ h = substr($0, 1, 300) }\n' +
  'h ~ /"role":"user"/ && h !~ /"tool_use_id"/ { p++; if (first == "" && length($0) <= 20000) first = $0 }\n' +
  'h ~ /"role":"assistant"/ { r++ }\n' +
  'h ~ /[,{]"type":"ai-title"[,}]/ { t = $0 }\n' +
  'END { if (f != "") emit() }\n' +
  'function emit() { printf "%s\\t%d\\t%d\\t%s\\t%s\\n", f, p, r, t, first }\n';

// instanceID (pane UUID) → this pane's list state.
var panes = {};

function makePane(instanceID) {
  return {
    id: instanceID,
    workspaceId: null,
    workspacePath: "",
    project: "",
    sessions: [],
    notice: "Loading…",
    // Guards against a slow scan clobbering a newer one (settings can change twice in a row).
    generation: 0
  };
}

function paneList() {
  var ids = Object.keys(panes);
  var list = [];
  for (var i = 0; i < ids.length; i++) list.push(panes[ids[i]]);
  return list;
}

// --- resolving what to scan ------------------------------------------------

function setting(key) {
  return (tenon.settings.get(key) || "").trim();
}

// The directory whose sessions a pane shows: an explicit setting wins, otherwise the
// workspace that owns the pane.
function resolveProject(st) {
  return setting("projectPath") || st.workspacePath;
}

// The workspace that owns a pane: pane → tab → workspace, from the public state snapshot.
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

function sessionsDir(path) {
  var home = setting("claudeHome") || "~/.claude";
  return home.replace(/\/+$/, "") + "/projects/" + path.replace(/[^a-zA-Z0-9]/g, "-");
}

// Quote a path for `sh`, leaving a leading "~" to the shell's $HOME.
function shellPath(path) {
  var quoted = function (s) { return "'" + s.split("'").join("'\\''") + "'"; };
  if (path === "~") return '"$HOME"';
  if (path.indexOf("~/") === 0) return '"$HOME"/' + quoted(path.slice(2));
  return quoted(path);
}

function inlineText(value) {
  return value && value.kind === "inline" ? value.text || "" : "";
}

async function exec(command, argumentsValue, workingDirectory, call) {
  var input = {
    command: command,
    arguments: argumentsValue,
    workingDirectory: workingDirectory || "/"
  };
  var result = call
    ? await call.send("process.exec.v1", input)
    : await tenon.intents.send("process.exec.v1", input);
  if (!result.ok) {
    return {
      ok: false,
      status: -1,
      stdout: "",
      stderr: "",
      error: result.error.code
    };
  }
  return {
    ok: true,
    status: result.value.exitCode,
    stdout: inlineText(result.value.standardOutput),
    stderr: inlineText(result.value.standardError),
    error: null
  };
}

// --- scanning --------------------------------------------------------------

async function scan(st, call) {
  st.project = resolveProject(st);
  var gen = ++st.generation;
  if (!st.project) {
    st.sessions = [];
    st.notice = "Open a workspace to see its Claude Code sessions.";
    render(st);
    return;
  }
  st.notice = "Scanning…";
  render(st);

  var dir = sessionsDir(st.project);
  var result = await exec(
    "/bin/sh",
    [
      "-c",
      "cd " + shellPath(dir)
        + ' 2>/dev/null || exit 3\nstat -f "%m %z %N" "$PWD"/*.jsonl 2>/dev/null\n'
    ],
    st.project,
    call
  );
  if (gen !== st.generation || panes[st.id] !== st) return;
  if (!result.ok || result.status !== 0) {
    st.sessions = [];
    st.notice = result.error || result.stderr || "Could not read the sessions directory.";
    render(st);
    return;
  }
  var found = parseStat(result.stdout || "");
  found.sort(function (a, b) { return b.mtime - a.mtime; });
  st.sessions = found.slice(0, parseInt(setting("limit") || "25", 10) || 25);
  st.notice = null;
  render(st);
  if (st.sessions.length) await enrich(st, gen, call);
}

function parseStat(out) {
  var lines = out.split("\n");
  var found = [];
  for (var i = 0; i < lines.length; i++) {
    var m = lines[i].match(/^(\d+) (\d+) (.*\.jsonl)$/);
    if (!m) continue;
    var path = m[3];
    var name = path.slice(path.lastIndexOf("/") + 1);
    found.push({
      id: name.slice(0, name.length - ".jsonl".length),
      path: path,
      mtime: parseInt(m[1], 10),
      size: parseInt(m[2], 10),
      prompts: 0,
      replies: 0,
      branch: "",
      title: "",
    });
  }
  return found;
}

async function enrich(st, gen, call) {
  // LC_ALL=C is load-bearing: a transcript carries pasted images and binary tool output,
  // and awk in a UTF-8 locale aborts the whole run on the first byte it cannot decode
  // ("towc: multibyte conversion failure") — leaving every session unnamed. Byte mode
  // reads them as bytes, and is ~2x faster besides.
  var args = ["LC_ALL=C", "/usr/bin/awk", AWK];
  for (var i = 0; i < st.sessions.length; i++) args.push(st.sessions[i].path);
  var result = await exec("/usr/bin/env", args, st.project, call);
  if (gen !== st.generation || panes[st.id] !== st) return;
  if (!result.ok || result.status !== 0) {
    tenon.log(
      "claude-sessions: could not read session details: "
        + (result.error || result.stderr || "awk exited " + result.status)
    );
    return;
  }
  var byPath = {};
  for (var j = 0; j < st.sessions.length; j++) byPath[st.sessions[j].path] = st.sessions[j];
  var lines = (result.stdout || "").split("\n");
  for (var k = 0; k < lines.length; k++) {
    var fields = lines[k].split("\t");
    var session = byPath[fields[0]];
    if (!session || fields.length < 5) continue;
    session.prompts = parseInt(fields[1], 10) || 0;
    session.replies = parseInt(fields[2], 10) || 0;
    var titleRecord = parseJSON(fields[3]);
    var firstPrompt = parseJSON(fields[4]);
    if (firstPrompt) session.branch = firstPrompt.gitBranch || "";
    session.title = (titleRecord && titleRecord.aiTitle) || promptTitle(firstPrompt) || "";
  }
  render(st);
}

function parseJSON(text) {
  if (!text) return null;
  try { return JSON.parse(text); } catch (e) { return null; }
}

// A session with no ai-title names itself after its opening prompt. Slash commands
// arrive wrapped in tags — show the command and its arguments, not the markup.
function promptTitle(record) {
  var content = record && record.message ? record.message.content : null;
  if (typeof content !== "string") return "";
  var name = content.match(/<command-name>([\s\S]*?)<\/command-name>/);
  var args = content.match(/<command-args>([\s\S]*?)<\/command-args>/);
  if (name) content = name[1] + (args && args[1] ? " " + args[1] : "");
  content = content.replace(/<[^>]*>/g, " ").replace(/\s+/g, " ").trim();
  return content.length > 90 ? content.slice(0, 90) + "…" : content;
}

// --- formatting ------------------------------------------------------------

function ago(seconds) {
  var delta = Math.max(0, Math.floor(Date.now() / 1000) - seconds);
  if (delta < 60) return "just now";
  if (delta < 3600) return Math.floor(delta / 60) + "m ago";
  if (delta < 86400) return Math.floor(delta / 3600) + "h ago";
  if (delta < 2592000) return Math.floor(delta / 86400) + "d ago";
  return Math.floor(delta / 2592000) + "mo ago";
}

function size(bytes) {
  if (bytes < 1024) return bytes + " B";
  if (bytes < 1048576) return Math.round(bytes / 1024) + " KB";
  return (bytes / 1048576).toFixed(1) + " MB";
}

function plural(count, one, many) {
  return count + " " + (count === 1 ? one : many);
}

// --- rendering -------------------------------------------------------------

// One session = two quiet lines inside the shared list card: what it was about, then the
// facts about it. Everything that was a badge before is one muted line, so twenty sessions
// read as a list instead of twenty competing boxes.
function sessionRow(session) {
  var facts = [session.id.slice(0, 8)];
  if (session.prompts) facts.push(plural(session.prompts, "prompt", "prompts"));
  if (session.replies) facts.push(plural(session.replies, "reply", "replies"));
  facts.push(size(session.size));

  var meta = [];
  if (session.branch) meta.push({ type: "badge", value: session.branch, tint: "green" });
  meta.push({ type: "text", value: facts.join(" · "), style: "caption", color: "muted" });
  meta.push({ type: "spacer" });
  meta.push({ type: "button", label: "Resume", action: "resume:" + session.id, style: "plain" });

  return {
    type: "vstack",
    spacing: 4,
    children: [
      {
        type: "hstack",
        children: [
          { type: "text", value: session.title || session.id.slice(0, 8), weight: "semibold" },
          { type: "spacer" },
          { type: "text", value: ago(session.mtime), style: "caption", color: "muted" },
        ],
      },
      { type: "hstack", spacing: 8, children: meta },
    ],
  };
}

function render(st) {
  if (panes[st.id] !== st) return;
  var children = [
    {
      type: "hstack",
      children: [
        { type: "text", value: "Claude Code sessions", style: "title", weight: "semibold" },
        { type: "spacer" },
        { type: "button", label: "Refresh", action: "refresh", style: "plain" },
        { type: "button", label: "New session", action: "new", style: "primary" },
      ],
    },
    { type: "text", value: st.project || "no project directory", style: "caption", color: "muted" },
  ];

  if (st.notice) {
    children.push({ type: "card", children: [{ type: "text", value: st.notice, color: "muted" }] });
  } else if (!st.sessions.length) {
    children.push({
      type: "card",
      children: [
        { type: "text", value: "No Claude Code sessions here yet", weight: "semibold" },
        { type: "text", value: "Run `claude` in this directory and it will show up.", style: "caption", color: "muted" },
      ],
    });
  } else {
    // One card holding the whole list, hairlines between rows — a list, not a stack of boxes.
    var rows = [];
    for (var i = 0; i < st.sessions.length; i++) {
      if (i > 0) rows.push({ type: "divider" });
      rows.push(sessionRow(st.sessions[i]));
    }
    children.push({ type: "card", children: rows });
  }

  tenon.views.set(VIEW, {
    title: "Claude Sessions",
    body: { type: "vstack", spacing: 10, children: children }
  }, st.id);
}

// --- wiring ----------------------------------------------------------------

tenon.views.register(VIEW, { title: "Claude Sessions", instanced: true });

tenon.views.onOpen(VIEW, async function (instanceID) {
  var st = makePane(instanceID);
  panes[instanceID] = st;
  var owner = await owningWorkspace(instanceID);
  if (panes[instanceID] !== st) return;
  st.workspaceId = owner.id;
  st.workspacePath = owner.path;
  await scan(st);
});

tenon.views.onClose(VIEW, function (instanceID) {
  delete panes[instanceID];
});

tenon.views.onSelect(VIEW, async function (action, value, instanceID) {
  var st = panes[instanceID];
  if (!st) return;
  if (action === "refresh") {
    await scan(st);
  } else if (action === "new") {
    await tenon.intents.send("terminal.open.v1", { command: "claude" });
  } else if (action.indexOf("resume:") === 0) {
    // Each session gets a pane of its own. `terminal.run.v1` would reuse whichever
    // terminal is in this tab, so resuming would take over a shell the user is already
    // working in — and two resumed sessions would fight over one pane.
    await tenon.intents.send("terminal.open.v1", {
      command: "claude --resume " + action.slice("resume:".length)
    });
  }
});

tenon.intents.handle("dev.tenon.claude-sessions.open.v1", async function (_, call) {
  var result = await call.send("workspace.content.open.v1", {
    content: {
      kind: "plugin",
      pluginID: "dev.tenon.claude-sessions",
      viewID: VIEW
    }
  });
  if (!result.ok) throw new Error(result.error.code);
  return {};
});

tenon.intents.handle("dev.tenon.claude-sessions.refresh.v1", async function (_, call) {
  var list = paneList();
  for (var i = 0; i < list.length; i++) await scan(list[i], call);
  return {};
});

tenon.events.on("settings.changed", function () {
  var list = paneList();
  for (var i = 0; i < list.length; i++) scan(list[i]);
});

// A pane can move between workspaces; its instance keeps its list but re-resolves the
// workspace that owns it, and rescans only when that project really changed —
// workspace.changed fires on every tab and split.
tenon.events.on("workspace.changed", async function () {
  var list = paneList();
  for (var i = 0; i < list.length; i++) {
    var st = list[i];
    var owner = await owningWorkspace(st.id);
    if (!owner.id || panes[st.id] !== st) continue;
    if (owner.id === st.workspaceId && owner.path === st.workspacePath) continue;
    st.workspaceId = owner.id;
    st.workspacePath = owner.path;
    await scan(st);
  }
});
