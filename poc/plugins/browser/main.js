// Browser — an instance-aware plugin. Each pane owns one browser surface whose
// identifier is the pane instance ID supplied by the host.

var VIEW = "browser";
var PLUGIN_ID = "dev.tenon.browser";
var home = tenon.settings.get("homeURL") || "https://duckduckgo.com";
var panes = {};

function render(instanceID) {
  var pane = panes[instanceID];
  if (!pane) return;
  tenon.views.set(VIEW, {
    body: {
      type: "vstack",
      spacing: 0,
      children: [
        { type: "browserBar", url: pane.address },
        { type: "webview", surfaceID: instanceID }
      ]
    }
  }, instanceID);
}

function resolve(input) {
  var value = (input || "").trim();
  if (!value) return null;
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(value)) return value;
  if (/^[^\s]+\.[^\s]{2,}(\/.*)?$/.test(value)) return "https://" + value;
  var engine = tenon.settings.get("searchEngine") || "https://duckduckgo.com/?q=";
  return engine + encodeURIComponent(value);
}

async function navigate(instanceID, input) {
  var url = resolve(input);
  if (!url || !panes[instanceID]) return;
  var result = await tenon.intents.send(
    "browser.surface.load.v1",
    { surfaceID: instanceID, url: url }
  );
  if (!result.ok) {
    tenon.log("browser: navigation failed: " + result.error.code);
    return;
  }
  panes[instanceID].address = url;
  render(instanceID);
}

tenon.views.register(VIEW, { title: "Browser", instanced: true });

tenon.intents.handle("dev.tenon.browser.open.v1", async function (_, call) {
  var result = await call.send("workspace.tab.create.v1", {
    content: {
      kind: "plugin",
      pluginID: PLUGIN_ID,
      viewID: VIEW
    }
  });
  if (!result.ok) throw new Error(result.error.code);
  return {};
});

tenon.views.onOpen(VIEW, async function (instanceID) {
  panes[instanceID] = { address: home };
  render(instanceID);
  var result = await tenon.intents.send(
    "browser.surface.load.v1",
    { surfaceID: instanceID, url: home }
  );
  if (!result.ok) tenon.log("browser: home load failed: " + result.error.code);
});

tenon.views.onClose(VIEW, function (instanceID) {
  delete panes[instanceID];
});

tenon.views.onSelect(VIEW, async function (action, value, instanceID) {
  if (action === "go") {
    await navigate(instanceID, value);
    return;
  }

  var name = null;
  if (action === "back") name = "browser.surface.back.v1";
  if (action === "forward") name = "browser.surface.forward.v1";
  if (action === "reload") name = "browser.surface.reload.v1";
  if (!name) return;

  var result;
  if (name === "browser.surface.back.v1") {
    result = await tenon.intents.send(
      "browser.surface.back.v1",
      { surfaceID: instanceID }
    );
  } else if (name === "browser.surface.forward.v1") {
    result = await tenon.intents.send(
      "browser.surface.forward.v1",
      { surfaceID: instanceID }
    );
  } else {
    result = await tenon.intents.send(
      "browser.surface.reload.v1",
      { surfaceID: instanceID }
    );
  }
  if (!result.ok) tenon.log("browser: navigation failed: " + result.error.code);
});

tenon.events.on("web.did-navigate", function (event) {
  if (event && event.surfaceID && panes[event.surfaceID] && event.url) {
    panes[event.surfaceID].address = event.url;
    render(event.surfaceID);
  }
});
