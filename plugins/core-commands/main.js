// Core workspace actions are plugin-owned intents. Their palette rows are declared in
// the manifest; execution uses the same canonical workspace intents as every caller.

function requireSuccess(result) {
  if (!result.ok) throw new Error(result.error.code);
  return {};
}

tenon.intents.handle("dev.tenon.core-commands.tab.new.v1", async function (_, call) {
  return requireSuccess(
    await call.send("workspace.tab.create.v1", {})
  );
});

tenon.intents.handle("dev.tenon.core-commands.terminal.new.v1", async function (_, call) {
  return requireSuccess(
    await call.send("workspace.tab.create.v1", {
      content: { kind: "terminal" }
    })
  );
});

tenon.intents.handle("dev.tenon.core-commands.pane.split-right.v1", async function (_, call) {
  return requireSuccess(
    await call.send("workspace.pane.split.v1", {
      axis: "horizontal"
    })
  );
});

tenon.intents.handle("dev.tenon.core-commands.pane.split-down.v1", async function (_, call) {
  return requireSuccess(
    await call.send("workspace.pane.split.v1", {
      axis: "vertical"
    })
  );
});

tenon.intents.handle("dev.tenon.core-commands.pane.close.v1", async function (_, call) {
  return requireSuccess(
    await call.send("workspace.pane.close.v1", {})
  );
});

tenon.intents.handle("dev.tenon.core-commands.changes.open.v1", async function (_, call) {
  return requireSuccess(
    await call.send("workspace.tab.create.v1", {
      content: { kind: "changes" }
    })
  );
});

tenon.intents.handle("dev.tenon.core-commands.automation.open.v1", async function (_, call) {
  return requireSuccess(
    await call.send("workspace.tab.create.v1", {
      content: { kind: "automation" }
    })
  );
});

tenon.intents.handle("dev.tenon.core-commands.tab.next.v1", async function (_, call) {
  return requireSuccess(
    await call.send("workspace.tab.next.v1", {})
  );
});

tenon.intents.handle("dev.tenon.core-commands.tab.previous.v1", async function (_, call) {
  return requireSuccess(
    await call.send("workspace.tab.previous.v1", {})
  );
});

tenon.intents.handle("dev.tenon.core-commands.pane.focus-next.v1", async function (_, call) {
  return requireSuccess(
    await call.send("workspace.pane.focus-next.v1", {})
  );
});

tenon.intents.handle("dev.tenon.core-commands.workspace.switch.v1", async function (_, call) {
  // Every page. A switcher that lists only page one offers the human a menu missing the
  // workspace they are looking for, with nothing to say it was truncated. Bounded at
  // MAX_STATE_PAGES × 256 nodes (invariant 10).
  var MAX_STATE_PAGES = 16;
  var workspaces = [];
  var cursor = null;
  for (var page = 0; page < MAX_STATE_PAGES; page++) {
    var input = { limit: 256 };
    if (cursor) input.cursor = cursor;
    var state = await call.send("workspace.state.v1", input);
    if (!state.ok) throw new Error(state.error.code);
    var nodes = state.value.nodes || [];
    for (var i = 0; i < nodes.length; i++) {
      if (nodes[i].kind === "workspace") workspaces.push(nodes[i]);
    }
    cursor = state.value.nextCursor;
    if (!cursor) break;
  }
  if (!workspaces.length) return {};

  var picked = await call.send("ui.pick.v1", {
    items: workspaces.map(function (workspace) {
      return {
        id: workspace.id,
        label: workspace.name,
        detail: workspace.path,
        icon: "square.stack"
      };
    }),
    placeholder: "Switch workspace"
  });
  if (!picked.ok || !picked.value.selectedID) return {};

  return requireSuccess(
    await call.send(
      "workspace.select.v1",
      {},
      { scope: { workspaceID: picked.value.selectedID } }
    )
  );
});
