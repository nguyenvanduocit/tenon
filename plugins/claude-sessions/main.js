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
    // What the host says is installed and how this person runs it. The pane never spells an
    // agent's command line itself; it asks for one.
    agents: [],
    notice: LOADING,
    // A refused favourite write, said out loud on the pane that asked for it. It is not the
    // pane's `notice`, because that one only speaks when the list is empty and this has to be
    // legible over a full list.
    favouriteError: null,
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

// --- favourites -------------------------------------------------------------

// A person marks the sessions worth coming back to. The mark's whole value is that it
// OUTLIVES the recent window: the pane shows the newest `limit` sessions, and a session
// becomes worth remembering long after it has fallen out of that slice. So a favourite is
// carried past the cutoff by the scan rather than merely sorted to the top of it.
//
// The record lives in this plugin's own storage — a closed scoped facility, so favourites
// need no permission, no intent, and no host state. One record holds every project; a pane
// shows only the marks made in the project that owns it.
var FAVOURITES_KEY = "favourites";

// Bounded (invariant 10). Only a person grows this list, but "only by hand" is not a bound:
// nothing above stops a script, and an unbounded value would grow one storage write without
// limit. At the ceiling the OLDEST mark gives way, so the mark just made is never refused.
var MAX_FAVOURITES = 200;

// How many ids one by-id lookup may name. A single SQL statement is the thing being bounded
// here, not the record: the rest of a very large favourites list is simply not fetched, and
// says so in the log rather than silently truncating the pane.
var MAX_FAVOURITE_LOOKUP = 100;

// The committed record, read once per generation and kept in step with storage. Every pane
// reads this one copy, because a mark belongs to the person and not to a pane.
var favourites = readFavourites();

function readFavourites() {
  var stored = tenon.storage.get(FAVOURITES_KEY);
  if (!Array.isArray(stored)) return [];
  var records = [];
  for (var i = 0; i < stored.length && records.length < MAX_FAVOURITES; i++) {
    var record = stored[i];
    if (!record || typeof record.key !== "string" || !record.key) continue;
    if (typeof record.project !== "string" || !record.project) continue;
    records.push({
      key: record.key,
      project: record.project,
      at: parseInt(record.at, 10) || 0
    });
  }
  return records;
}

function favouriteKey(provider, sessionID) {
  return provider + ":" + sessionID;
}

function indexOfFavourite(project, key) {
  for (var i = 0; i < favourites.length; i++) {
    if (favourites[i].key === key && favourites[i].project === project) return i;
  }
  return -1;
}

function isFavourite(project, provider, sessionID) {
  return indexOfFavourite(project, favouriteKey(provider, sessionID)) >= 0;
}

// The session ids marked in one project for one provider. This is what the scan needs: a
// Claude id keeps its transcript out of the recent slice, a Codex id is fetched by id.
function favouriteIDs(project, provider) {
  var prefix = provider + ":";
  var ids = [];
  for (var i = 0; i < favourites.length; i++) {
    var record = favourites[i];
    if (record.project !== project) continue;
    if (record.key.indexOf(prefix) !== 0) continue;
    ids.push(record.key.slice(prefix.length));
  }
  return ids;
}

// Marking is optimistic and then honest: the pane redraws immediately, and a storage write
// the host refuses puts the committed record back — `tenon.storage.get` reads a cache that
// only a committed write publishes, so it is the truth to fall back to.
async function toggleFavourite(st, provider, sessionID) {
  if (!st.project) return;
  var key = favouriteKey(provider, sessionID);
  var at = indexOfFavourite(st.project, key);
  var next = favourites.slice();
  if (at >= 0) {
    next.splice(at, 1);
  } else {
    next.push({
      key: key,
      project: st.project,
      at: Math.floor(Date.now() / 1000)
    });
    // The mark just made is the one entry the bound may not take, whatever the stored
    // timestamps say — a clock that moved backwards must not eat the person's click.
    while (next.length > MAX_FAVOURITES) {
      next.splice(oldestFavourite(next, next.length - 1), 1);
    }
  }
  favourites = next;
  st.favouriteError = null;
  renderAll();

  try {
    await tenon.storage.set(FAVOURITES_KEY, next);
  } catch (error) {
    favourites = readFavourites();
    if (panes[st.id] === st) {
      st.favouriteError = "Could not save that favourite: "
        + ((error && error.code) || "the write was refused");
    }
    renderAll();
    return;
  }
  renderAll();
}

function oldestFavourite(records, keep) {
  var oldest = keep === 0 ? 1 : 0;
  for (var i = 0; i < records.length; i++) {
    if (i === keep) continue;
    if (records[i].at < records[oldest].at) oldest = i;
  }
  return oldest;
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
  // A rescan is a fresh look at the same question, so last scan's refused write stops
  // speaking rather than following the pane around forever.
  st.favouriteError = null;
  render(st);

  await loadAgents(st, gen, call);
  if (gen !== st.generation || panes[st.id] !== st) return;

  var limit = sessionLimit();
  var claude = await scanClaude(st, gen, limit, call);
  if (gen !== st.generation || panes[st.id] !== st) return;
  var codex = await scanCodex(st, gen, limit, call);
  if (gen !== st.generation || panes[st.id] !== st) return;

  var found = claude.concat(codex);
  found.sort(function (a, b) { return b.mtime - a.mtime; });
  // The cutoff applies to unmarked sessions only, and marked ones lead. Both halves stay
  // bounded: `limit` for one, `MAX_FAVOURITES` for the other.
  var marked = [];
  var rest = [];
  for (var i = 0; i < found.length; i++) {
    if (isFavourite(st.project, found[i].provider, found[i].id)) marked.push(found[i]);
    else rest.push(found[i]);
  }
  st.sessions = marked.concat(rest.slice(0, limit));
  // A listing that failed must not read as "this project has no sessions".
  st.notice = st.scanError;
  render(st);
}

function sessionLimit() {
  var value = parseInt(setting("limit") || "25", 10) || 25;
  return Math.max(10, Math.min(100, value));
}

// Which agents this machine has, re-read with every scan so an agent installed since the
// pane opened appears on the next Refresh. The host owns the answer — including the options
// this person passes — so the pane offers exactly what the Launcher offers.
async function loadAgents(st, gen, call = tenon.intents) {
  var result = await call.send("agent.inventory.v1", {});
  if (gen !== st.generation || panes[st.id] !== st) return;
  st.agents = result.ok ? (result.value.agents || []) : [];
  if (!result.ok) {
    tenon.log("agent-sessions: could not list agents: " + result.error.code);
  }
}

function agentLabel(st, id) {
  for (var i = 0; i < st.agents.length; i++) {
    if (st.agents[i].id === id) return st.agents[i].label;
  }
  return id;
}

// --- starting and continuing -----------------------------------------------

// Every command line this pane runs is composed by the host, which is the only place that
// knows which agents exist, which options this person passes them, and how each provider
// spells "resume". Each session gets a pane of its own: `terminal.run.v1` would reuse
// whichever terminal is in this tab, taking over a shell somebody is already working in.
async function launch(st, request, call = tenon.intents) {
  var composed = await call.send("agent.command.v1", request);
  if (panes[st.id] !== st) return composed;
  if (!composed.ok) {
    st.notice = "Could not start " + agentLabel(st, request.agent)
      + ": " + composed.error.code;
    render(st);
    return composed;
  }
  var opened = await call.send("terminal.open.v1", {
    command: composed.value.commandLine,
    workingDirectory: st.project
  });
  if (panes[st.id] !== st) return opened;
  if (!opened.ok) {
    st.notice = "Could not open a pane: " + opened.error.code;
    render(st);
  }
  return opened;
}

// Continuing a session with the agent that wrote it is a resume. Continuing it with any
// other agent is a reading task, so that agent is told where the transcript is and the host
// writes the instructions — there is no flag on either CLI for the other one's session.
async function continueSession(st, agentID, sessionID, call = tenon.intents) {
  var session = null;
  for (var i = 0; i < st.sessions.length; i++) {
    if (st.sessions[i].id === sessionID) session = st.sessions[i];
  }
  if (!session) return;

  var request = {
    agent: agentID,
    session: { agent: session.provider, sessionID: session.id }
  };
  if (session.provider !== agentID) {
    var path = session.path || await transcriptPath(st, session, call);
    if (panes[st.id] !== st) return;
    if (!path) {
      st.notice = "No transcript on disk for that session, so "
        + agentLabel(st, agentID) + " would have nothing to read.";
      render(st);
      return;
    }
    request.session.transcriptPath = path;
  }
  await launch(st, request, call);
}

// Opening a session for reading rather than for running. `workspace.content.open.v1` already
// carries every other kind of pane this plugin opens, and a recorded session is one more kind
// of content — so this needs no new contract and no manifest change.
//
// The path is required and is not this plugin's to vouch for: the host re-decides containment
// under its own provider roots, with symlinks resolved, and refuses anything else. A Codex row
// carries no path until somebody asks for one, so it is looked up here rather than for every
// row of every scan.
async function openRecorded(st, sessionID, call = tenon.intents) {
  var session = null;
  for (var i = 0; i < st.sessions.length; i++) {
    if (st.sessions[i].id === sessionID) session = st.sessions[i];
  }
  if (!session) return;

  var path = session.path || await transcriptPath(st, session, call);
  if (panes[st.id] !== st) return;
  if (!path) {
    st.notice = "No transcript on disk for that session, so there is nothing to read.";
    render(st);
    return;
  }

  var opened = await call.send("workspace.content.open.v1", {
    content: {
      kind: "agentSession",
      provider: session.provider,
      sessionID: session.id,
      transcriptPath: path,
      title: sessionTitle(session)
    }
  });
  if (panes[st.id] !== st) return;
  if (!opened.ok) {
    st.notice = "Could not open that session: " + opened.error.code;
    render(st);
  }
}

// A Codex thread's transcript is a rollout file named after the thread and filed by date.
// The SQLite index that lists the session carries no path, so it is looked up once — at the
// moment somebody asks another agent to read it, not for every row of every scan.
async function transcriptPath(st, session, call = tenon.intents) {
  if (session.provider !== "codex") return "";
  var home = setting("codexHome") || "~/.codex";
  var script = "exec /usr/bin/find " + shellPath(home)
    + "/sessions -maxdepth 5 -type f -name \"*$1.jsonl\" -print -quit";
  var result = await exec(
    "/bin/sh",
    ["-c", script, "tenon-codex-transcript", session.id],
    st.project,
    call
  );
  if (!result.ok || result.status !== 0) return "";
  var found = (result.stdout || "").split("\n")[0].trim();
  session.path = found;
  return found;
}

async function scanClaude(st, gen, limit, call = tenon.intents) {
  var found = await listClaudeTranscripts(st, gen, call);
  if (!found || gen !== st.generation || panes[st.id] !== st) return [];
  found.sort(function (a, b) { return b.mtime - a.mtime; });
  found = recentAndMarked(st, found, limit);
  if (found.length) await enrichClaude(st, gen, found, call);
  return found;
}

// The listing already walked the whole directory, so keeping a marked transcript past the
// cutoff costs nothing but the awk pass that names it.
function recentAndMarked(st, sessions, limit) {
  var kept = sessions.slice(0, limit);
  for (var i = limit; i < sessions.length; i++) {
    if (isFavourite(st.project, sessions[i].provider, sessions[i].id)) kept.push(sessions[i]);
  }
  return kept;
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

// The recent window, then the marked threads that window missed. Codex bounds its own
// answer with a LIMIT rather than handing over a list to slice, so honouring a mark past
// the cutoff means asking a second time — by id, for exactly the ids still missing.
async function scanCodex(st, gen, limit, call = tenon.intents) {
  var sessions = await fetchCodex(st, gen, "", limit, call);
  if (gen !== st.generation || panes[st.id] !== st) return [];
  var missing = missingCodexFavourites(st, sessions);
  if (!missing.length) return sessions;
  var marked = await fetchCodex(st, gen, codexIDFilter(missing), missing.length, call);
  if (gen !== st.generation || panes[st.id] !== st) return [];
  return sessions.concat(marked);
}

function missingCodexFavourites(st, sessions) {
  var seen = {};
  for (var i = 0; i < sessions.length; i++) seen[sessions[i].id] = true;
  var marked = favouriteIDs(st.project, "codex");
  var missing = [];
  for (var j = 0; j < marked.length; j++) {
    if (!seen[marked[j]]) missing.push(marked[j]);
  }
  // One statement is what MAX_FAVOURITE_LOOKUP bounds. Past it the remaining marks are left
  // out of this scan and said out loud, rather than silently thinning the pane.
  if (missing.length > MAX_FAVOURITE_LOOKUP) {
    tenon.log(
      "agent-sessions: " + (missing.length - MAX_FAVOURITE_LOOKUP)
        + " favourited Codex sessions past the " + MAX_FAVOURITE_LOOKUP
        + " this scan looks up"
    );
    missing = missing.slice(0, MAX_FAVOURITE_LOOKUP);
  }
  return missing;
}

function codexIDFilter(ids) {
  var quoted = [];
  for (var i = 0; i < ids.length; i++) quoted.push(sqlString(ids[i]));
  return " AND id IN (" + quoted.join(", ") + ")";
}

async function fetchCodex(st, gen, filter, limit, call = tenon.intents) {
  var query =
    "SELECT id, "
      + "CASE WHEN recency_at > 0 THEN recency_at ELSE updated_at END AS mtime, "
      + "substr(COALESCE(NULLIF(trim(name), ''), NULLIF(trim(title), ''), "
      + "NULLIF(trim(first_user_message), ''), NULLIF(trim(preview), ''), ''), 1, 160) AS title, "
      + "tokens_used AS tokens, substr(COALESCE(git_branch, ''), 1, 80) AS branch "
      + "FROM threads WHERE archived = 0 AND source = 'cli' AND cwd = "
      + sqlString(st.project) + filter
      + " ORDER BY mtime DESC, id DESC LIMIT " + limit;
  var result = await runCodexQuery(st, query, call);
  if (gen !== st.generation || panes[st.id] !== st) return [];
  if (!result.ok || result.status !== 0) {
    // Older Codex indexes predate the richer preview columns but still carry titles.
    var fallback =
      "SELECT id, updated_at AS mtime, substr(COALESCE(title, ''), 1, 160) AS title, "
        + "tokens_used AS tokens, substr(COALESCE(git_branch, ''), 1, 80) AS branch "
        + "FROM threads WHERE archived = 0 AND source = 'cli' AND cwd = "
        + sqlString(st.project) + filter
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

// --- rendering -------------------------------------------------------------

// One session = two quiet lines inside the shared list card: what it was about, then the
// facts about it. Everything that was a badge before is one muted line, so twenty sessions
// read as a list instead of twenty competing boxes.
function sessionRow(st, session) {
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
  // Reading a session you already had, without starting anything. The host opens its own
  // Agent Lens over the recorded transcript, so this pane hands over a reference and stops
  // there — it renders no transcript itself and learns nothing about how one is read.
  meta.push({
    type: "button",
    label: "Details",
    action: "details:" + session.id,
    style: "plain"
  });
  // One button per installed agent. The agent that wrote the session resumes it; any other
  // one continues it, and the host is what decides which of those a command line means.
  for (var a = 0; a < st.agents.length; a++) {
    var agent = st.agents[a];
    meta.push({
      type: "button",
      label: agent.id === session.provider ? "Resume" : "In " + agent.label,
      action: "open:" + agent.id + ":" + session.id,
      style: "plain"
    });
  }

  // The mark sits on the title line, not among the verbs: it says something about the
  // session rather than doing something with it, and the verb row already carries three.
  // Measured at 420 pt: a fourth verb broke every label in the row onto two lines
  // ("Detai/ls", "Resum/e"), while the title line absorbs it by wrapping the title one line
  // further. Its state is in words as well as in a glyph, because this label is also what
  // VoiceOver reads.
  var marked = isFavourite(st.project, session.provider, session.id);
  return {
    type: "vstack",
    spacing: 4,
    children: [
      {
        type: "hstack",
        children: [
          { type: "text", value: sessionTitle(session), weight: "semibold" },
          { type: "spacer" },
          {
            type: "button",
            label: marked ? "★ Unfavourite" : "☆ Favourite",
            action: "fav:" + session.provider + ":" + session.id,
            style: "plain"
          },
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
  // Starting a session is a menu of named lines, not a row of glyphs nobody can tell apart:
  // there is no Claude symbol and no Codex symbol to draw. The entries are whatever the host
  // says is installed, so an agent this machine does not have is never offered.
  if (st.agents.length) {
    var entries = [];
    for (var a = 0; a < st.agents.length; a++) {
      entries.push({
        value: "start:" + st.agents[a].id,
        label: "New " + st.agents[a].label + " session"
      });
    }
    trailing.push({
      type: "menu",
      id: "new",
      systemName: "plus",
      tooltip: "Start a session",
      entries: entries
    });
  }
  trailing.push({
    type: "iconButton",
    id: "refresh",
    systemName: "arrow.clockwise",
    tooltip: "Refresh"
  });
  return { leading: leading, trailing: trailing };
}

// One card holding a list, hairlines between rows — a list, not a stack of boxes. A heading
// appears only when there are two groups to tell apart, so a pane with nothing marked reads
// exactly as it did before anyone had a favourite.
function listCard(st, sessions, heading) {
  var rows = [];
  if (heading) {
    rows.push({ type: "text", value: heading, style: "caption", weight: "medium", color: "muted" });
  }
  for (var i = 0; i < sessions.length; i++) {
    if (i > 0 || heading) rows.push({ type: "divider" });
    rows.push(sessionRow(st, sessions[i]));
  }
  return { type: "card", children: rows };
}

function render(st) {
  if (panes[st.id] !== st) return;
  var children = [];

  // A refused write is reported over the list, because the list is what it disagrees with.
  if (st.favouriteError) {
    children.push({
      type: "card",
      children: [{ type: "text", value: st.favouriteError, color: "red" }]
    });
  }

  var marked = [];
  var rest = [];
  for (var s = 0; s < st.sessions.length; s++) {
    if (isFavourite(st.project, st.sessions[s].provider, st.sessions[s].id)) {
      marked.push(st.sessions[s]);
    } else {
      rest.push(st.sessions[s]);
    }
  }

  if (marked.length) {
    children.push(listCard(st, marked, "Favourites"));
    if (rest.length) children.push(listCard(st, rest, "Recent"));
  } else if (rest.length) {
    children.push(listCard(st, rest, null));
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

// A mark belongs to the person, not to the pane that made it, so every open pane showing
// that project redraws with it.
function renderAll() {
  var list = paneList();
  for (var i = 0; i < list.length; i++) render(list[i]);
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
  } else if (chosen.indexOf("start:") === 0) {
    await launch(st, { agent: chosen.slice("start:".length) });
  } else if (chosen.indexOf("details:") === 0) {
    await openRecorded(st, chosen.slice("details:".length));
  } else if (chosen.indexOf("fav:") === 0) {
    var mark = chosen.slice("fav:".length);
    var at = mark.indexOf(":");
    if (at > 0) await toggleFavourite(st, mark.slice(0, at), mark.slice(at + 1));
  } else if (chosen.indexOf("open:") === 0) {
    var rest = chosen.slice("open:".length);
    var separator = rest.indexOf(":");
    if (separator > 0) {
      await continueSession(st, rest.slice(0, separator), rest.slice(separator + 1));
    }
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
