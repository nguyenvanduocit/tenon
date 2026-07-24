// workspace-status — proves workspace structure is free tier (VISION §5):
// zero permissions, yet it always knows how many tabs and slots exist.
// Structure is not sensitive; what's INSIDE a slot needs "terminal.read".

tenon.statusBar.set("⊞ workspace");

tenon.events.on("workspace.changed", function (e) {
  var tabs = e.tabs + (e.tabs === 1 ? " tab" : " tabs");
  var slots = e.slots + (e.slots === 1 ? " slot" : " slots");
  tenon.statusBar.set("⊞ " + tabs + " · " + slots);
});
