// file-explorer — a declarative native file tree backed only by canonical intents.

var VIEW = "tree";
var PLUGIN_ID = "dev.tenon.file-explorer";
var SETTING_ROOT = "rootPath";

var root = "";
var expanded = {};
var selectedPath = null;
var renaming = null;
var draft = null;
var directoryPaths = {};
var renderGeneration = 0;

tenon.views.register(VIEW, { title: "Files" });

function shellPath(path) {
  return path === "~" ? "~" : "'" + path.split("'").join("'\\''") + "'";
}

function logFailure(operation, result) {
  var code = result && result.error ? result.error.code : "unknown";
  tenon.log("file-explorer: " + operation + " failed: " + code);
}

async function workspaceRoot() {
  var result = await tenon.intents.send("workspace.state.v1", { limit: 256 });
  if (!result.ok) return "~";
  var nodes = result.value.nodes || [];
  for (var i = 0; i < nodes.length; i++) {
    if (nodes[i].kind === "workspace" && nodes[i].selected) {
      return nodes[i].path || "~";
    }
  }
  for (var j = 0; j < nodes.length; j++) {
    if (nodes[j].kind === "workspace") return nodes[j].path || "~";
  }
  return "~";
}

// The project root of each pane that has one, as reported by the host, plus the one we are
// currently following. `followedRoot` is deliberately sticky: focusing a pane that has no
// directory of its own — this tree, a browser, a diff — must leave the tree where it is
// rather than snapping back to the workspace.
var paneRoots = {};
var focusedSlot = null;
var followedRoot = "";

async function resolveRoot() {
  var configured = (tenon.settings.get(SETTING_ROOT) || "").trim();
  return configured || followedRoot || await workspaceRoot();
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

async function appendRows(directory, depth, rows, generation, call) {
  if (generation !== renderGeneration) return;
  directoryPaths[directory] = true;

  if (draft && draft.parent === directory) {
    rows.push({
      id: "draft",
      label: "",
      depth: depth,
      icon: draft.isDirectory ? "folder.fill" : "doc.text",
      editing: true,
      placeholder: draft.isDirectory ? "Folder name" : "File name"
    });
  }

  var entries = await listDirectory(directory, call);
  if (!entries || generation !== renderGeneration) return;
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
    if (renaming === path) {
      row.editing = true;
      row.placeholder = "Name";
    }
    if (entry.isDirectory) {
      directoryPaths[path] = true;
      row.expanded = !!expanded[path];
    } else if (path === selectedPath) {
      row.selected = true;
    }
    rows.push(row);
    if (entry.isDirectory && expanded[path]) {
      await appendRows(path, depth + 1, rows, generation, call);
    }
  }
}

async function render(call) {
  if (!root) return;
  var generation = ++renderGeneration;
  var rows = [];
  directoryPaths = {};
  await appendRows(root, 0, rows, generation, call);
  if (generation !== renderGeneration) return;
  tenon.views.set(VIEW, {
    title: tenon.path.basename(root),
    subtitle: root,
    actions: [
      {
        id: "reveal-root",
        icon: "arrow.up.forward.app",
        tooltip: "Reveal in Finder"
      }
    ],
    items: rows
  });
}

async function openFile(path, forceSplit) {
  selectedPath = path;
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
  await render();
}

async function runMenu(path, action) {
  if (action === "open") return openFile(path, false);
  if (action === "open-side") return openFile(path, true);

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
    renaming = null;
    draft = { parent: path, isDirectory: action === "new-folder" };
    expanded[path] = true;
    return render();
  }
  if (action === "rename") {
    draft = null;
    renaming = path;
    return render();
  }
  if (action === "trash") {
    var trashed = await tenon.intents.send(
      "filesystem.path.trash.v1",
      { path: path }
    );
    if (!trashed.ok) {
      logFailure("trash " + path, trashed);
    } else {
      delete expanded[path];
      if (selectedPath === path) selectedPath = null;
    }
    return render();
  }
  tenon.log("file-explorer: unknown menu action " + action);
}

async function select(id, action) {
  if (id === "reveal-root") {
    var result = await tenon.intents.send("file.reveal.v1", { path: root });
    if (!result.ok) logFailure("reveal " + root, result);
    return;
  }
  if (id === "draft") return;
  if (action) return runMenu(id, action);

  if (directoryPaths[id]) {
    expanded[id] = !expanded[id];
    await render();
  } else {
    await openFile(id, false);
  }
}

async function submit(id, text) {
  var name = (text || "").trim();
  if (id === "draft") {
    var pending = draft;
    draft = null;
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
        await openFile(target, false);
        return;
      }
    }
    await render();
    return;
  }

  var path = renaming;
  renaming = null;
  if (path && name && name !== tenon.path.basename(path)) {
    var moved = await tenon.intents.send("filesystem.path.move.v1", {
      sourcePath: path,
      destinationPath: tenon.path.join(tenon.path.dirname(path), name)
    });
    if (!moved.ok) {
      logFailure("rename " + path, moved);
    } else {
      var destination = moved.value.path;
      if (expanded[path]) {
        delete expanded[path];
        expanded[destination] = true;
      }
      if (selectedPath === path) selectedPath = destination;
    }
  }
  await render();
}

tenon.views.onSelect(VIEW, select);
tenon.views.onSubmit(VIEW, submit);

tenon.intents.handle("dev.tenon.file-explorer.open.v1", async function (_, call) {
  var result = await call.send("workspace.tab.create.v1", {
    content: { kind: "plugin", pluginID: PLUGIN_ID, viewID: VIEW }
  });
  if (!result.ok) throw new Error(result.error.code);
  return {};
});

tenon.intents.handle("dev.tenon.file-explorer.cd-root.v1", async function (_, call) {
  var result = await call.send("terminal.write.v1", {
    text: "cd " + shellPath(root) + "\n"
  });
  if (!result.ok) throw new Error(result.error.code);
  return {};
});

tenon.intents.handle("dev.tenon.file-explorer.reveal-root.v1", async function (_, call) {
  var result = await call.send("file.reveal.v1", { path: root });
  if (!result.ok) throw new Error(result.error.code);
  return {};
});

tenon.intents.handle("dev.tenon.file-explorer.refresh.v1", async function (_, call) {
  await render(call);
  return {};
});

tenon.intents.handle("dev.tenon.file-explorer.collapse-all.v1", async function (_, call) {
  expanded = {};
  await render(call);
  return {};
});

async function retarget(path) {
  if (path === root) return;
  root = path;
  expanded = {};
  selectedPath = null;
  renaming = null;
  draft = null;
  await render();
}

tenon.events.on("settings.changed", async function (event) {
  if (event.key === SETTING_ROOT) await retarget(await resolveRoot());
});

tenon.events.on("workspace.selected", async function () {
  await retarget(await resolveRoot());
});

// A pane's project root moved — typically an agent stepping into its own `git worktree`.
// The host publishes this only when the resolved ROOT actually changed, never on an
// ordinary `cd` inside one repository, so following it cannot thrash the tree.
tenon.events.on("pane.cwd-changed", async function (event) {
  var slot = event.slotId;
  if (!slot) return;
  if (event.projectRoot) paneRoots[slot] = event.projectRoot;
  else delete paneRoots[slot];
  if (slot !== focusedSlot) return;
  followedRoot = event.projectRoot || "";
  await retarget(await resolveRoot());
});

// Follow the pane the human is actually working in.
tenon.events.on("workspace.slot-focused", async function (event) {
  var slot = event.slotId;
  if (!slot) return;
  focusedSlot = slot;
  if (!paneRoots[slot]) return;
  followedRoot = paneRoots[slot];
  await retarget(await resolveRoot());
});

tenon.events.on("workspace.slot-closed", function (event) {
  if (event.slotId) delete paneRoots[event.slotId];
});

(async function start() {
  root = await resolveRoot();
  await render();
})();
