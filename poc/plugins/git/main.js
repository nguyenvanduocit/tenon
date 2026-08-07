// git — a full source-control panel built ONLY on the public tenon API:
// process/filesystem resources + settings + status/view contributions + canonical intents.
// It parses `git status --porcelain=v2` into staged / changed / conflict sections,
// stages, unstages, discards, commits, and syncs — and opens each file's diff in
// the host's default diff view in a new tab,
// never carved inline.
//
// Instanced (T-012 model): every pane owns an independent panel bound to the repo of the
// workspace that OWNS the pane, resolved through `workspace.pane.owner.v1`. The status bar is
// one global surface, so it alone follows the selected workspace and the focused pane.
//
// Point "Repository path" at a repo in Settings (⌘,), or leave it on "~" and each panel
// uses the repo of the workspace its pane lives in.

var LOG_SEP = String.fromCharCode(31); // field separator for `git log --pretty`, not for actions
var VIEW = "git";

// instanceID (pane UUID) → this pane's panel state. `bar` drives only the status bar.
var panes = {};
var bar = makeState(null);

// Project roots reported per pane (slot UUID → path) — a host fact shared by instances.
var paneRoots = {};

function makeState(instanceID) {
  return {
    id: instanceID,
    workspaceId: null,
    workspacePath: "",
    repoPath: null,
    model: emptyModel(),
    commitMessage: "",
    // Sticky project-root following (T-030): a panel follows the focused pane within its
    // own workspace; the bar follows the focused pane anywhere.
    followedRepo: "",
    focusedSlot: null,
    watch: null,
    watchedRepo: null,
    debounceHandle: null
  };
}

function emptyModel() {
  return {
    isRepo: false, branch: "?", ahead: 0, behind: 0, upstream: null,
    hasHead: true, staged: [], changed: [], merge: [], recent: [],
  };
}

function paneList() {
  var ids = Object.keys(panes);
  var list = [];
  for (var i = 0; i < ids.length; i++) list.push(panes[ids[i]]);
  return list;
}

// --- repo resolution -------------------------------------------------------

function settingRepo() {
  var s = (tenon.settings.get("repoPath") || "").trim();
  return s && s !== "~" ? s : null;
}

// Bounds on one snapshot walk (invariant 10). `workspace.state.v1` pages at up to 256
// nodes a reply, so MAX_STATE_PAGES reaches 4096 nodes — past any real workspace tree.
var MAX_STATE_PAGES = 16;

// The selected workspace node, or the first workspace when nothing is selected.
//
// This walks every page. Reading only the first one was a silent wrong answer: `selected`
// is a flag on one node among all of them, so a workspace past node 128 (the default page
// size) made this report the wrong repo rather than fail — the same defect
// `workspace.pane.owner.v1` removed from the pane→workspace join.
async function selectedWorkspace(call = tenon.intents) {
  var firstWorkspace = null;
  var cursor = null;
  for (var page = 0; page < MAX_STATE_PAGES; page++) {
    var input = { limit: 256 };
    if (cursor) input.cursor = cursor;
    var result = await call.send("workspace.state.v1", input);
    if (!result.ok) return null;
    var nodes = result.value.nodes || [];
    for (var i = 0; i < nodes.length; i++) {
      if (nodes[i].kind !== "workspace") continue;
      if (nodes[i].selected) return nodes[i];
      if (!firstWorkspace) firstWorkspace = nodes[i];
    }
    cursor = result.value.nextCursor;
    if (!cursor) break;
  }
  return firstWorkspace;
}

/// The workspace the user is currently in — what the status bar means by "the repo".
async function workspacePath(call = tenon.intents) {
  var workspace = await selectedWorkspace(call);
  return (workspace && workspace.path) || "";
}

// The workspace that owns a pane, resolved by the host.
async function owningWorkspace(instanceID, call = tenon.intents) {
  var result = await call.send("workspace.pane.owner.v1", { paneID: instanceID });
  if (!result.ok) return { id: null, path: "" };
  return { id: result.value.workspaceID, path: result.value.workspacePath };
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

// An explicit "Repository path" setting always wins; otherwise discover the repo that
// contains the state's own base — a panel's owning workspace, the bar's selected one.
// The setting is re-read on every call, so a slow discovery cannot answer for a stale path.
async function resolveRepo(st, call = tenon.intents) {
  var explicit = settingRepo();
  if (explicit) { st.repoPath = explicit; return st.repoPath; }
  // A pane's project root outranks the cached discovery: the agent moved, so do we.
  if (st.followedRepo) { st.repoPath = st.followedRepo; return st.repoPath; }
  if (st.repoPath) return st.repoPath;
  var base = st.id ? st.workspacePath : await workspacePath(call);
  var root = await exec(
    "/usr/bin/git",
    ["rev-parse", "--show-toplevel"],
    base || "/",
    call
  );
  if (settingRepo()) { st.repoPath = settingRepo(); return st.repoPath; }
  if (root.ok && root.status === 0) st.repoPath = (root.stdout || "").trim();
  return st.repoPath;
}

async function git(st, args, call = tenon.intents) {
  var repo = await resolveRepo(st, call);
  if (!repo) return { ok: false, status: 1, stdout: "", stderr: "no repository" };
  return await exec("/usr/bin/git", args, repo, call);
}

// Runs a mutating command, reports the first error line as a toast, then refreshes the
// acting state AND the status bar, which summarises whatever just changed.
async function op(st, args, label, call = tenon.intents) {
  var r = await git(st, args, call);
  if (!r.ok || r.status !== 0) {
    var msg = ((r.stderr || r.error || "") + "").trim().split("\n")[0];
    var input = {
      message: (label || "Git") + " failed" + (msg ? ": " + msg : ""),
      kind: "error"
    };
    await call.send("ui.toast.v1", input);
  }
  await refresh(st, call);
  if (st !== bar) await refresh(bar, call);
}

// --- status parsing (porcelain v2, NUL-delimited) --------------------------

function pathAfter(rec, n) {
  var count = 0;
  for (var i = 0; i < rec.length; i++) {
    if (rec[i] === " ") { count++; if (count === n) return rec.slice(i + 1); }
  }
  return "";
}

function parseStatus(out) {
  var recs = out.split(String.fromCharCode(0));
  var m = emptyModel();
  m.isRepo = true;
  var entries = [];
  for (var i = 0; i < recs.length; i++) {
    var rec = recs[i];
    if (!rec) continue;
    if (rec.indexOf("# branch.oid ") === 0) {
      m.hasHead = rec.slice(13) !== "(initial)";
    } else if (rec.indexOf("# branch.head ") === 0) {
      var head = rec.slice(14);
      m.branch = head === "(detached)" ? "detached HEAD" : head;
    } else if (rec.indexOf("# branch.upstream ") === 0) {
      m.upstream = rec.slice(18);
    } else if (rec.indexOf("# branch.ab ") === 0) {
      var parts = rec.slice(12).split(" ");
      for (var j = 0; j < parts.length; j++) {
        if (parts[j][0] === "+") m.ahead = parseInt(parts[j].slice(1), 10) || 0;
        if (parts[j][0] === "-") m.behind = parseInt(parts[j].slice(1), 10) || 0;
      }
    } else if (rec[0] === "1" && rec[1] === " ") {
      entries.push({ path: pathAfter(rec, 8), staged: rec[2], unstaged: rec[3], conflict: false });
    } else if (rec[0] === "2" && rec[1] === " ") {
      // Rename/copy: destination in this record, original path is the next token.
      var orig = recs[i + 1];
      i++;
      entries.push({ path: pathAfter(rec, 9), staged: rec[2], unstaged: rec[3], origPath: orig, conflict: false });
    } else if (rec[0] === "u" && rec[1] === " ") {
      entries.push({ path: pathAfter(rec, 10), staged: rec[2], unstaged: rec[3], conflict: true });
    } else if (rec[0] === "?" && rec[1] === " ") {
      entries.push({ path: rec.slice(2), staged: "?", unstaged: "?", conflict: false });
    }
  }
  m.merge = entries.filter(function (e) { return e.conflict; });
  m.staged = entries.filter(function (e) { return !e.conflict && e.staged !== "." && e.staged !== "?"; });
  m.changed = entries.filter(function (e) { return !e.conflict && e.unstaged !== "."; });
  return m;
}

function parseLog(out) {
  return out.split("\n").filter(Boolean).map(function (line) {
    var f = line.split(LOG_SEP);
    return { hash: f[0], subject: f[1] || "" };
  });
}

// --- refresh ---------------------------------------------------------------

async function refresh(st, call = tenon.intents) {
  var repo = await resolveRepo(st, call);
  if (!repo) {
    st.model = emptyModel();
    publish(st);
    return;
  }
  var status = await git(
    st,
    ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"],
    call
  );
  if (!status.ok || status.status !== 0) {
    st.model = emptyModel();
    publish(st);
    return;
  }
  var next = parseStatus(status.stdout);
  var log = await git(
    st,
    ["log", "-n", "5", "--pretty=%h" + LOG_SEP + "%s"],
    call
  );
  if (log.ok && log.status === 0) next.recent = parseLog(log.stdout);
  st.model = next;
  publish(st);
}

function publish(st) {
  if (st === bar) updateStatusBar();
  else render(st);
}

function updateStatusBar() {
  if (!bar.model.isRepo) {
    tenon.statusBar.set("⎇ no repo");
    return;
  }
  var count = bar.model.staged.length + bar.model.changed.length + bar.model.merge.length;
  var sync = "";
  if (bar.model.ahead) sync += " ↑" + bar.model.ahead;
  if (bar.model.behind) sync += " ↓" + bar.model.behind;
  tenon.statusBar.set("⎇ " + bar.model.branch + (count ? " ±" + count : "") + sync);
}

// --- view tree -------------------------------------------------------------

function statusMeta(ch) {
  switch (ch) {
    case "M": return { code: "M", tint: "amber" };
    case "A": return { code: "A", tint: "green" };
    case "D": return { code: "D", tint: "red" };
    case "R": return { code: "R", tint: "amber" };
    case "C": return { code: "C", tint: "amber" };
    case "U": return { code: "U", tint: "red" };
    case "?": return { code: "?", tint: "muted" };
    default: return { code: (ch || " ").trim() || "•", tint: "muted" };
  }
}

function shortName(path) {
  var parts = path.split("/");
  return parts[parts.length - 1] || path;
}

// --- the pane's chrome header ----------------------------------------------

function syncText(model) {
  var parts = [];
  if (model.ahead) parts.push("↑" + model.ahead);
  if (model.behind) parts.push("↓" + model.behind);
  return parts.join(" ");
}

function syncTooltip(model) {
  var parts = [];
  if (model.ahead) parts.push(model.ahead + " ahead");
  if (model.behind) parts.push(model.behind + " behind");
  return parts.join(", ") + " " + (model.upstream || "upstream");
}

// What a supervisor reads off a git panel WITHOUT reading it: which branch it is on, how
// much is uncommitted, how far the branch has drifted, and one verb to re-read the repo.
// Each of those left the body when it arrived here — the strip owns the pane's identity and
// its measurement, the body owns the files.
//
// `leading` holds five items and folds from its LAST one backwards, so the order here is
// urgency order: a three-column pane keeps the branch and the conflicts and gives up the
// counts. Every badge says its word as well as its number, because a folded badge becomes
// one line of its own text in the `…` menu and a bare "3" names nothing there.
function headerNode(model) {
  if (!model.isRepo) return null;
  var leading = [
    { type: "image", id: "branch-icon", systemName: "arrow.triangle.branch", tint: "muted" },
    { type: "label", id: "branch", text: model.branch, weight: "medium", truncation: "middle" }
  ];
  if (model.merge.length) {
    leading.push({ type: "badge", id: "conflicts", text: model.merge.length + " conflicted", tint: "red" });
  }
  if (model.staged.length) {
    leading.push({ type: "badge", id: "staged", text: model.staged.length + " staged", tint: "green" });
  }
  if (model.changed.length) {
    leading.push({ type: "badge", id: "changed", text: model.changed.length + " changed", tint: "amber" });
  }
  var trailing = [];
  if (model.ahead || model.behind) {
    trailing.push({
      type: "badge",
      id: "sync",
      text: syncText(model),
      tint: "amber",
      tooltip: syncTooltip(model)
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

// Every action is an object the host hands back to onSelect exactly as written here.
function btn(label, action, style) {
  return { type: "button", label: label, action: action, style: style || "plain" };
}

function fileRow(e, section) {
  var meta = statusMeta(section === "staged" ? e.staged : e.unstaged);
  var children = [
    { type: "badge", value: meta.code, tint: meta.tint },
    btn(e.path, { do: "open", section: section, path: e.path }, "plain"),
    { type: "spacer" },
  ];
  if (section === "staged") {
    children.push(btn("Unstage", { do: "unstage", path: e.path }));
  } else if (section === "changed") {
    children.push(btn("Stage", { do: "stage", path: e.path }));
    children.push(btn("Discard", { do: "discard", path: e.path }));
  }
  return { type: "hstack", spacing: 6, children: children };
}

// The heading names its files; the count of them is a header badge. Two places saying
// "3" is the two-row duplication the one-header rule deletes.
function sectionCard(title, entries, section, bulkLabel, bulkAction) {
  var header = [
    { type: "text", value: title, weight: "semibold", color: "text" },
    { type: "spacer" },
  ];
  if (bulkLabel) header.push(btn(bulkLabel, bulkAction));
  var children = [{ type: "hstack", spacing: 6, children: header }];
  entries.forEach(function (e) { children.push(fileRow(e, section)); });
  return { type: "card", children: children };
}

function render(st) {
  if (!st.id || panes[st.id] !== st) return;
  var model = st.model;
  var children = [];

  // Which branch, and how far it has drifted, are read off the chrome header. What stays
  // here is the row of verbs that act on it.
  var branchRow = [
    btn("Switch branch", { do: "switchBranch" }),
    { type: "spacer" },
    btn("Fetch", { do: "fetch" }),
    btn("Pull", { do: "pull" }),
    btn("Push", { do: "push" }),
  ];
  children.push({ type: "card", children: [
    { type: "hstack", spacing: 8, children: branchRow },
    { type: "hstack", spacing: 8, children: [btn("Stash", { do: "stash" }), btn("Pop stash", { do: "stashPop" }), { type: "spacer" }] },
    { type: "field", label: "New branch", children: [{ type: "textfield", value: "", placeholder: "branch name", action: { do: "newBranch" } }] },
  ] });

  // Commit box.
  children.push({ type: "card", children: [
    { type: "field", label: "Commit message", children: [{ type: "textfield", value: st.commitMessage, placeholder: "Message…", action: { do: "commitMsg" } }] },
    { type: "hstack", spacing: 8, children: [{ type: "spacer" }, btn("Commit staged", { do: "commit" }, "primary"), btn("Commit all", { do: "commitAll" })] },
  ] });

  if (model.merge.length) children.push(sectionCard("Conflicts", model.merge, "merge", null, null));
  if (model.staged.length) children.push(sectionCard("Staged", model.staged, "staged", "Unstage all", { do: "unstageAll" }));
  if (model.changed.length) children.push(sectionCard("Changes", model.changed, "changed", "Discard all", { do: "discardAll" }));

  if (model.changed.length && !model.staged.length) {
    // A quick one-tap stage-all when nothing is staged yet.
    children.push({ type: "hstack", spacing: 8, children: [{ type: "spacer" }, btn("Stage all", { do: "stageAll" }, "primary")] });
  }

  if (model.isRepo && !model.merge.length && !model.staged.length && !model.changed.length) {
    children.push({ type: "card", children: [{ type: "text", value: "Working tree clean", style: "caption", color: "muted" }] });
  }

  if (model.recent.length) {
    var recentChildren = [{ type: "text", value: "Recent", weight: "semibold", color: "muted", style: "caption" }];
    model.recent.forEach(function (c) {
      recentChildren.push({ type: "hstack", spacing: 6, children: [
        { type: "text", value: c.hash, style: "code", color: "amber" },
        { type: "text", value: c.subject, style: "caption", color: "muted" },
      ] });
    });
    children.push({ type: "card", children: recentChildren });
  }

  if (!model.isRepo) {
    children = [{ type: "card", children: [{ type: "text", value: "No git repository. Set \"Repository path\" in Settings.", style: "caption", color: "muted" }] }];
  }

  var specification = {
    title: "Git",
    body: { type: "vstack", spacing: 10, children: children }
  };
  // Omitting `header` clears the previous one, which is exactly what a panel that has lost
  // its repository wants to say: there is no branch and nothing to count.
  var header = headerNode(model);
  if (header) specification.header = header;
  tenon.views.set(VIEW, specification, st.id);
}

// --- actions ---------------------------------------------------------------

function findEntry(st, section, path) {
  var list = section === "staged" ? st.model.staged : section === "merge" ? st.model.merge : st.model.changed;
  for (var i = 0; i < list.length; i++) if (list[i].path === path) return list[i];
  return null;
}

async function openDiff(st, section, path) {
  var e = findEntry(st, section, path);
  var untracked = e ? (e.staged === "?" || e.unstaged === "?") : false;
  var res = await tenon.intents.send("workspace.content.open.v1", {
    content: {
      kind: "diff",
      source: "git",
      repositoryPath: st.repoPath,
      path: path,
      staged: section === "staged",
      untracked: untracked,
      originalPath: e ? (e.origPath || null) : null,
      title: shortName(path) + (section === "staged" ? " (staged)" : "")
    }
  });
  if (!res.ok) tenon.log("open diff failed: " + res.error.code);
}

async function discard(st, path) {
  var e = findEntry(st, "changed", path);
  var result = await tenon.intents.send("ui.confirm.v1", {
    title: "Discard changes to " + shortName(path) + "? This cannot be undone.",
    destructive: true
  });
  if (!result.ok || !result.value.confirmed) return;
  if (e && (e.staged === "?" || e.unstaged === "?")) {
    await op(st, ["clean", "-f", "--", path], "Discard untracked " + shortName(path));
  } else {
    await op(st, ["restore", "--worktree", "--", path], "Discard " + shortName(path));
  }
}

async function discardAll(st) {
  var result = await tenon.intents.send("ui.confirm.v1", {
    title: "Discard all " + st.model.changed.length + " changed files? This cannot be undone.",
    destructive: true
  });
  if (result.ok && result.value.confirmed) {
    await op(st, ["restore", "--worktree", "--", "."], "Discard tracked changes");
  }
}

async function doCommit(st, includeAll) {
  var msg = (st.commitMessage || "").trim();
  if (!msg) {
    var prompted = await tenon.intents.send("ui.prompt.v1", {
      title: "Commit message",
      multiline: true
    });
    msg = (prompted.ok && prompted.value.value
      ? prompted.value.value
      : "").trim();
    if (!msg) return;
  }
  if (includeAll) {
    var staged = await git(st, ["add", "-A"]);
    if (!staged.ok || staged.status !== 0) {
      await tenon.intents.send("ui.toast.v1", {
        message: "Stage all failed",
        kind: "error"
      });
      return;
    }
  }
  st.commitMessage = "";
  await op(st, ["commit", "-m", msg], "Commit");
}

// The branch list, in the host's own pick list — the plugin describes it, the shell draws it.
async function switchBranch(st, call = tenon.intents) {
  var r = await git(st, ["branch", "--format=%(refname:short)"], call);
  var names = (r.stdout || "").split("\n").filter(Boolean);
  if (!names.length) {
    var toastInput = {
      message: "No branches found",
      kind: "warning"
    };
    await call.send("ui.toast.v1", toastInput);
    return;
  }
  var pickInput = {
    items: names.map(function (name) {
      return {
        id: name,
        label: name,
        icon: "arrow.triangle.branch",
        detail: name === st.model.branch ? "current" : ""
      };
    }),
    placeholder: "Switch branch"
  };
  var choice = await call.send("ui.pick.v1", pickInput);
  var selected = choice.ok ? choice.value.selectedID : null;
  if (selected && selected !== st.model.branch) {
    await op(st, ["switch", selected], "Switch to " + selected, call);
  }
}

tenon.views.register(VIEW, { title: "Git", instanced: true });

// Whatever the view declared arrives back verbatim — no packing, no splitting.
tenon.views.onSelect(VIEW, async function (action, value, instanceID) {
  var st = panes[instanceID];
  if (!st) return;
  // A header control reports the opaque id string this plugin chose for it; a body button
  // reports the action object it was declared with. One handler, two shapes.
  if (typeof action === "string") {
    if (action === "refresh") await refresh(st);
    return;
  }
  switch (action.do) {
    case "open": await openDiff(st, action.section, action.path); break;
    case "stage": await op(st, ["add", "--", action.path], "Stage"); break;
    case "unstage": await op(st, st.model.hasHead ? ["restore", "--staged", "--", action.path] : ["rm", "--cached", "--", action.path], "Unstage"); break;
    case "discard": await discard(st, action.path); break;
    case "stageAll": await op(st, ["add", "-A"], "Stage all"); break;
    case "unstageAll": await op(st, st.model.hasHead ? ["restore", "--staged", "--", "."] : ["rm", "--cached", "-r", "--", "."], "Unstage all"); break;
    case "discardAll": await discardAll(st); break;
    case "commit": await doCommit(st, false); break;
    case "commitAll": await doCommit(st, true); break;
    case "commitMsg": st.commitMessage = value || ""; break;
    case "switchBranch": await switchBranch(st); break;
    case "fetch": await op(st, ["fetch", "--all", "--prune"], "Fetch"); break;
    case "pull": await op(st, ["pull", "--ff-only"], "Pull"); break;
    case "push": await op(st, ["push"], "Push"); break;
    case "stash": await op(st, ["stash", "push", "--include-untracked"], "Stash"); break;
    case "stashPop": await op(st, ["stash", "pop"], "Pop stash"); break;
    case "newBranch":
      if (value && value.trim()) {
        await op(st, ["switch", "-c", value.trim()], "Create branch " + value.trim());
      }
      break;
  }
});

tenon.views.onOpen(VIEW, async function (instanceID) {
  var st = makeState(instanceID);
  panes[instanceID] = st;
  var owner = await owningWorkspace(instanceID);
  if (panes[instanceID] !== st) return;
  st.workspaceId = owner.id;
  st.workspacePath = owner.path;
  render(st);
  await refresh(st);
  await watchRepo(st);
});

tenon.views.onClose(VIEW, function (instanceID) {
  var st = panes[instanceID];
  if (!st) return;
  if (st.watch) st.watch.cancel();
  if (st.debounceHandle !== null) tenon.timers.cancel(st.debounceHandle);
  delete panes[instanceID];
});

// --- commands + lifecycle --------------------------------------------------

// Commands arrive without a pane; they mean the panel the human is looking at — the
// instance owned by the selected workspace — and fall back to the status bar's repo.
async function commandTarget(call = tenon.intents) {
  var workspace = await selectedWorkspace(call);
  // Only a genuinely selected workspace may claim a pane; `selectedWorkspace` falls back
  // to the first one it saw, and that fallback must not silently retarget a command.
  var selected = workspace && workspace.selected ? workspace.id : null;
  var list = paneList();
  for (var j = 0; j < list.length; j++) {
    if (selected && list[j].workspaceId === selected) return list[j];
  }
  return bar;
}

tenon.intents.handle("dev.tenon.git.refresh.v1", async function (_, call) {
  var st = await commandTarget(call);
  await refresh(st, call);
  if (st !== bar) await refresh(bar, call);
  return {};
});

tenon.intents.handle("dev.tenon.git.switch-branch.v1", async function (_, call) {
  await switchBranch(await commandTarget(call), call);
  return {};
});

tenon.intents.handle("dev.tenon.git.fetch.v1", async function (_, call) {
  await op(await commandTarget(call), ["fetch", "--all", "--prune"], "Fetch", call);
  return {};
});

tenon.intents.handle("dev.tenon.git.pull.v1", async function (_, call) {
  await op(await commandTarget(call), ["pull", "--ff-only"], "Pull", call);
  return {};
});

tenon.intents.handle("dev.tenon.git.push.v1", async function (_, call) {
  await op(await commandTarget(call), ["push"], "Push", call);
  return {};
});

tenon.intents.handle("dev.tenon.git.stage-all.v1", async function (_, call) {
  await op(await commandTarget(call), ["add", "-A"], "Stage all", call);
  return {};
});

tenon.events.on("settings.changed", function (e) {
  if (e.key !== "repoPath") return;
  bar.repoPath = null;
  refresh(bar);
  var list = paneList();
  for (var i = 0; i < list.length; i++) {
    list[i].repoPath = null;
    refresh(list[i]);
    watchRepo(list[i]);
  }
});

// The status bar is the one surface that means "where the human is": it re-resolves on
// selection. Panel instances stay bound to the workspaces that own their panes.
tenon.events.on("workspace.selected", function () {
  bar.repoPath = null;
  bar.followedRepo = "";
  bar.focusedSlot = null;
  refresh(bar);
});

// A pane can move between workspaces; its instance keeps its panel but re-resolves the
// workspace that owns it. Owners that did not change cause no work.
tenon.events.on("workspace.changed", async function () {
  var list = paneList();
  for (var i = 0; i < list.length; i++) {
    var st = list[i];
    var owner = await owningWorkspace(st.id);
    if (!owner.id || panes[st.id] !== st) continue;
    if (owner.id === st.workspaceId && owner.path === st.workspacePath) continue;
    st.workspaceId = owner.id;
    st.workspacePath = owner.path;
    st.repoPath = null;
    st.followedRepo = "";
    st.focusedSlot = null;
    await refresh(st);
    await watchRepo(st);
  }
});

// A pane's project root moved — an agent stepped into its own worktree. Published only on
// a real root change, never on an ordinary `cd`, so this cannot restart `git status` on
// every directory the shell walks through.
tenon.events.on("pane.cwd-changed", function (event) {
  var slot = event.slotId;
  if (!slot) return;
  if (event.projectRoot) paneRoots[slot] = event.projectRoot;
  else delete paneRoots[slot];
  if (bar.focusedSlot === slot) followRepo(bar, event.projectRoot || "");
  var list = paneList();
  for (var i = 0; i < list.length; i++) {
    if (list[i].focusedSlot === slot) followRepo(list[i], event.projectRoot || "");
  }
});

tenon.events.on("workspace.slot-focused", function (event) {
  var slot = event.slotId;
  if (!slot) return;
  bar.focusedSlot = slot;
  if (paneRoots[slot]) followRepo(bar, paneRoots[slot]);
  var list = paneList();
  for (var i = 0; i < list.length; i++) {
    var st = list[i];
    if (event.workspaceId && st.workspaceId && event.workspaceId !== st.workspaceId) {
      continue;
    }
    st.focusedSlot = slot;
    if (paneRoots[slot]) followRepo(st, paneRoots[slot]);
  }
});

tenon.events.on("workspace.slot-closed", function (event) {
  if (event.slotId) delete paneRoots[event.slotId];
});

// Re-point a panel AND its filesystem watch at the new repo in one step; without the
// re-watch the panel would show the new repo but keep reacting to writes in the old one.
function followRepo(st, root) {
  if (st.followedRepo === root) return;
  st.followedRepo = root;
  st.repoPath = null;
  refresh(st);
  watchRepo(st);
}

// The working tree also changes underneath us — a build writes, a rebase runs in another
// pane. Watch each panel's repo instead of re-running `git status` on a timer and hoping.
function debouncedRefresh(st) {
  if (st.debounceHandle !== null) tenon.timers.cancel(st.debounceHandle);
  st.debounceHandle = tenon.timers.after(400, function () {
    st.debounceHandle = null;
    refresh(st);
  });
}

async function watchRepo(st) {
  if (!st.id) return; // the status bar re-polls on the timer; only panels watch
  var repo = await resolveRepo(st);
  if (!repo || st.watchedRepo === repo || panes[st.id] !== st) return;
  if (st.watch) st.watch.cancel();
  st.watch = tenon.fs.watch(repo, { recursive: true }, function () {
    debouncedRefresh(st);
  });
  st.watchedRepo = st.watch ? repo : null;
}

// The backstop: the watchers cover working trees, this catches everything else
// (a fetch landing new upstream commits) and re-points watches after a repo change.
tenon.timers.every(15000, function () {
  refresh(bar);
  var list = paneList();
  for (var i = 0; i < list.length; i++) {
    watchRepo(list[i]);
    refresh(list[i]);
  }
});

refresh(bar);
