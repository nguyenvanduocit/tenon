// hello-palette — proves command registration + invocation from the host UI.
//
// Its manifest declares "terminal.read" because the title listener below reads
// terminal state — remove it and the subscription is blocked with a ⛔ in the log.
// It also deliberately declares "network.fetch", which this host version does
// not know about: watch the log for the unknown-permission warning.

var greeting = "hello";
var count = 0;

tenon.commands.register("greet", "Say Hello", function () {
  count = count + 1;
  tenon.log(greeting + " #" + count + " 👋");
});

tenon.commands.register("reset", "Reset Greeting Counter", function () {
  count = 0;
  tenon.log("counter reset");
});

tenon.events.on("terminal.title-changed", function (event) {
  tenon.log("terminal title → " + event.title);
});

tenon.statusBar.set("palette: 2 commands");
