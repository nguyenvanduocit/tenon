// claude-sessions — lists the Claude Code conversations recorded for the directory
// you are working in, and resumes one in the terminal.
//
// Claude Code writes one JSONL transcript per session to
// `<claudeHome>/projects/<slug>/<sessionID>.jsonl`, where the slug is the project
// path with every non-alphanumeric character replaced by "-". This plugin reads
// those transcripts through canonical intents plus settings and view contributions.
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

var sessions = [];
var project = "";
var notice = "Loading…";
// Guards against a slow scan clobbering a newer one (settings can change twice in a row).
var generation = 0;

// --- resolving what to scan ------------------------------------------------

function setting(key) {
  return (tenon.settings.get(key) || "").trim();
}

// The directory whose sessions we show: an explicit setting wins, otherwise the
// workspace the user is currently in.
async function currentProject(call) {
  var explicit = setting("projectPath");
  if (explicit) return explicit;
  var result = call
    ? await call.send("workspace.state.v1", { limit: 256 })
    : await tenon.intents.send("workspace.state.v1", { limit: 256 });
  if (!result.ok) return "";
  var nodes = result.value.nodes || [];
  for (var i = 0; i < nodes.length; i++) {
    if (nodes[i].kind === "workspace" && nodes[i].selected) {
      return nodes[i].path || "";
    }
  }
  for (var j = 0; j < nodes.length; j++) {
    if (nodes[j].kind === "workspace") return nodes[j].path || "";
  }
  return "";
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

async function scan(call) {
  project = await currentProject(call);
  var gen = ++generation;
  if (!project) {
    sessions = [];
    notice = "Open a workspace to see its Claude Code sessions.";
    render();
    return;
  }
  notice = "Scanning…";
  render();

  var dir = sessionsDir(project);
  var result = await exec(
    "/bin/sh",
    [
      "-c",
      "cd " + shellPath(dir)
        + ' 2>/dev/null || exit 3\nstat -f "%m %z %N" "$PWD"/*.jsonl 2>/dev/null\n'
    ],
    project,
    call
  );
  if (gen !== generation) return;
  if (!result.ok || result.status !== 0) {
    sessions = [];
    notice = result.error || result.stderr || "Could not read the sessions directory.";
    render();
    return;
  }
  var found = parseStat(result.stdout || "");
  found.sort(function (a, b) { return b.mtime - a.mtime; });
  sessions = found.slice(0, parseInt(setting("limit") || "25", 10) || 25);
  notice = null;
  render();
  if (sessions.length) await enrich(gen, call);
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

async function enrich(gen, call) {
  // LC_ALL=C is load-bearing: a transcript carries pasted images and binary tool output,
  // and awk in a UTF-8 locale aborts the whole run on the first byte it cannot decode
  // ("towc: multibyte conversion failure") — leaving every session unnamed. Byte mode
  // reads them as bytes, and is ~2x faster besides.
  var args = ["LC_ALL=C", "/usr/bin/awk", AWK];
  for (var i = 0; i < sessions.length; i++) args.push(sessions[i].path);
  var result = await exec("/usr/bin/env", args, project, call);
  if (gen !== generation) return;
  if (!result.ok || result.status !== 0) {
    tenon.log(
      "claude-sessions: could not read session details: "
        + (result.error || result.stderr || "awk exited " + result.status)
    );
    return;
  }
  var byPath = {};
  for (var j = 0; j < sessions.length; j++) byPath[sessions[j].path] = sessions[j];
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
  render();
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

function render() {
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
    { type: "text", value: project || "no project directory", style: "caption", color: "muted" },
  ];

  if (notice) {
    children.push({ type: "card", children: [{ type: "text", value: notice, color: "muted" }] });
  } else if (!sessions.length) {
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
    for (var i = 0; i < sessions.length; i++) {
      if (i > 0) rows.push({ type: "divider" });
      rows.push(sessionRow(sessions[i]));
    }
    children.push({ type: "card", children: rows });
  }

  tenon.views.set(VIEW, { title: "Claude Sessions", body: { type: "vstack", spacing: 10, children: children } });
}

// --- wiring ----------------------------------------------------------------

tenon.views.register(VIEW, { title: "Claude Sessions" });

tenon.views.onSelect(VIEW, async function (action) {
  if (action === "refresh") {
    await scan();
  } else if (action === "new") {
    await tenon.intents.send("terminal.run.v1", { command: "claude" });
  } else if (action.indexOf("resume:") === 0) {
    // The host picks the terminal (this tab's, or a new terminal tab) — a panel click
    // happens while the panel itself is the active pane, so "type into the active pane"
    // would land nowhere.
    await tenon.intents.send("terminal.run.v1", {
      command: "claude --resume " + action.slice("resume:".length)
    });
  }
});

tenon.intents.handle("dev.tenon.claude-sessions.open.v1", async function (_, call) {
  var result = await call.send("workspace.tab.create.v1", {
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
  await scan(call);
  return {};
});

tenon.events.on("settings.changed", function () { scan(); });

// Follow the user between workspaces — but only re-scan when the directory really changed,
// since workspace.changed fires on every tab and split.
tenon.events.on("workspace.selected", rescanIfProjectChanged);
tenon.events.on("workspace.changed", rescanIfProjectChanged);

async function rescanIfProjectChanged() {
  if (await currentProject() !== project) await scan();
}

scan();
