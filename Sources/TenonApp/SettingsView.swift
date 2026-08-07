// @domain: plugin-settings
import SwiftUI
import TenonCore
import TenonIntentCore

/// The Settings window (⌘,), styled like modern macOS System Settings: a source-list
/// sidebar on the left, a grouped `Form` detail on the right.
///
/// The sidebar is **flat** — General, then one entry per plugin that declares settings
/// (drawn generically from its manifest, no plugin-specific Swift), then Extensions for
/// enable/permissions of every plugin. A plugin's settings pane looks exactly like a
/// built-in one because the same `PluginSettingsForm` renders both.
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
                    sidebarRow(.cli, "CLI", "terminal.fill")
                    sidebarRow(.extensions, "Extensions", "puzzlepiece.extension.fill")
                }
            }
            .tenonScrollbarStyle()
            .navigationSplitViewColumnWidth(min: 195, ideal: 215, max: 250)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
        }
        .frame(minWidth: 730, idealWidth: 760, minHeight: 470, idealHeight: 560)
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
        case .automation:
            AutomationSettingsDetail(prefs: prefs).navigationTitle("Automation")
        case .cli:
            CLISettingsDetail(instanceChannel: instanceChannel).navigationTitle("CLI")
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
    case automation
    case cli
    case extensions
    case plugin(PluginID)
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

// MARK: - General  @domain: plugin-settings

private struct GeneralSettingsDetail: View {
    @Bindable var prefs: AppPreferencesStore

    var body: some View {
        Form {
            Section {
                paneContentPicker("New tab opens", selection: $prefs.preferences.newTabContent)
                paneContentPicker("New split opens", selection: $prefs.preferences.newSplitContent)
                paneContentPicker("New workspace opens", selection: $prefs.preferences.newWorkspaceContent)
            } header: {
                Text("New panes")
            } footer: {
                Text("The view a freshly opened pane starts on.")
            }

            Section("Sidebar") {
                Toggle("Show workspace sidebar on launch", isOn: $prefs.preferences.sidebarVisibleOnLaunch)
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
