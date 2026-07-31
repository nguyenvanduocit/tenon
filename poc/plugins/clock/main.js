// clock — proves the host can call back into JS repeatedly, and that a plugin
// with ZERO permissions can still render UI and react to events (VISION §5).
// Also the first consumer of manifest automation schedules (T-046): the manifest
// declares { "id": "tick", "every": "1m" }, and the host fires the owner-scoped
// automation.fired event at this plugin each minute.
//
// Try it: change the emoji or the label below while the app is running and save.
// The status bar updates within ~a quarter second, no restart.

var EMOJI = "🕐";

function show() {
  var now = new Date();
  var hh = String(now.getHours()).padStart(2, "0");
  var mm = String(now.getMinutes()).padStart(2, "0");
  tenon.statusBar.set(EMOJI + " " + hh + ":" + mm);
}

show();

tenon.events.on("automation.fired", function () {
  show();
});
