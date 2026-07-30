// hello-palette — a minimal plugin-owned intent provider projected into the palette.

var greeting = "hello";
var count = 0;

tenon.intents.handle("dev.tenon.hello-palette.greet.v1", function () {
  count += 1;
  tenon.log(greeting + " #" + count + " 👋");
  return {};
});

tenon.intents.handle("dev.tenon.hello-palette.reset.v1", function () {
  count = 0;
  tenon.log("counter reset");
  return {};
});

tenon.events.on("terminal.title-changed", function (event) {
  tenon.log("terminal title → " + event.title);
});

tenon.statusBar.set("palette: 2 intents");
