// Browser — an instance-aware plugin. Each pane owns one browser surface whose
// identifier is the pane instance ID supplied by the host.

var VIEW = "browser";
var PLUGIN_ID = "dev.tenon.browser";
var home = tenon.settings.get("homeURL") || "https://duckduckgo.com";
var panes = {};
// The address the next pane should land on. An opener names where it wants to go before
// the pane exists, so the request is parked here and the first onOpen consumes it. It is
// cleared whether the open succeeds or fails, so a refused open never redirects the next
// one.
var pendingAddress = null;

function render(instanceID) {
  var pane = panes[instanceID];
  if (!pane) return;
  // Back/forward/reload and the address field go in the pane's ONE chrome header, beside
  // the pane's name. Three `iconButton`s and a flexible `textfield` are a browser toolbar,
  // so every point of the pane below the 34-point strip belongs to the web surface.
  tenon.views.set(VIEW, {
    header: {
      leading: [
        { type: "iconButton", id: "back", systemName: "chevron.left", tooltip: "Back" },
        { type: "iconButton", id: "forward", systemName: "chevron.right", tooltip: "Forward" },
        { type: "iconButton", id: "reload", systemName: "arrow.clockwise", tooltip: "Reload" }
      ],
      trailing: [
        {
          type: "textfield",
          id: "go",
          value: pane.address,
          flex: true,
          placeholder: "Search or enter website"
        }
      ]
    },
    body: { type: "webview", surfaceID: instanceID }
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

tenon.intents.handle("dev.tenon.browser.open.v1", async function (input, call) {
  pendingAddress = resolve(input && input.url);
  var result = await call.send("workspace.content.open.v1", {
    content: {
      kind: "plugin",
      pluginID: PLUGIN_ID,
      viewID: VIEW
    }
  });
  if (!result.ok) {
    pendingAddress = null;
    throw new Error(result.error.code);
  }
  return {};
});

tenon.views.onOpen(VIEW, async function (instanceID) {
  var address = pendingAddress || home;
  pendingAddress = null;
  panes[instanceID] = { address: address };
  render(instanceID);
  var result = await tenon.intents.send(
    "browser.surface.load.v1",
    { surfaceID: instanceID, url: address }
  );
  if (!result.ok) tenon.log("browser: initial load failed: " + result.error.code);
});

tenon.views.onClose(VIEW, function (instanceID) {
  delete panes[instanceID];
});

// The address field is a header `textfield`, and a field COMMITS rather than selects: the
// plugin hears the typed address once, when the user says so.
tenon.views.onSubmit(VIEW, async function (action, text, instanceID) {
  if (action === "go") await navigate(instanceID, text);
});

tenon.views.onSelect(VIEW, async function (action, value, instanceID) {
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
