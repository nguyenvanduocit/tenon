// claude-sessions — lists Claude Code and Codex conversations recorded for the
// directory you are working in, and resumes one in the terminal.
//
// Claude Code writes one JSONL transcript per session to
// `<claudeHome>/projects/<slug>/<sessionID>.jsonl`, where the slug is the project
// path with every non-alphanumeric character replaced by "-". This plugin reads
// those transcripts through canonical intents plus settings and view contributions.
//
// Instanced (T-012 model): every pane owns an independent list bound to the project of
// the workspace that OWNS the pane, resolved through `workspace.pane.owner.v1`, so the global
// selection can change without touching an inactive pane's list.
//
// Claude scanning is two passes, so only the sessions actually shown are read:
//   1. `filesystem.directory.list.v2` with metadata → id, last activity, size, which is
//      what sorts the list;
//   2. `awk` over just the newest N → title, prompt/reply counts, git branch.
// Codex maintains the same display metadata in its bounded SQLite thread index, so it
// does not need to replay transcripts.

var VIEW = "sessions";

// The two notices that mean "a scan is in flight". They are named because the pane's chrome
// header reads them back as a spinner, and a literal spelled in three places drifts.
var LOADING = "Loading…";
var SCANNING = "Scanning…";

// process.exec.v1 has a finite 48 KB inline body. Extract only bounded JSON-string
// fragments instead of returning whole prompt records; the old whole-record output could
// exceed that limit and leave every row permanently named after its UUID.
var AWK =
  'FNR == 1 { if (f != "") emit(); f = FILENAME; p = 0; r = 0; t = ""; first = ""; branch = "" }\n' +
  '{ h = substr($0, 1, 1000) }\n' +
  'h ~ /"role":"user"/ && h !~ /"tool_use_id"/ { p++; if (first == "") first = jsonString($0, "content", 240); if (branch == "") branch = jsonString($0, "gitBranch", 100) }\n' +
  'h ~ /"role":"assistant"/ { r++ }\n' +
  'h ~ /[,{]"type":"ai-title"[,}]/ { t = jsonString($0, "aiTitle", 240) }\n' +
  'END { if (f != "") emit() }\n' +
  'function jsonString(line, key, maximum, marker, start, i, ch, escaped, out) { marker = "\\\"" key "\\\":\\\""; start = index(line, marker); if (!start) return ""; start += length(marker); escaped = 0; out = ""; for (i = start; i <= length(line) && length(out) < maximum; i++) { ch = substr(line, i, 1); if (ch == "\\\"" && !escaped) break; out = out ch; if (ch == "\\\\" && !escaped) escaped = 1; else escaped = 0 } if (escaped) out = substr(out, 1, length(out) - 1); return out }\n' +
  'function emit() { printf "%s\\t%d\\t%d\\t%s\\t%s\\t%s\\n", f, p, r, t, first, branch }\n';

// instanceID (pane UUID) → this pane's list state.
var panes = {};

function makePane(instanceID) {
  return {
    id: instanceID,
    workspaceId: null,
    workspacePath: "",
    project: "",
    sessions: [],
    notice: LOADING,
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

// The workspace that owns a pane, resolved by the host.
async function owningWorkspace(instanceID, call = tenon.intents) {
  var result = await call.send("workspace.pane.owner.v1", { paneID: instanceID });
  if (!result.ok) return { id: null, path: "" };
  return { id: result.value.workspaceID, path: result.value.workspacePath };
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

async function exec(command, argumentsValue, workingDirectory, call = tenon.intents) {
  var input = {
    command: command,
    arguments: argumentsValue,
    workingDirectory: workingDirectory || "/"
  };
  var result = await call.send("process.exec.v1", input);
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

async function scan(st, call = tenon.intents) {
  st.project = resolveProject(st);
  var gen = ++st.generation;
  if (!st.project) {
    st.sessions = [];
    st.notice = "Open a workspace to see its agent sessions.";
    render(st);
    return;
  }
  st.notice = SCANNING;
  st.scanError = null;
  render(st);

  var limit = sessionLimit();
  var claude = await scanClaude(st, gen, limit, call);
  if (gen !== st.generation || panes[st.id] !== st) return;
  var codex = await scanCodex(st, gen, limit, call);
  if (gen !== st.generation || panes[st.id] !== st) return;

  st.sessions = claude.concat(codex);
  st.sessions.sort(function (a, b) { return b.mtime - a.mtime; });
  st.sessions = st.sessions.slice(0, limit);
  // A listing that failed must not read as "this project has no sessions".
  st.notice = st.scanError;
  render(st);
}

function sessionLimit() {
  var value = parseInt(setting("limit") || "25", 10) || 25;
  return Math.max(10, Math.min(100, value));
}

async function scanClaude(st, gen, limit, call = tenon.intents) {
  var found = await listClaudeTranscripts(st, gen, call);
  if (!found || gen !== st.generation || panes[st.id] !== st) return [];
  found.sort(function (a, b) { return b.mtime - a.mtime; });
  found = found.slice(0, limit);
  if (found.length) await enrichClaude(st, gen, found, call);
  return found;
}

// Bounds on one listing (invariant 10). `~/.claude/projects/<slug>` grows without limit
// in normal use and this scan reruns on every pane open, settings change, workspace
// change and Refresh — with metadata on, each page also costs one stat per entry. At 256
// entries a page, MAX_PAGES stops the walk at 8192 transcripts, far past any real project,
// so a directory that has run away cannot hold a cursor loop open indefinitely. The pane
// shows the newest sessions it did reach rather than nothing.
var MAX_LISTING_PAGES = 32;

// One paged listing of the transcript directory. Child paths are built from the
// reply's own `path` — the directory the host actually opened — so a "~"-rooted
// Claude home reaches awk already expanded, which no argv would have done.
// Returns null when the pane moved on underneath the scan.
async function listClaudeTranscripts(st, gen, call = tenon.intents) {
  for (var attempt = 0; attempt < 2; attempt++) {
    var found = [];
    var directory = "";
    var cursor = null;
    var stale = false;
    for (var page = 0; page < MAX_LISTING_PAGES; page++) {
      var input = {
        path: sessionsDir(st.project),
        limit: 256,
        includeMetadata: true
      };
      if (cursor) input.cursor = cursor;
      var result = await call.send("filesystem.directory.list.v2", input);
      if (gen !== st.generation || panes[st.id] !== st) return null;
      if (!result.ok) {
        // No transcript directory yet is the ordinary state of a fresh project.
        if (result.error.code === "dev.tenon.core.path-not-found") return [];
        var reason = result.error.details && result.error.details.reason;
        // A live session writing into the directory moves its identity and
        // retires the cursor. One restart, then report it like any other failure.
        if (reason === "stale-cursor" && attempt === 0) {
          stale = true;
          break;
        }
        var failure = reason || result.error.code;
        tenon.log("agent-sessions: could not read Claude sessions: " + failure);
        st.scanError = "Could not read Claude sessions: " + failure;
        return [];
      }
      if (!directory) directory = result.value.path;
      var entries = result.value.entries || [];
      for (var i = 0; i < entries.length; i++) {
        var name = entries[i].name;
        if (entries[i].isDirectory) continue;
        if (name.length <= 6 || name.slice(-6) !== ".jsonl") continue;
        found.push({
          provider: "claude",
          id: name.slice(0, name.length - 6),
          path: directory + "/" + name,
          mtime: entries[i].modifiedAt
            ? Math.floor(Date.parse(entries[i].modifiedAt) / 1000)
            : 0,
          size: entries[i].sizeBytes || 0,
          prompts: 0,
          replies: 0,
          tokens: 0,
          branch: "",
          title: "",
        });
      }
      cursor = result.value.nextCursor;
      if (!cursor) break;
    }
    if (!stale) return found;
  }
  return [];
}

async function enrichClaude(st, gen, sessions, call = tenon.intents) {
  // LC_ALL=C is load-bearing: a transcript carries pasted images and binary tool output,
  // and awk in a UTF-8 locale aborts the whole run on the first byte it cannot decode
  // ("towc: multibyte conversion failure"). Chunks preserve the finite intent body even
  // when the user raises the visible-session limit to 100.
  var byPath = {};
  for (var i = 0; i < sessions.length; i++) byPath[sessions[i].path] = sessions[i];
  for (var offset = 0; offset < sessions.length; offset += 25) {
    var args = ["LC_ALL=C", "/usr/bin/awk", AWK];
    var end = Math.min(sessions.length, offset + 25);
    for (var j = offset; j < end; j++) args.push(sessions[j].path);
    var result = await exec("/usr/bin/env", args, st.project, call);
    if (gen !== st.generation || panes[st.id] !== st) return;
    if (!result.ok || result.status !== 0) {
      tenon.log(
        "agent-sessions: could not read Claude session details: "
          + (result.error || result.stderr || "awk exited " + result.status)
      );
      continue;
    }
    applyClaudeDetails(byPath, result.stdout || "");
  }
}

function applyClaudeDetails(byPath, output) {
  var lines = output.split("\n");
  for (var i = 0; i < lines.length; i++) {
    var fields = lines[i].split("\t");
    var session = byPath[fields[0]];
    if (!session || fields.length < 6) continue;
    session.prompts = parseInt(fields[1], 10) || 0;
    session.replies = parseInt(fields[2], 10) || 0;
    session.title = cleanTitle(decodeJSONFragment(fields[3]))
      || cleanTitle(decodeJSONFragment(fields[4]));
    session.branch = decodeJSONFragment(fields[5]);
  }
}

function decodeJSONFragment(text) {
  if (!text) return "";
  var candidate = text;
  while (candidate.length) {
    try { return JSON.parse('"' + candidate + '"'); } catch (e) { candidate = candidate.slice(0, -1); }
  }
  return "";
}

// A session with no generated title names itself after its opening prompt. Slash commands
// arrive wrapped in tags — show the command and its arguments, not the markup.
function cleanTitle(content) {
  if (typeof content !== "string") return "";
  var name = content.match(/<command-name>([\s\S]*?)<\/command-name>/);
  var args = content.match(/<command-args>([\s\S]*?)<\/command-args>/);
  if (name) content = name[1] + (args && args[1] ? " " + args[1] : "");
  content = content.replace(/<[^>]*>/g, " ").replace(/\s+/g, " ").trim();
  return content.length > 90 ? content.slice(0, 90) + "…" : content;
}

function codexDatabase() {
  var home = setting("codexHome") || "~/.codex";
  return home.replace(/\/+$/, "") + "/state_5.sqlite";
}

function sqlString(value) {
  return "'" + String(value || "").replace(/\u0000/g, "").split("'").join("''") + "'";
}

async function scanCodex(st, gen, limit, call = tenon.intents) {
  var query =
    "SELECT id, "
      + "CASE WHEN recency_at > 0 THEN recency_at ELSE updated_at END AS mtime, "
      + "substr(COALESCE(NULLIF(trim(name), ''), NULLIF(trim(title), ''), "
      + "NULLIF(trim(first_user_message), ''), NULLIF(trim(preview), ''), ''), 1, 160) AS title, "
      + "tokens_used AS tokens, substr(COALESCE(git_branch, ''), 1, 80) AS branch "
      + "FROM threads WHERE archived = 0 AND source = 'cli' AND cwd = "
      + sqlString(st.project)
      + " ORDER BY mtime DESC, id DESC LIMIT " + limit;
  var result = await runCodexQuery(st, query, call);
  if (gen !== st.generation || panes[st.id] !== st) return [];
  if (!result.ok || result.status !== 0) {
    // Older Codex indexes predate the richer preview columns but still carry titles.
    var fallback =
      "SELECT id, updated_at AS mtime, substr(COALESCE(title, ''), 1, 160) AS title, "
        + "tokens_used AS tokens, substr(COALESCE(git_branch, ''), 1, 80) AS branch "
        + "FROM threads WHERE archived = 0 AND source = 'cli' AND cwd = "
        + sqlString(st.project)
        + " ORDER BY updated_at DESC, id DESC LIMIT " + limit;
    result = await runCodexQuery(st, fallback, call);
  }
  if (gen !== st.generation || panes[st.id] !== st) return [];
  if (!result.ok || result.status !== 0) return [];

  var rows;
  try { rows = JSON.parse(result.stdout || "[]"); } catch (e) { return []; }
  if (!Array.isArray(rows)) return [];
  var sessions = [];
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i] || {};
    if (!row.id) continue;
    sessions.push({
      provider: "codex",
      id: String(row.id),
      path: "",
      mtime: parseInt(row.mtime, 10) || 0,
      size: 0,
      prompts: 0,
      replies: 0,
      tokens: parseInt(row.tokens, 10) || 0,
      branch: String(row.branch || ""),
      title: cleanTitle(String(row.title || "")),
    });
  }
  return sessions;
}

function runCodexQuery(st, query, call = tenon.intents) {
  var script = "exec /usr/bin/sqlite3 -readonly -json " + shellPath(codexDatabase()) + " \"$1\"";
  return exec(
    "/bin/sh",
    ["-c", script, "tenon-codex-scan", query],
    st.project,
    call
  );
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

function compactCount(count) {
  if (count < 1000) return String(count);
  if (count < 1000000) return (count / 1000).toFixed(count < 10000 ? 1 : 0) + "K";
  return (count / 1000000).toFixed(count < 10000000 ? 1 : 0) + "M";
}

function sessionTitle(session) {
  if (session.title) return session.title;
  return session.provider === "codex" ? "Untitled Codex session" : "Untitled Claude session";
}

function shellArgument(value) {
  return "'" + String(value).split("'").join("'\\''") + "'";
}

// --- rendering -------------------------------------------------------------

// One session = two quiet lines inside the shared list card: what it was about, then the
// facts about it. Everything that was a badge before is one muted line, so twenty sessions
// read as a list instead of twenty competing boxes.
function sessionRow(session) {
  var facts = [];
  if (session.prompts) facts.push(plural(session.prompts, "prompt", "prompts"));
  if (session.replies) facts.push(plural(session.replies, "reply", "replies"));
  if (session.tokens) facts.push(compactCount(session.tokens) + " tokens");
  if (session.size) facts.push(size(session.size));

  var meta = [
    {
      type: "badge",
      value: session.provider === "codex" ? "Codex" : "Claude",
      tint: session.provider === "codex" ? "green" : "amber"
    }
  ];
  if (session.branch) meta.push({ type: "badge", value: session.branch, tint: "green" });
  if (facts.length) {
    meta.push({ type: "text", value: facts.join(" · "), style: "caption", color: "muted" });
  }
  meta.push({ type: "spacer" });
  meta.push({
    type: "button",
    label: "Resume",
    action: "resume:" + session.provider + ":" + session.id,
    style: "plain"
  });

  return {
    type: "vstack",
    spacing: 4,
    children: [
      {
        type: "hstack",
        children: [
          { type: "text", value: sessionTitle(session), weight: "semibold" },
          { type: "spacer" },
          { type: "text", value: ago(session.mtime), style: "caption", color: "muted" },
        ],
      },
      { type: "hstack", spacing: 8, children: meta },
    ],
  };
}

// A scan in flight is the pane's own state, which is why it reads as a spinner in the strip
// rather than as a card that hides the list you were part-way through.
function isScanning(st) {
  return st.notice === LOADING || st.notice === SCANNING;
}

// What a supervisor scans on this pane: whose project it is, how much agent history sits
// here and from which tool, and whether that answer is still being worked out. The two
// pane-wide verbs sit at the trailing edge. All of it left the body when it arrived here —
// the title row was already the pane's own name said twice.
//
// A count badge appears only when it counts something: a project with no Codex history says
// nothing about Codex rather than drawing a "0". Each badge carries its word as well as its
// number, because folded into the `…` menu a badge becomes one line of its own text.
function headerNode(st) {
  var leading = [];
  if (st.project) {
    leading.push({
      type: "label",
      id: "project",
      text: st.project,
      color: "muted",
      truncation: "head"
    });
  }
  var claude = 0;
  var codex = 0;
  for (var i = 0; i < st.sessions.length; i++) {
    if (st.sessions[i].provider === "codex") codex++;
    else claude++;
  }
  if (claude) leading.push({ type: "badge", id: "claude", text: claude + " Claude", tint: "amber" });
  if (codex) leading.push({ type: "badge", id: "codex", text: codex + " Codex", tint: "green" });

  var trailing = [];
  if (isScanning(st)) trailing.push({ type: "spinner", id: "scanning" });
  // Two ways to start a session is a menu of named lines, not two glyphs nobody can tell
  // apart: there is no Claude symbol and no Codex symbol to draw.
  trailing.push({
    type: "menu",
    id: "new",
    systemName: "plus",
    tooltip: "Start a session",
    entries: [
      { value: "new:claude", label: "New Claude session" },
      { value: "new:codex", label: "New Codex session" }
    ]
  });
  trailing.push({
    type: "iconButton",
    id: "refresh",
    systemName: "arrow.clockwise",
    tooltip: "Refresh"
  });
  return { leading: leading, trailing: trailing };
}

function render(st) {
  if (panes[st.id] !== st) return;
  var children = [];

  if (st.sessions.length) {
    // One card holding the whole list, hairlines between rows — a list, not a stack of boxes.
    var rows = [];
    for (var i = 0; i < st.sessions.length; i++) {
      if (i > 0) rows.push({ type: "divider" });
      rows.push(sessionRow(st.sessions[i]));
    }
    children.push({ type: "card", children: rows });
  } else if (!isScanning(st)) {
    // Only a settled pane has news. Mid-scan the strip's spinner is the whole answer, so an
    // empty pane no longer claims there is nothing here before it has looked.
    children.push(st.notice
      ? { type: "card", children: [{ type: "text", value: st.notice, color: "muted" }] }
      : {
          type: "card",
          children: [
            { type: "text", value: "No agent sessions here yet", weight: "semibold" },
            { type: "text", value: "Run `claude` or `codex` in this directory and it will show up.", style: "caption", color: "muted" },
          ],
        });
  }

  tenon.views.set(VIEW, {
    title: "Agent Sessions",
    header: headerNode(st),
    body: { type: "vstack", spacing: 10, children: children }
  }, st.id);
}

// --- wiring ----------------------------------------------------------------

tenon.views.register(VIEW, { title: "Agent Sessions", instanced: true });

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
  // A header menu reports its OWN id plus the picked entry's value. Unwrapping the pick here
  // lets the strip speak the action vocabulary the rest of this handler already speaks.
  var chosen = action === "new" ? (value || "") : action;
  if (chosen === "refresh") {
    await scan(st);
  } else if (chosen === "new:claude") {
    await tenon.intents.send("terminal.open.v1", { command: "claude" });
  } else if (chosen === "new:codex") {
    await tenon.intents.send("terminal.open.v1", { command: "codex" });
  } else if (chosen.indexOf("resume:claude:") === 0) {
    // Each session gets a pane of its own. `terminal.run.v1` would reuse whichever
    // terminal is in this tab, so resuming would take over a shell the user is already
    // working in — and two resumed sessions would fight over one pane.
    await tenon.intents.send("terminal.open.v1", {
      command: "claude --resume " + shellArgument(chosen.slice("resume:claude:".length))
    });
  } else if (chosen.indexOf("resume:codex:") === 0) {
    await tenon.intents.send("terminal.open.v1", {
      command: "codex resume " + shellArgument(chosen.slice("resume:codex:".length))
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
