// clock — proves the host can call back into JS repeatedly, and that a plugin
// with ZERO permissions can still render UI and react to events (VISION §5).
//
// Try it: change the emoji or the label below while the app is running and save.
// The status bar updates within ~a quarter second, no restart.

var EMOJI = "🕐";

tenon.statusBar.set(EMOJI + " waiting for first tick…");

tenon.events.on("tick", function (event) {
  tenon.statusBar.set(EMOJI + " " + event.time + "  (tick " + event.count + ")");
});
