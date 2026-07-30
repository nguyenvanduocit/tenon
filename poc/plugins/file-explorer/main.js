// file-explorer — a declarative native file tree backed only by canonical intents.
//
// Instanced (T-012 model): every pane owns an independent tree. A tree's root comes from
// the workspace that OWNS its pane — resolved through `workspace.state.v1` — so the
// globally selected workspace can change freely without touching an inactive pane's state.

var VIEW = "tree";
var PLUGIN_ID = "dev.tenon.file-explorer";
var SETTING_ROOT = "rootPath";

// instanceID (pane UUID) → this pane's tree state.
var panes = {};

// Project roots reported per pane (slot UUID → path) — a host fact shared by instances.
var paneRoots = {};

tenon.views.register(VIEW, { title: "Files", instanced: true });

function makePane(instanceID) {
  return {
    id: instanceID,
    workspaceId: null,
    workspacePath: "",
    root: "",
    expanded: {},
    selectedPath: null,
    renaming: null,
    draft: null,
    directoryPaths: {},
    renderGeneration: 0,
    // Sticky project-root following (T-030), scoped to this instance's workspace:
    // focusing a pane that has no directory of its own — this tree, a browser, a diff —
    // must leave the tree where it is rather than snapping back to the workspace.
    followedRoot: "",
    focusedSlot: null
  };
}

function paneList() {
  var ids = Object.keys(panes);
  var list = [];
  for (var i = 0; i < ids.length; i++) list.push(panes[ids[i]]);
  return list;
}

function shellPath(path) {
  return path === "~" ? "~" : "'" + path.split("'").join("'\\''") + "'";
}

function logFailure(operation, result) {
  var code = result && result.error ? result.error.code : "unknown";
  tenon.log("file-explorer: " + operation + " failed: " + code);
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

function resolveRoot(st) {
  var configured = (tenon.settings.get(SETTING_ROOT) || "").trim();
  return configured || st.followedRoot || st.workspacePath || "~";
}

var FILE_MENU = [
  { id: "open", label: "Open" },
  { id: "open-side", label: "Open to the Side" },
  { id: "open-external", label: "Open in Default App", separatorBefore: true },
  { id: "reveal", label: "Reveal in Finder" },
  { id: "copy-path", label: "Copy Path" },
  { id: "rename", label: "Rename", separatorBefore: true },
  { id: "trash", label: "Move to Trash", destructive: true }
];

var DIRECTORY_MENU = [
  { id: "open-external", label: "Open in Default App" },
  { id: "reveal", label: "Reveal in Finder" },
  { id: "copy-path", label: "Copy Path" },
  { id: "cd", label: "cd Here", separatorBefore: true },
  { id: "new-file", label: "New File…", separatorBefore: true },
  { id: "new-folder", label: "New Folder…" },
  { id: "rename", label: "Rename", separatorBefore: true },
  { id: "trash", label: "Move to Trash", destructive: true }
];

async function listDirectory(path, call) {
  var entries = [];
  var cursor = null;
  do {
    var input = { path: path, limit: 256 };
    if (cursor) input.cursor = cursor;
    var result = call
      ? await call.send("filesystem.directory.list.v1", input)
      : await tenon.intents.send("filesystem.directory.list.v1", input);
    if (!result.ok) {
      logFailure("list " + path, result);
      return null;
    }
    entries = entries.concat(result.value.entries || []);
    cursor = result.value.nextCursor;
  } while (cursor);
  return entries;
}

async function appendRows(st, directory, depth, rows, generation, call) {
  if (generation !== st.renderGeneration) return;
  st.directoryPaths[directory] = true;

  if (st.draft && st.draft.parent === directory) {
    rows.push({
      id: "draft",
      label: "",
      depth: depth,
      icon: st.draft.isDirectory ? "folder.fill" : "doc.text",
      editing: true,
      placeholder: st.draft.isDirectory ? "Folder name" : "File name"
    });
  }

  var entries = await listDirectory(directory, call);
  if (!entries || generation !== st.renderGeneration) return;
  var directories = entries.filter(function (entry) {
    return entry.isDirectory && entry.name !== ".git";
  });
  var files = entries.filter(function (entry) {
    return !entry.isDirectory;
  });
  var all = directories.concat(files);

  for (var i = 0; i < all.length; i++) {
    var entry = all[i];
    var path = tenon.path.join(directory, entry.name);
    var row = {
      id: path,
      label: entry.name,
      depth: depth,
      path: path,
      icon: entry.isDirectory ? "folder.fill" : "doc.text",
      menu: entry.isDirectory ? DIRECTORY_MENU : FILE_MENU
    };
    if (st.renaming === path) {
      row.editing = true;
      row.placeholder = "Name";
    }
    if (entry.isDirectory) {
      st.directoryPaths[path] = true;
      row.expanded = !!st.expanded[path];
    } else if (path === st.selectedPath) {
      row.selected = true;
    }
    rows.push(row);
    if (entry.isDirectory && st.expanded[path]) {
      await appendRows(st, path, depth + 1, rows, generation, call);
    }
  }
}

async function render(st, call) {
  if (!st || !st.root) return;
  var generation = ++st.renderGeneration;
  var rows = [];
  st.directoryPaths = {};
  await appendRows(st, st.root, 0, rows, generation, call);
  if (generation !== st.renderGeneration) return;
  if (panes[st.id] !== st) return;
  tenon.views.set(VIEW, {
    title: tenon.path.basename(st.root),
    subtitle: st.root,
    actions: [
      {
        id: "reveal-root",
        icon: "arrow.up.forward.app",
        tooltip: "Reveal in Finder"
      }
    ],
    items: rows
  }, st.id);
}

async function openFile(st, path, forceSplit) {
  st.selectedPath = path;
  var result;
  if (forceSplit) {
    result = await tenon.intents.send("workspace.pane.split.v1", {
      axis: "horizontal"
    });
    if (result.ok) {
      result = await tenon.intents.send("workspace.pane.content.set.v1", {
        content: { kind: "file", path: path }
      });
    }
  } else {
    result = await tenon.intents.send("workspace.content.open.v1", {
      content: { kind: "file", path: path }
    });
  }
  if (!result.ok) logFailure("open " + path, result);
  await render(st);
}

async function runMenu(st, path, action) {
  if (action === "open") return openFile(st, path, false);
  if (action === "open-side") return openFile(st, path, true);

  if (action === "open-external") {
    var opened = await tenon.intents.send("file.open.v1", { path: path });
    if (!opened.ok) logFailure("open externally " + path, opened);
    return;
  }
  if (action === "reveal") {
    var revealed = await tenon.intents.send("file.reveal.v1", { path: path });
    if (!revealed.ok) logFailure("reveal " + path, revealed);
    return;
  }
  if (action === "copy-path") {
    var copied = await tenon.intents.send("clipboard.write.v1", { text: path });
    if (!copied.ok) logFailure("copy path", copied);
    return;
  }
  if (action === "cd") {
    var written = await tenon.intents.send("terminal.write.v1", {
      text: "cd " + shellPath(path) + "\n"
    });
    if (!written.ok) logFailure("cd " + path, written);
    return;
  }

  if (action === "new-file" || action === "new-folder") {
    st.renaming = null;
    st.draft = { parent: path, isDirectory: action === "new-folder" };
    st.expanded[path] = true;
    return render(st);
  }
  if (action === "rename") {
    st.draft = null;
    st.renaming = path;
    return render(st);
  }
  if (action === "trash") {
    var trashed = await tenon.intents.send(
      "filesystem.path.trash.v1",
      { path: path }
    );
    if (!trashed.ok) {
      logFailure("trash " + path, trashed);
    } else {
      delete st.expanded[path];
      if (st.selectedPath === path) st.selectedPath = null;
    }
    return render(st);
  }
  tenon.log("file-explorer: unknown menu action " + action);
}

async function select(id, action, instanceID) {
  var st = panes[instanceID];
  if (!st) return;
  if (id === "reveal-root") {
    var result = await tenon.intents.send("file.reveal.v1", { path: st.root });
    if (!result.ok) logFailure("reveal " + st.root, result);
    return;
  }
  if (id === "draft") return;
  if (action) return runMenu(st, id, action);

  if (st.directoryPaths[id]) {
    st.expanded[id] = !st.expanded[id];
    await render(st);
  } else {
    await openFile(st, id, false);
  }
}

async function submit(id, text, instanceID) {
  var st = panes[instanceID];
  if (!st) return;
  var name = (text || "").trim();
  if (id === "draft") {
    var pending = st.draft;
    st.draft = null;
    if (pending && name) {
      var target = tenon.path.join(pending.parent, name);
      var created = pending.isDirectory
        ? await tenon.intents.send(
          "filesystem.directory.create.v1",
          { path: target }
        )
        : await tenon.intents.send(
          "filesystem.file.create.v1",
          { path: target }
        );
      if (!created.ok) {
        logFailure("create " + target, created);
      } else if (!pending.isDirectory) {
        await openFile(st, target, false);
        return;
      }
    }
    await render(st);
    return;
  }

  var path = st.renaming;
  st.renaming = null;
  if (path && name && name !== tenon.path.basename(path)) {
    var moved = await tenon.intents.send("filesystem.path.move.v1", {
      sourcePath: path,
      destinationPath: tenon.path.join(tenon.path.dirname(path), name)
    });
    if (!moved.ok) {
      logFailure("rename " + path, moved);
    } else {
      var destination = moved.value.path;
      if (st.expanded[path]) {
        delete st.expanded[path];
        st.expanded[destination] = true;
      }
      if (st.selectedPath === path) st.selectedPath = destination;
    }
  }
  await render(st);
}

tenon.views.onSelect(VIEW, select);
tenon.views.onSubmit(VIEW, submit);

tenon.views.onOpen(VIEW, async function (instanceID) {
  var st = makePane(instanceID);
  panes[instanceID] = st;
  var owner = await owningWorkspace(instanceID);
  if (panes[instanceID] !== st) return;
  st.workspaceId = owner.id;
  st.workspacePath = owner.path;
  st.root = resolveRoot(st);
  await render(st);
});

tenon.views.onClose(VIEW, function (instanceID) {
  delete panes[instanceID];
});

// Commands arrive without a pane; they mean the tree the human is looking at — the
// instance owned by the selected workspace, or any instance when none is there.
async function commandTarget(call) {
  var result = call
    ? await call.send("workspace.state.v1", { limit: 256 })
    : await tenon.intents.send("workspace.state.v1", { limit: 256 });
  var selected = null;
  if (result.ok) {
    var nodes = result.value.nodes || [];
    for (var i = 0; i < nodes.length; i++) {
      if (nodes[i].kind === "workspace" && nodes[i].selected) selected = nodes[i].id;
    }
  }
  var list = paneList();
  for (var j = 0; j < list.length; j++) {
    if (selected && list[j].workspaceId === selected) return list[j];
  }
  return list.length ? list[0] : null;
}

tenon.intents.handle("dev.tenon.file-explorer.open.v1", async function (_, call) {
  var result = await call.send("workspace.tab.create.v1", {
    content: { kind: "plugin", pluginID: PLUGIN_ID, viewID: VIEW }
  });
  if (!result.ok) throw new Error(result.error.code);
  return {};
});

tenon.intents.handle("dev.tenon.file-explorer.cd-root.v1", async function (_, call) {
  var st = await commandTarget(call);
  if (!st) return {};
  var result = await call.send("terminal.write.v1", {
    text: "cd " + shellPath(st.root) + "\n"
  });
  if (!result.ok) throw new Error(result.error.code);
  return {};
});

tenon.intents.handle("dev.tenon.file-explorer.reveal-root.v1", async function (_, call) {
  var st = await commandTarget(call);
  if (!st) return {};
  var result = await call.send("file.reveal.v1", { path: st.root });
  if (!result.ok) throw new Error(result.error.code);
  return {};
});

tenon.intents.handle("dev.tenon.file-explorer.refresh.v1", async function (_, call) {
  var list = paneList();
  for (var i = 0; i < list.length; i++) await render(list[i], call);
  return {};
});

tenon.intents.handle("dev.tenon.file-explorer.collapse-all.v1", async function (_, call) {
  var list = paneList();
  for (var i = 0; i < list.length; i++) {
    list[i].expanded = {};
    await render(list[i], call);
  }
  return {};
});

async function retarget(st, path) {
  if (path === st.root) return;
  st.root = path;
  st.expanded = {};
  st.selectedPath = null;
  st.renaming = null;
  st.draft = null;
  await render(st);
}

tenon.events.on("settings.changed", async function (event) {
  if (event.key !== SETTING_ROOT) return;
  var list = paneList();
  for (var i = 0; i < list.length; i++) {
    await retarget(list[i], resolveRoot(list[i]));
  }
});

// A pane can move between workspaces; its instance keeps its UI state but re-resolves the
// workspace that owns it. Owners that did not change cause no work and no render.
tenon.events.on("workspace.changed", async function () {
  var list = paneList();
  for (var i = 0; i < list.length; i++) {
    var st = list[i];
    var owner = await owningWorkspace(st.id);
    if (!owner.id || panes[st.id] !== st) continue;
    if (owner.id === st.workspaceId && owner.path === st.workspacePath) continue;
    st.workspaceId = owner.id;
    st.workspacePath = owner.path;
    st.followedRoot = "";
    st.focusedSlot = null;
    await retarget(st, resolveRoot(st));
  }
});

// A pane's project root moved — typically an agent stepping into its own `git worktree`.
// The host publishes this only when the resolved ROOT actually changed, never on an
// ordinary `cd` inside one repository, so following it cannot thrash the tree.
tenon.events.on("pane.cwd-changed", async function (event) {
  var slot = event.slotId;
  if (!slot) return;
  if (event.projectRoot) paneRoots[slot] = event.projectRoot;
  else delete paneRoots[slot];
  var list = paneList();
  for (var i = 0; i < list.length; i++) {
    var st = list[i];
    if (st.focusedSlot !== slot) continue;
    st.followedRoot = event.projectRoot || "";
    await retarget(st, resolveRoot(st));
  }
});

// Follow the pane the human is actually working in — within each tree's own workspace.
tenon.events.on("workspace.slot-focused", async function (event) {
  var slot = event.slotId;
  if (!slot) return;
  var list = paneList();
  for (var i = 0; i < list.length; i++) {
    var st = list[i];
    if (event.workspaceId && st.workspaceId && event.workspaceId !== st.workspaceId) {
      continue;
    }
    st.focusedSlot = slot;
    if (!paneRoots[slot]) continue;
    st.followedRoot = paneRoots[slot];
    await retarget(st, resolveRoot(st));
  }
});

tenon.events.on("workspace.slot-closed", function (event) {
  if (event.slotId) delete paneRoots[event.slotId];
});
