// git — a core plugin built ONLY on the public tenon API: process.exec + settings
// + statusBar + sidebar. Shows the branch and dirty count of the configured repo;
// point "Repository path" at a repo in Settings (⌘,).

var repoPath = tenon.settings.get("repoPath") || "~";
var tickCount = 0;

function refresh() {
  tenon.process.exec(
    "/usr/bin/git",
    ["-C", repoPath, "status", "--porcelain=v1", "--branch"],
    function (r) {
      if (!r.ok || r.status !== 0) {
        tenon.statusBar.set("⎇ no repo");
        tenon.sidebar.set({ title: "Git", items: [] });
        return;
      }
      var lines = r.stdout.split("\n");
      var branch = "?";
      var changed = [];
      for (var i = 0; i < lines.length; i++) {
        var line = lines[i];
        if (line.indexOf("## ") === 0) {
          branch = line.slice(3).split("...")[0];
        } else if (line.length > 3) {
          changed.push({
            id: line.slice(3),
            label: line.slice(0, 2).trim() + " " + line.slice(3),
            depth: 0,
            icon: "pencil",
          });
        }
      }
      tenon.statusBar.set("⎇ " + branch + (changed.length ? " ±" + changed.length : ""));
      tenon.sidebar.set({ title: "Git", items: changed.slice(0, 20) });
    }
  );
}

tenon.commands.register("refresh", "Git: Refresh", refresh);

tenon.events.on("settings.changed", function (e) {
  if (e.key === "repoPath") {
    repoPath = e.value;
    refresh();
  }
});

// Cheap freshness without a filesystem watcher: re-check twice a minute.
tenon.events.on("tick", function () {
  tickCount++;
  if (tickCount % 30 === 0) refresh();
});

refresh();
