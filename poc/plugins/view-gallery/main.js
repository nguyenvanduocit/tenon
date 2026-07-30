// view-gallery — demonstrates the declarative view-tree vocabulary a plugin composes
// UI from (docs/design-plugin-views.md). Free tier: UI contribution needs no permission.
// A "card" is just a box you compose from primitives — never something the host must ship.

let reruns = 0;
let lastAnswer = "—";

function render() {
  tenon.views.set("gallery", {
    title: "Gallery",
    body: { type: "vstack", spacing: 10, children: [
      { type: "text", value: "Component gallery", style: "title", weight: "semibold" },
      { type: "text", value: "Tokens map to the app theme — light/dark is automatic.", style: "caption", color: "muted" },

      { type: "card", children: [
        { type: "hstack", children: [
          { type: "text", value: "Build", weight: "semibold" },
          { type: "spacer" },
          { type: "badge", value: "passing", tint: "green" },
        ]},
        { type: "text", value: "1,204 tests · 2.1s", style: "caption", color: "muted" },
        { type: "divider" },
        { type: "hstack", spacing: 6, children: [
          { type: "badge", value: "main", tint: "amber" },
          { type: "badge", value: reruns + " reruns", tint: "muted" },
          { type: "spacer" },
          { type: "button", label: "Rerun", action: "rerun", style: "primary" },
        ]},
      ]},

      { type: "card", children: [
        { type: "text", value: "Status components", weight: "semibold" },
        { type: "grid", columns: 2, spacing: 10, children: [
          { type: "stat", label: "Tests", value: "1204" },
          { type: "stat", label: "Duration", value: "2.1s" },
        ]},
        { type: "divider" },
        { type: "keyValue", label: "Branch", value: "main", tint: "green" },
        { type: "keyValue", label: "Ahead / behind", value: "2 / 0", tint: "amber" },
        { type: "field", label: "Coverage", children: [
          { type: "progress", value: 0.86, tint: "green" },
          { type: "text", value: "86%", style: "caption", color: "muted" },
        ]},
      ]},

      { type: "card", children: [
        { type: "text", value: "Asking the user", weight: "semibold" },
        { type: "text", value: "UI intents describe the question; the shell draws it and returns one typed result.", style: "caption", color: "muted" },
        { type: "hstack", spacing: 6, children: [
          { type: "button", label: "Pick", action: { demo: "pick" } },
          { type: "button", label: "Prompt", action: { demo: "prompt" } },
          { type: "button", label: "Confirm", action: { demo: "confirm" } },
          { type: "button", label: "Toast", action: { demo: "toast" } },
          { type: "spacer" },
        ]},
        { type: "keyValue", label: "Last answer", value: lastAnswer, tint: "amber" },
      ]},

      { type: "card", children: [
        { type: "text", value: "Composability", weight: "semibold" },
        { type: "text", value: "vstack + hstack + box + grid + text + badge + button + stat + keyValue + progress + field — enough to build most panels without waiting on the host.", color: "muted" },
      ]},
    ]},
  });
}

// Each demo awaits the shell's answer, then shows what came back.
async function runDemo(which) {
  if (which === "pick") {
    var picked = await tenon.intents.send("ui.pick.v1", {
      items: [
        { id: "main", label: "main", detail: "current", icon: "arrow.triangle.branch" },
        { id: "dev", label: "dev", detail: "2 ahead", icon: "arrow.triangle.branch" },
        { id: "release", label: "release/1.0", icon: "tag" }
      ],
      placeholder: "Pick a branch"
    });
    lastAnswer = picked.ok && picked.value.selectedID
      ? picked.value.selectedID
      : "dismissed";
  } else if (which === "prompt") {
    var prompted = await tenon.intents.send("ui.prompt.v1", {
      title: "Commit message",
      initialValue: "wip: ",
      multiline: true
    });
    var text = prompted.ok ? prompted.value.value : null;
    lastAnswer = text === null ? "dismissed" : JSON.stringify(text);
  } else if (which === "confirm") {
    var confirmed = await tenon.intents.send("ui.confirm.v1", {
      title: "Discard 3 files?",
      destructive: true
    });
    lastAnswer = confirmed.ok && confirmed.value.confirmed
      ? "confirmed"
      : "cancelled";
  } else if (which === "toast") {
    var toasted = await tenon.intents.send("ui.toast.v1", {
      message: "That is a toast — it expires on its own.",
      kind: "success"
    });
    lastAnswer = toasted.ok ? "toast shown" : "toast failed";
  }
  render();
}

tenon.views.register("gallery", { title: "Gallery" });
// An action is a string when the plugin wrote a string, and an object when it wrote one.
tenon.views.onSelect("gallery", function (action) {
  if (action === "rerun") {
    reruns += 1;
    tenon.log("rerun #" + reruns);
    render();
  } else if (action && action.demo) {
    runDemo(action.demo);
  }
});
render();
