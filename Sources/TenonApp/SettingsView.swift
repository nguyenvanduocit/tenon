// @domain: plugin-settings, companion
import AppKit
import SwiftUI
import TenonCore
import TenonIntentCore

/// The Settings window (⌘,), styled like modern macOS System Settings: a source-list
/// sidebar on the left, a grouped `Form` detail on the right.
///
/// The sidebar is **flat** — General, Companion, then one entry per plugin that declares settings
/// (drawn generically from its manifest, no plugin-specific Swift), then the host's own
/// pages: Automation, Permissions, CLI, Agent Harness, and Extensions for enable/permissions of every
/// plugin. A plugin's settings pane looks exactly like a built-in one because the same
/// `PluginSettingsForm` renders both.
struct SettingsView: View {
    var host: PluginHost
    @Bindable var prefs: AppPreferencesStore
    var instanceChannel: AppInstanceChannel

    @State private var route: SettingsRoute = .general

    /// Plugins that declare at least one setting get their own flat entry.
    private var settingsPlugins: [PluginSnapshot] {
        host.plugins.filter { !$0.settingSpecs.isEmpty }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $route) {
                sidebarRow(.general, "General", "gearshape.fill")
                sidebarRow(.companion, "Companion", "sparkles")

                if !settingsPlugins.isEmpty {
                    Section("Plugins") {
                        ForEach(settingsPlugins) { plugin in
                            sidebarRow(
                                .plugin(plugin.id),
                                plugin.settingsTitle,
                                plugin.icon ?? "puzzlepiece.extension.fill"
                            )
                        }
                    }
                }

                Section {
                    sidebarRow(.automation, "Automation", "clock.arrow.circlepath")
                    sidebarRow(.permissions, "Permissions", "hand.raised.fill")
                    sidebarRow(.cli, "CLI", "terminal.fill")
                    sidebarRow(.agentHarness, "Agent Harness", "graduationcap.fill")
                    sidebarRow(.extensions, "Extensions", "puzzlepiece.extension.fill")
                }
            }
            .tenonScrollbarStyle()
            .navigationSplitViewColumnWidth(min: 195, ideal: 215, max: 250)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
        }
        .frame(minWidth: 730, idealWidth: 760, minHeight: 560, idealHeight: 660)
    }

    private func sidebarRow(
        _ route: SettingsRoute,
        _ title: String,
        _ systemImage: String
    ) -> some View {
        Label {
            Text(title)
        } icon: {
            SettingsIconBadge(systemName: systemImage)
        }
        .tag(route)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var detail: some View {
        switch route {
        case .general:
            GeneralSettingsDetail(prefs: prefs).navigationTitle("General")
        case .companion:
            CompanionSettingsDetail(prefs: prefs).navigationTitle("Companion")
        case .automation:
            AutomationSettingsDetail(prefs: prefs).navigationTitle("Automation")
        case .permissions:
            PermissionsSettingsDetail(prefs: prefs).navigationTitle("Permissions")
        case .cli:
            CLISettingsDetail(instanceChannel: instanceChannel).navigationTitle("CLI")
        case .agentHarness:
            AgentHarnessSettingsDetail().navigationTitle("Agent Harness")
        case .extensions:
            ExtensionsDetail(host: host).navigationTitle("Extensions")
        case .plugin(let pluginID):
            if let plugin = host.plugins.first(
                where: { $0.id == pluginID }
            ) {
                PluginSettingsForm(host: host, plugin: plugin)
                    .navigationTitle(plugin.settingsTitle)
            } else {
                // The plugin was disabled/removed while selected — fall back gracefully.
                GeneralSettingsDetail(prefs: prefs).navigationTitle("General")
            }
        }
    }

}

private enum SettingsRoute: Hashable {
    case general
    case companion
    case automation
    case permissions
    case cli
    case agentHarness
    case extensions
    case plugin(PluginID)
}

// MARK: - Companion  @domain: companion

/// Defaults for short host-owned AI assistance. A feature may expose a deliberate per-run
/// override, but otherwise it takes one snapshot of this profile when its task starts.
struct CompanionSettingsDetail: View {
    @Bindable var prefs: AppPreferencesStore
    @State private var installedAgents: Set<AgentCLI> = []
    @State private var didCheckAgents = false
    @FocusState private var promptFocused: Bool

    private var profile: CompanionProfile { prefs.preferences.companion }

    var body: some View {
        Form {
            Section {
                Picker("Agent", selection: $prefs.preferences.companion.agent) {
                    ForEach(AgentCLI.allCases) { agent in
                        Text(agent.label).tag(agent)
                    }
                }

                TextField(
                    "Model",
                    text: $prefs.preferences.companion.model,
                    prompt: Text("Provider default")
                )
                .accessibilityHint("Leave blank to use the agent's configured default model.")

                LabeledContent("Availability") {
                    if !didCheckAgents {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Checking installed agents")
                    } else if installedAgents.contains(profile.agent) {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Not found", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Assistant")
            } footer: {
                Text("These are defaults for Tenon's host-native AI helpers. A task with its own visible agent or model controls may override them for that run.")
            }

            Section {
                LabeledContent("Working folder") {
                    HStack(spacing: 8) {
                        Text(profile.workingDirectory.isEmpty
                            ? "Task default"
                            : profile.workingDirectory)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)

                        if !profile.workingDirectory.isEmpty {
                            Button("Clear") {
                                prefs.preferences.companion.workingDirectory = ""
                            }
                        }
                        Button("Choose…") { chooseWorkingDirectory() }
                    }
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("Custom prompt")
                        .font(.callout)

                    TextEditor(text: $prefs.preferences.companion.customPrompt)
                        .font(TenonTheme.interfaceFont(size: 12))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 84)
                        .background(TenonTheme.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(
                                    promptFocused ? TenonTheme.amber : TenonTheme.line,
                                    lineWidth: promptFocused ? 2 : 1
                                )
                        }
                        .focused($promptFocused)
                        .accessibilityLabel("Companion instructions")

                    HStack {
                        Text("Applied before task instructions")
                        Spacer()
                        Text("\(profile.customPrompt.utf8.count) / \(CompanionProfile.maximumPromptBytes) bytes")
                            .monospacedDigit()
                            .accessibilityLabel(
                                "\(profile.customPrompt.utf8.count) of \(CompanionProfile.maximumPromptBytes) bytes used"
                            )
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("Personalization")
            } footer: {
                Text("Instructions set stable tone, terminology, or language; task schemas and safety rules still win. Depending on the provider and task, files in the chosen folder may be available to the agent.")
            }
        }
        .tenonScrollbarStyle()
        .formStyle(.grouped)
        .task {
            installedAgents = Set(await AgentExecutableLocator.scanLive().keys)
            didCheckAgents = true
        }
    }

    private func chooseWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.title = Shell.text("Choose Companion Working Folder")
        panel.prompt = Shell.text("Choose")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if let current = profile.workingDirectoryURL {
            panel.directoryURL = current
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        prefs.preferences.companion.workingDirectory = url.standardizedFileURL.path
    }
}

/// A white SF Symbol on a rounded, tinted square — the macOS System Settings sidebar glyph.
/// One treatment for every settings page.
///
/// Colour here would be decoration: a hue assigned to "CLI" or to a plugin says nothing about
/// state, and the design law reserves additional colours for real status — success, warning,
/// destructive. Selection is already carried by the list, and it is the only thing in this
/// sidebar that differs between rows.
private struct SettingsIconBadge: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(TenonTheme.text)
            .frame(width: 20, height: 20)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(TenonTheme.chromeRaised)
            )
    }
}

// MARK: - Automation  @domain: automation

/// Automation configuration only. The operational schedules, Run Now actions, authoring,
/// and delivery history live in the dedicated Automation view on the Canvas.
private struct AutomationSettingsDetail: View {
    @Bindable var prefs: AppPreferencesStore

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Run scheduled automations",
                    isOn: $prefs.preferences.automationSchedulesEnabled
                )
            } footer: {
                Text("When off, Tenon advances schedule clocks but suppresses scheduled "
                    + "events, so re-enabling does not replay missed runs. Run Now remains "
                    + "available in the Automation view on the Canvas.")
            }
        }
        .tenonScrollbarStyle()
        .formStyle(.grouped)
    }
}

// MARK: - Permissions  @domain: intent-bus

/// The "Permissions" page: one switch deciding whether Tenon asks before a caller runs a
/// contract that declared it needs asking, or answers for you.
///
/// The page states the consequence rather than leaving it in the word "dangerously". A
/// person turning this off wants to know what comes back, and a person leaving it on
/// deserves to read what they are keeping.
private struct PermissionsSettingsDetail: View {
    @Bindable var prefs: AppPreferencesStore

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Approve every permission request automatically",
                    isOn: $prefs.preferences.bypassAllPermissionPrompts
                )
            } footer: {
                Text("On, nothing is ever asked: plugins, the CLI, and agents run every "
                    + "operation they declared without stopping for you — including the "
                    + "irreversible ones, like deleting a stored secret. Off, Tenon asks "
                    + "once per caller and remembers your answer.")
            }

            if prefs.preferences.bypassAllPermissionPrompts {
                Section {
                    Label {
                        Text("A plugin you install from outside Tenon's own bundle runs "
                            + "everything its manifest declares, and you are not asked "
                            + "first. Its manifest is then the only place that says what "
                            + "it may do — Extensions lists it.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                Text("What this switch cannot reach: an intent still has to be declared by "
                    + "the caller's manifest, allowed for its audience, hold the capability "
                    + "and the workspace, pane, path or host scope it names, and reach a "
                    + "provider willing to serve it. Those run on every invocation whether "
                    + "this is on or off. The switch answers the confirmation, nothing else.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Still enforced")
            }
        }
        .tenonScrollbarStyle()
        .formStyle(.grouped)
    }
}

// MARK: - CLI  @domain: cli-control

/// The "CLI" settings page: an Install button that copies the self-contained `tenon-cli` binary
/// into `~/.local/bin` so agents and scripts can drive Tenon from any terminal.
private struct CLISettingsDetail: View {
    let instanceChannel: AppInstanceChannel
    /// Read once off the main thread and refreshed after an install, rather than stat'd from
    /// inside `body` on every render.
    @State private var status = CLICommandInstaller.Status()
    @State private var isInstalling = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Command-line tool")
                        .font(.headline)
                    Text("Install `tenon-cli` so agents and scripts can drive Tenon from any terminal — "
                        + "run commands, read pane output, and wait for an agent to finish. Inside a Tenon "
                        + "pane the running app's socket is discovered automatically.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                HStack(spacing: 10) {
                    Button(status.isInstalled ? "Reinstall Command" : "Install Command") {
                        install()
                    }
                    .disabled(!status.canInstall || isInstalling)

                    if status.isInstalled {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                    }
                }

                if let installedPath = status.installedPath {
                    Text("Installed to \(installedPath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if instanceChannel == .staging {
                    Label("Staging cannot replace production's global tenon-cli command.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                } else if !status.canInstall {
                    Label("No tenon-cli binary is available in this build to install.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            } footer: {
                Text("Installs to ~/.local/bin. If your shell can't find `tenon-cli` afterwards, add that "
                    + "directory to your PATH:\n    export PATH=\"$HOME/.local/bin:$PATH\"")
                    .font(.caption)
                    .textSelection(.enabled)
            }
        }
        .tenonScrollbarStyle()
        .formStyle(.grouped)
        .task { status = await CLICommandInstaller.status(in: instanceChannel) }
    }

    private func install() {
        isInstalling = true
        Task {
            defer { isInstalling = false }
            do {
                _ = try await CLICommandInstaller.installOffMain(in: instanceChannel)
                errorMessage = nil
            } catch {
                errorMessage = "\(error)"
            }
            status = await CLICommandInstaller.status(in: instanceChannel)
        }
    }
}

// MARK: - Agent Harness  @domain: agent-control

/// The "Agent Harness" page: one button that teaches every agent on this machine what Tenon
/// is and what it can do about it.
///
/// The page names the exact files it writes and offers Remove beside Install, because these
/// are the person's own global instruction files — loaded into every session they ever run,
/// including the ones that have nothing to do with Tenon. A settings page that edits those
/// silently, or that can only add, would not have earned the right to be a button.
private struct AgentHarnessSettingsDetail: View {
    private let installer = AgentHarnessInstaller()
    @State private var status = AgentHarnessInstaller.Status()
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Teach your agents about Tenon")
                        .font(.headline)
                    Text("Installs a short briefing into the instructions your agents already "
                        + "read at the start of every session: that they are running in a "
                        + "Tenon pane, how to label their own tab so you can see what each "
                        + "one is working on, how to resolve their pane and workspace, and "
                        + "how to ask you a real question instead of stalling.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                HStack(spacing: 10) {
                    Button(installButtonTitle) { install() }
                        .disabled(isWorking)

                    if status.state == .current {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                    } else if status.state == .outdated {
                        Label("Update available", systemImage: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }

                    Spacer()

                    if status.state != .absent {
                        Button("Remove") { remove() }
                            .disabled(isWorking)
                    }
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            } header: {
                Text("Installation")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(AgentHarnessInstaller.Target.allCases, id: \.relativePath) { target in
                        Text("~/\(target.relativePath)")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Text("The two instruction files keep everything you wrote in them: the "
                        + "briefing goes between Tenon's own markers, and Remove takes only "
                        + "what is between them. The skill file belongs to Tenon entirely.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                Text("The briefing describes `tenon-cli`. Install it on the CLI page first, or "
                    + "an agent that reads this will find no command to run.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Requires")
            }
        }
        .tenonScrollbarStyle()
        .formStyle(.grouped)
        .task { refresh() }
    }

    private var installButtonTitle: String {
        switch status.state {
        case .absent: "Install Harness"
        case .current: "Reinstall Harness"
        case .outdated: "Update Harness"
        }
    }

    private func install() {
        perform { try installer.install() }
    }

    private func remove() {
        perform { try installer.remove() }
    }

    private func perform(_ work: @escaping () throws -> Void) {
        isWorking = true
        errorMessage = nil
        do {
            try work()
        } catch {
            errorMessage = "\(error)"
        }
        refresh()
        isWorking = false
    }

    private func refresh() {
        status = installer.status()
    }
}

// MARK: - General  @domain: plugin-settings

private struct GeneralSettingsDetail: View {
    @Bindable var prefs: AppPreferencesStore

    var body: some View {
        Form {
            Section {
                paneContentPicker("New tab opens", selection: $prefs.preferences.newTabContent)
                paneContentPicker("New split opens", selection: $prefs.preferences.newSplitContent)
                paneContentPicker("New workspace opens", selection: $prefs.preferences.newWorkspaceContent)
                Picker("Maximum automatic pane width", selection: $prefs.preferences.newPaneMaximumWidth) {
                    Text("As wide as it fits").tag(SpatialExtentFraction?.none)
                    ForEach(SpatialExtentFraction.allCases, id: \.self) { fraction in
                        Text(fraction.label).tag(SpatialExtentFraction?.some(fraction))
                    }
                }
                .accessibilityLabel("Maximum automatic pane width")
                .accessibilityHint(
                    "Limits pane width when opening a pane or absorbing space after a close."
                )
            } header: {
                Text("Pane defaults")
            } footer: {
                Text("Choose what a freshly opened pane starts on. The width limit applies "
                    + "when a pane opens and when a neighboring pane closes. Changing it "
                    + "does not resize existing panes, and you can still drag beyond it.")
            }

            Section("Sidebar") {
                Toggle("Expand workspace sidebar on launch", isOn: $prefs.preferences.sidebarVisibleOnLaunch)
                LabeledContent("Default width") {
                    HStack(spacing: 10) {
                        Slider(
                            value: $prefs.preferences.sidebarWidth,
                            in: Double(SidebarResize.minWidth)...Double(SidebarResize.maxWidth)
                        )
                        .frame(width: 180)
                        Text("\(Int(prefs.preferences.sidebarWidth)) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 46, alignment: .trailing)
                    }
                }
            }

            Section {
                Picker("Accent colour", selection: $prefs.preferences.accent) {
                    ForEach(AccentColor.allCases, id: \.self) { accent in
                        HStack {
                            Circle()
                                .fill(Color(nsColor: NSColor(hex: accent.hex)))
                                .frame(width: 12, height: 12)
                            Text(accent.label)
                        }
                        .tag(accent)
                    }
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text("Applies to Tenon's chrome — tab selection, active-pane borders, "
                    + "focus marks. Terminal colours come from ghostty.")
            }

            // Where a person goes to ask what they are running. The workspace list is not
            // that place, so the version reads here — beside the plugin versions Settings
            // already reports — rather than under the sidebar (T-098).
            Section("About") {
                LabeledContent("Tenon version") {
                    Text(AppVersion.current.summary)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .textSelection(.enabled)
                        .accessibilityIdentifier("tenon.settingsVersion")
                }
            }
        }
        .tenonScrollbarStyle()
        .formStyle(.grouped)
    }

    private func paneContentPicker(
        _ title: String,
        selection: Binding<DefaultPaneContent>
    ) -> some View {
        Picker(title, selection: selection) {
            ForEach(DefaultPaneContent.allCases, id: \.self) { content in
                Text(content.label).tag(content)
            }
        }
    }
}

// MARK: - Per-plugin settings (generic renderer — the whole point)  @domain: plugin-settings

private struct PluginSettingsForm: View {
    var host: PluginHost
    let plugin: PluginSnapshot
    @State private var isChangingEnabledState = false
    @State private var lifecycleError: String?

    var body: some View {
        Form {
            ForEach(Array(groupedSpecs.enumerated()), id: \.offset) { _, group in
                Section(group.name ?? "") {
                    ForEach(group.specs, id: \.key) { spec in
                        SpecControl(
                            host: host,
                            pluginID: plugin.id,
                            spec: spec
                        )
                    }
                }
            }

            Section {
                if !plugin.permissions.isEmpty {
                    LabeledContent("Permissions") {
                        Text(plugin.permissions.joined(separator: ", "))
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
                ForEach(plugin.permissionViolations, id: \.self) { violation in
                    Label(violation, systemImage: "nosign")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.red)
                }
                Toggle("Enabled", isOn: Binding(
                    get: { plugin.isEnabled },
                    set: { setEnabled($0) }
                ))
                .disabled(isChangingEnabledState)
                if let lifecycleError {
                    Text(lifecycleError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Plugin")
            } footer: {
                Text("\(plugin.name) · v\(plugin.version)")
                    .font(.system(.caption, design: .monospaced))
            }
        }
        .tenonScrollbarStyle()
        .formStyle(.grouped)
    }

    /// Specs bucketed by `group`, preserving first-seen order; ungrouped specs share a
    /// single leading unnamed section.
    private var groupedSpecs: [(name: String?, specs: [PluginSettingSpec])] {
        var order: [String?] = []
        var buckets: [String?: [PluginSettingSpec]] = [:]
        for spec in plugin.settingSpecs {
            if buckets[spec.group] == nil { order.append(spec.group) }
            buckets[spec.group, default: []].append(spec)
        }
        return order.map { (name: $0, specs: buckets[$0] ?? []) }
    }

    private func setEnabled(_ enabled: Bool) {
        guard !isChangingEnabledState else { return }
        isChangingEnabledState = true
        lifecycleError = nil
        Task { @MainActor in
            do {
                try await host.setEnabled(
                    enabled,
                    pluginID: plugin.id
                )
            } catch {
                lifecycleError = String(describing: error)
            }
            isChangingEnabledState = false
        }
    }
}

/// One control, chosen by the spec's declared type — the same renderer for every plugin.
private struct SpecControl: View {
    var host: PluginHost
    let pluginID: PluginID
    let spec: PluginSettingSpec

    @State private var value: IntentValue?
    @State private var draft = ""
    @State private var numberDraft = 0.0
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                switch spec.type {
                case .boolean:
                    Toggle(
                        spec.label,
                        isOn: Binding(
                            get: { booleanValue },
                            set: { save(.bool($0)) }
                        )
                    )
                case .string:
                    TextField(spec.label, text: $draft)
                        .onSubmit { save(.string(draft)) }
                case .number:
                    TextField(
                        spec.label,
                        value: $numberDraft,
                        format: .number
                    )
                    .onSubmit { save(.number(numberDraft)) }
                case .select:
                    if let options = spec.options, !options.isEmpty {
                        Picker(
                            spec.label,
                            selection: Binding(
                                get: {
                                    stringValue
                                        ?? options.first?.value
                                        ?? ""
                                },
                                set: { save(.string($0)) }
                            )
                        ) {
                            ForEach(options, id: \.value) { option in
                                Text(option.label).tag(option.value)
                            }
                        }
                    } else {
                        TextField(spec.label, text: $draft)
                            .onSubmit { save(.string(draft)) }
                    }
                }
            }
            .disabled(isLoading || isSaving)

            if isLoading || isSaving {
                ProgressView()
                    .controlSize(.small)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .task(id: "\(pluginID.rawValue):\(spec.key)") {
            await load()
        }
    }

    private var booleanValue: Bool {
        guard case let .bool(value) = value else { return false }
        return value
    }

    private var stringValue: String? {
        guard case let .string(value) = value else { return nil }
        return value
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let loaded = try await host.settingValue(
                forKey: spec.key,
                pluginID: pluginID
            ) ?? spec.defaultValue?.intentValue
            value = loaded
            synchronizeDrafts(with: loaded)
        } catch {
            errorMessage = String(describing: error)
        }
        isLoading = false
    }

    private func save(_ newValue: IntentValue) {
        guard !isSaving else { return }
        let previousValue = value
        value = newValue
        synchronizeDrafts(with: newValue)
        isSaving = true
        errorMessage = nil
        Task { @MainActor in
            do {
                try await host.setSetting(
                    newValue,
                    forKey: spec.key,
                    pluginID: pluginID
                )
            } catch {
                value = previousValue
                synchronizeDrafts(with: previousValue)
                errorMessage = String(describing: error)
            }
            isSaving = false
        }
    }

    private func synchronizeDrafts(with value: IntentValue?) {
        switch value {
        case let .string(string):
            draft = string
        case let .number(number):
            numberDraft = number
        case let .integer(integer):
            numberDraft = Double(integer)
        default:
            break
        }
    }
}

// MARK: - Extensions (enable/permissions for every plugin, settings or not)  @domain: plugin-settings

private struct ExtensionsDetail: View {
    var host: PluginHost

    var body: some View {
        Form {
            Section {
                Label(
                    "Plugins run inside the Tenon process. Enable only code you trust.",
                    systemImage: "exclamationmark.shield.fill"
                )
                .foregroundStyle(.orange)
            }
            if host.plugins.isEmpty {
                Section { Text("No plugins installed.").foregroundStyle(.secondary) }
            }
            ForEach(host.plugins) { plugin in
                ExtensionPluginSection(host: host, plugin: plugin)
            }
        }
        .tenonScrollbarStyle()
        .formStyle(.grouped)
    }
}

private struct ExtensionPluginSection: View {
    let host: PluginHost
    let plugin: PluginSnapshot
    @State private var isChangingEnabledState = false
    @State private var lifecycleError: String?

    var body: some View {
        Section {
            Toggle(
                "Enabled",
                isOn: Binding(
                    get: { plugin.isEnabled },
                    set: { setEnabled($0) }
                )
            )
            .disabled(isChangingEnabledState)
            LabeledContent("Permissions") {
                Text(
                    plugin.permissions.isEmpty
                        ? "none"
                        : plugin.permissions.joined(separator: ", ")
                )
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
            }
            if !plugin.unknownPermissions.isEmpty {
                Label(
                    "unknown: \(plugin.unknownPermissions.joined(separator: ", "))",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.orange)
            }
            if let error = plugin.error {
                Label(error, systemImage: "xmark.octagon.fill")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.red)
            }
            if let lifecycleError {
                Text(lifecycleError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("\(plugin.settingsTitle) · v\(plugin.version)")
                .font(.system(.body, design: .monospaced))
        }
    }

    private func setEnabled(_ enabled: Bool) {
        guard !isChangingEnabledState else { return }
        isChangingEnabledState = true
        lifecycleError = nil
        Task { @MainActor in
            do {
                try await host.setEnabled(
                    enabled,
                    pluginID: plugin.id
                )
            } catch {
                lifecycleError = String(describing: error)
            }
            isChangingEnabledState = false
        }
    }
}
