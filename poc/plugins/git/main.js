// git — a full source-control panel built ONLY on the public tenon API:
// process/filesystem resources + settings + status/view contributions + canonical intents.
// It parses `git status --porcelain=v2` into staged / changed / conflict sections,
// stages, unstages, discards, commits, and syncs — and opens each file's diff in
// the host's default diff view in a new tab,
// never carved inline.
//
// Point "Repository path" at a repo in Settings (⌘,), or leave it on "~" and the
// plugin uses the repo of the workspace you are in.

var LOG_SEP = String.fromCharCode(31); // field separator for `git log --pretty`, not for actions
var repoPath = null;
var model = emptyModel();
var commitMessage = "";

function emptyModel() {
  return {
    isRepo: false, branch: "?", ahead: 0, behind: 0, upstream: null,
    hasHead: true, staged: [], changed: [], merge: [], recent: [],
  };
}

// --- repo resolution -------------------------------------------------------

function settingRepo() {
  var s = (tenon.settings.get("repoPath") || "").trim();
  return s && s !== "~" ? s : null;
}

/// The workspace the user is currently in — where "the repo" means, when no path is set.
async function workspacePath(call) {
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

// An explicit "Repository path" setting always wins; otherwise discover the repo that
// contains the current workspace. No generation guard needed any more: the setting is
// re-read on every call, so a slow discovery can no longer answer for a stale path.
// The project root of each pane that has one, plus the one we are currently following.
// Sticky for the same reason the file tree's is: focusing this panel, a browser or a diff
// must not drop the panel back to the workspace repo.
var paneRoots = {};
var focusedSlot = null;
var followedRepo = "";

async function resolveRepo(call) {
  var explicit = settingRepo();
  if (explicit) { repoPath = explicit; return repoPath; }
  // A pane's project root outranks the cached discovery: the agent moved, so do we.
  if (followedRepo) { repoPath = followedRepo; return repoPath; }
  if (repoPath) return repoPath;
  var currentWorkspace = await workspacePath(call);
  var root = await exec(
    "/usr/bin/git",
    ["rev-parse", "--show-toplevel"],
    currentWorkspace || "/",
    call
  );
  if (settingRepo()) { repoPath = settingRepo(); return repoPath; }
  if (root.ok && root.status === 0) repoPath = (root.stdout || "").trim();
  return repoPath;
}

async function git(args, call) {
  var repo = await resolveRepo(call);
  if (!repo) return { ok: false, status: 1, stdout: "", stderr: "no repository" };
  return await exec("/usr/bin/git", args, repo, call);
}

// Runs a mutating command, reports the first error line as a toast, then refreshes.
async function op(args, label, call) {
  var r = await git(args, call);
  if (!r.ok || r.status !== 0) {
    var msg = ((r.stderr || r.error || "") + "").trim().split("\n")[0];
    var input = {
      message: (label || "Git") + " failed" + (msg ? ": " + msg : ""),
      kind: "error"
    };
    if (call) await call.send("ui.toast.v1", input);
    else await tenon.intents.send("ui.toast.v1", input);
  }
  await refresh(call);
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

async function refresh(call) {
  var repo = await resolveRepo(call);
  if (!repo) {
    model = emptyModel();
    tenon.statusBar.set("⎇ no repo");
    render();
    return;
  }
  var status = await git(
    ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"],
    call
  );
  if (!status.ok || status.status !== 0) {
    model = emptyModel();
    tenon.statusBar.set("⎇ no repo");
    render();
    return;
  }
  var next = parseStatus(status.stdout);
  var log = await git(
    ["log", "-n", "5", "--pretty=%h" + LOG_SEP + "%s"],
    call
  );
  if (log.ok && log.status === 0) next.recent = parseLog(log.stdout);
  model = next;
  updateStatusBar();
  render();
}

function updateStatusBar() {
  var count = model.staged.length + model.changed.length + model.merge.length;
  var sync = "";
  if (model.ahead) sync += " ↑" + model.ahead;
  if (model.behind) sync += " ↓" + model.behind;
  tenon.statusBar.set("⎇ " + model.branch + (count ? " ±" + count : "") + sync);
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

function sectionCard(title, entries, section, bulkLabel, bulkAction) {
  var header = [
    { type: "text", value: title + " (" + entries.length + ")", weight: "semibold", color: "text" },
    { type: "spacer" },
  ];
  if (bulkLabel) header.push(btn(bulkLabel, bulkAction));
  var children = [{ type: "hstack", spacing: 6, children: header }];
  entries.forEach(function (e) { children.push(fileRow(e, section)); });
  return { type: "card", children: children };
}

function render() {
  var children = [];

  // Branch + sync controls.
  var branchRow = [btn(model.branch, { do: "switchBranch" }, "plain")];
  if (model.ahead || model.behind) {
    branchRow.push({ type: "badge", value: (model.ahead ? "↑" + model.ahead : "") + (model.behind ? " ↓" + model.behind : ""), tint: "amber" });
  }
  branchRow.push({ type: "spacer" });
  branchRow.push(btn("Fetch", { do: "fetch" }));
  branchRow.push(btn("Pull", { do: "pull" }));
  branchRow.push(btn("Push", { do: "push" }));
  children.push({ type: "card", children: [
    { type: "hstack", spacing: 8, children: branchRow },
    { type: "hstack", spacing: 8, children: [btn("Stash", { do: "stash" }), btn("Pop stash", { do: "stashPop" }), { type: "spacer" }] },
    { type: "field", label: "New branch", children: [{ type: "textfield", value: "", placeholder: "branch name", action: { do: "newBranch" } }] },
  ] });

  // Commit box.
  children.push({ type: "card", children: [
    { type: "field", label: "Commit message", children: [{ type: "textfield", value: commitMessage, placeholder: "Message…", action: { do: "commitMsg" } }] },
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

  tenon.views.set("git", { title: "Git", body: { type: "vstack", spacing: 10, children: children } });
}

// --- actions ---------------------------------------------------------------

function findEntry(section, path) {
  var list = section === "staged" ? model.staged : section === "merge" ? model.merge : model.changed;
  for (var i = 0; i < list.length; i++) if (list[i].path === path) return list[i];
  return null;
}

async function openDiff(section, path) {
  var e = findEntry(section, path);
  var untracked = e ? (e.staged === "?" || e.unstaged === "?") : false;
  var res = await tenon.intents.send("workspace.content.open.v1", {
    content: {
      kind: "diff",
      source: "git",
      repositoryPath: repoPath,
      path: path,
      staged: section === "staged",
      untracked: untracked,
      originalPath: e ? (e.origPath || null) : null,
      title: shortName(path) + (section === "staged" ? " (staged)" : "")
    }
  });
  if (!res.ok) tenon.log("open diff failed: " + res.error.code);
}

async function discard(path) {
  var e = findEntry("changed", path);
  var result = await tenon.intents.send("ui.confirm.v1", {
    title: "Discard changes to " + shortName(path) + "? This cannot be undone.",
    destructive: true
  });
  if (!result.ok || !result.value.confirmed) return;
  if (e && (e.staged === "?" || e.unstaged === "?")) {
    await op(["clean", "-f", "--", path], "Discard untracked " + shortName(path));
  } else {
    await op(["restore", "--worktree", "--", path], "Discard " + shortName(path));
  }
}

async function discardAll() {
  var result = await tenon.intents.send("ui.confirm.v1", {
    title: "Discard all " + model.changed.length + " changed files? This cannot be undone.",
    destructive: true
  });
  if (result.ok && result.value.confirmed) {
    await op(["restore", "--worktree", "--", "."], "Discard tracked changes");
  }
}

async function doCommit(includeAll) {
  var msg = (commitMessage || "").trim();
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
    var staged = await git(["add", "-A"]);
    if (!staged.ok || staged.status !== 0) {
      await tenon.intents.send("ui.toast.v1", {
        message: "Stage all failed",
        kind: "error"
      });
      return;
    }
  }
  commitMessage = "";
  await op(["commit", "-m", msg], "Commit");
}

// The branch list, in the host's own pick list — the plugin describes it, the shell draws it.
async function switchBranch(call) {
  var r = await git(["branch", "--format=%(refname:short)"], call);
  var names = (r.stdout || "").split("\n").filter(Boolean);
  if (!names.length) {
    var toastInput = {
      message: "No branches found",
      kind: "warning"
    };
    if (call) await call.send("ui.toast.v1", toastInput);
    else await tenon.intents.send("ui.toast.v1", toastInput);
    return;
  }
  var pickInput = {
    items: names.map(function (name) {
      return {
        id: name,
        label: name,
        icon: "arrow.triangle.branch",
        detail: name === model.branch ? "current" : ""
      };
    }),
    placeholder: "Switch branch"
  };
  var choice = call
    ? await call.send("ui.pick.v1", pickInput)
    : await tenon.intents.send("ui.pick.v1", pickInput);
  var selected = choice.ok ? choice.value.selectedID : null;
  if (selected && selected !== model.branch) {
    await op(["switch", selected], "Switch to " + selected, call);
  }
}

tenon.views.register("git", { title: "Git" });

// The action arrives as the object the view declared — no packing, no splitting.
tenon.views.onSelect("git", async function (action, value) {
  switch (action.do) {
    case "open": await openDiff(action.section, action.path); break;
    case "stage": await op(["add", "--", action.path], "Stage"); break;
    case "unstage": await op(model.hasHead ? ["restore", "--staged", "--", action.path] : ["rm", "--cached", "--", action.path], "Unstage"); break;
    case "discard": await discard(action.path); break;
    case "stageAll": await op(["add", "-A"], "Stage all"); break;
    case "unstageAll": await op(model.hasHead ? ["restore", "--staged", "--", "."] : ["rm", "--cached", "-r", "--", "."], "Unstage all"); break;
    case "discardAll": await discardAll(); break;
    case "commit": await doCommit(false); break;
    case "commitAll": await doCommit(true); break;
    case "commitMsg": commitMessage = value || ""; break;
    case "switchBranch": await switchBranch(); break;
    case "fetch": await op(["fetch", "--all", "--prune"], "Fetch"); break;
    case "pull": await op(["pull", "--ff-only"], "Pull"); break;
    case "push": await op(["push"], "Push"); break;
    case "stash": await op(["stash", "push", "--include-untracked"], "Stash"); break;
    case "stashPop": await op(["stash", "pop"], "Pop stash"); break;
    case "newBranch":
      if (value && value.trim()) {
        await op(["switch", "-c", value.trim()], "Create branch " + value.trim());
      }
      break;
  }
});

// --- commands + lifecycle --------------------------------------------------

tenon.intents.handle("dev.tenon.git.refresh.v1", async function (_, call) {
  await refresh(call);
  return {};
});

tenon.intents.handle("dev.tenon.git.switch-branch.v1", async function (_, call) {
  await switchBranch(call);
  return {};
});

tenon.intents.handle("dev.tenon.git.fetch.v1", async function (_, call) {
  await op(["fetch", "--all", "--prune"], "Fetch", call);
  return {};
});

tenon.intents.handle("dev.tenon.git.pull.v1", async function (_, call) {
  await op(["pull", "--ff-only"], "Pull", call);
  return {};
});

tenon.intents.handle("dev.tenon.git.push.v1", async function (_, call) {
  await op(["push"], "Push", call);
  return {};
});

tenon.intents.handle("dev.tenon.git.stage-all.v1", async function (_, call) {
  await op(["add", "-A"], "Stage all", call);
  return {};
});

tenon.events.on("settings.changed", function (e) {
  if (e.key === "repoPath") { repoPath = null; refresh(); }
});

// Switching workspace means a different repo: re-resolve instead of showing the old one
// until the next tick.
tenon.events.on("workspace.selected", function () { repoPath = null; refresh(); });

// A pane's project root moved — an agent stepped into its own worktree. Published only on
// a real root change, never on an ordinary `cd`, so this cannot restart `git status` on
// every directory the shell walks through.
tenon.events.on("pane.cwd-changed", function (event) {
  var slot = event.slotId;
  if (!slot) return;
  if (event.projectRoot) paneRoots[slot] = event.projectRoot;
  else delete paneRoots[slot];
  if (slot !== focusedSlot) return;
  followRepo(event.projectRoot || "");
});

tenon.events.on("workspace.slot-focused", function (event) {
  var slot = event.slotId;
  if (!slot) return;
  focusedSlot = slot;
  if (!paneRoots[slot]) return;
  followRepo(paneRoots[slot]);
});

tenon.events.on("workspace.slot-closed", function (event) {
  if (event.slotId) delete paneRoots[event.slotId];
});

// Re-point the panel AND its filesystem watch at the new repo in one step; without the
// re-watch the panel would show the new repo but keep reacting to writes in the old one.
function followRepo(root) {
  if (followedRepo === root) return;
  followedRepo = root;
  repoPath = null;
  refresh();
  watchRepo();
}

// The working tree also changes underneath us — a build writes, a rebase runs in another
// pane. Watch the repo instead of re-running `git status` on a timer and hoping.
var debounceHandle = null;
function debouncedRefresh() {
  if (debounceHandle !== null) tenon.timers.cancel(debounceHandle);
  debounceHandle = tenon.timers.after(400, function () {
    debounceHandle = null;
    refresh();
  });
}
var repoWatch = null;
var watchedRepo = null;

async function watchRepo() {
  var repo = await resolveRepo();
  if (!repo || watchedRepo === repo) return;
  if (repoWatch) repoWatch.cancel();
  repoWatch = tenon.fs.watch(repo, { recursive: true }, debouncedRefresh);
  watchedRepo = repoWatch ? repo : null;
}

// The backstop: the watcher covers the working tree, this catches everything else
// (a fetch landing new upstream commits) and re-points the watch after a repo change.
tenon.timers.every(15000, function () { watchRepo(); refresh(); });

render();
refresh();
watchRepo();
