// file-explorer — a core plugin built ONLY on the public tenon API (VISION: no private
// API, ever). fs.readDir + settings + terminal.write, surfaced two ways on the same
// free-tier declarative rows: a sidebar section AND a fillable slot view (tenon.views).
//
// Directories first then files, dotfiles hidden; selecting a directory expands/collapses
// it in place; selecting a file logs its path.

var rootPath = tenon.settings.get("rootPath") || "~";
var expanded = {}; // absolute path -> true while expanded

tenon.views.register("tree", { title: "Files" });

function shellPath(path) {
  // Leave "~" bare so the shell expands it; quote everything else.
  return path === "~" ? "~" : "'" + path.split("'").join("'\\''") + "'";
}

function appendRows(path, depth, rows) {
  var result = tenon.fs.readDir(path);
  if (!result.ok) {
    tenon.log("file-explorer: " + result.error);
    return;
  }
  var dirs = [];
  var files = [];
  for (var i = 0; i < result.entries.length; i++) {
    var entry = result.entries[i];
    if (entry.name.indexOf(".") === 0) continue;
    (entry.isDirectory ? dirs : files).push(entry);
  }
  var all = dirs.concat(files);
  for (var j = 0; j < all.length; j++) {
    var e = all[j];
    var full = path + "/" + e.name;
    rows.push({ id: full, label: e.name, depth: depth, icon: e.isDirectory ? "folder" : "doc.text" });
    if (e.isDirectory && expanded[full]) {
      appendRows(full, depth + 1, rows);
    }
  }
}

function render() {
  var rows = [];
  appendRows(rootPath, 0, rows);
  // Same tree, two surfaces — both permission-free UI contribution.
  tenon.sidebar.set({ title: "Files", items: rows });
  tenon.views.set("tree", { title: "Files", items: rows });
}

function select(id) {
  var probe = tenon.fs.readDir(id);
  if (probe.ok) {
    expanded[id] = !expanded[id];
    render();
  } else {
    tenon.log("file-explorer: " + id);
  }
}

tenon.sidebar.onSelect(select);
tenon.views.onSelect("tree", select);

tenon.commands.register("cd-root", "Files: cd to root", function () {
  tenon.terminal.write("cd " + shellPath(rootPath) + "\n");
});

tenon.commands.register("refresh", "Files: Refresh", render);

tenon.events.on("settings.changed", function (e) {
  if (e.key === "rootPath") {
    rootPath = e.value;
    expanded = {};
    render();
  }
});

render();
