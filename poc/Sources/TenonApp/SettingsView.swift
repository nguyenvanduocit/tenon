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
    var automation: AutomationScheduler
    var runNow: (PluginID, String) async -> Void
    var createWithAI: () -> Void

    @State private var route: SettingsRoute = .general

    /// Plugins that declare at least one setting get their own flat entry.
    private var settingsPlugins: [PluginSnapshot] {
        host.plugins.filter { !$0.settingSpecs.isEmpty }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $route) {
                sidebarRow(.general, "General", "gearshape.fill", .gray)

                if !settingsPlugins.isEmpty {
                    Section("Plugins") {
                        ForEach(settingsPlugins) { plugin in
                            sidebarRow(
                                .plugin(plugin.id),
                                plugin.settingsTitle,
                                plugin.icon ?? "puzzlepiece.extension.fill",
                                pluginTint(plugin.id)
                            )
                        }
                    }
                }

                Section {
                    sidebarRow(.automation, "Automation", "clock.arrow.circlepath", .mint)
                    sidebarRow(.cli, "CLI", "terminal.fill", .blue)
                    sidebarRow(.extensions, "Extensions", "puzzlepiece.extension.fill", .indigo)
                }
            }
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
        _ systemImage: String,
        _ tint: Color
    ) -> some View {
        Label {
            Text(title)
        } icon: {
            SettingsIconBadge(systemName: systemImage, tint: tint)
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
            AutomationSettingsDetail(
                host: host,
                automation: automation,
                runNow: runNow,
                createWithAI: createWithAI
            )
            .navigationTitle("Automation")
        case .cli:
            CLISettingsDetail().navigationTitle("CLI")
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

    /// A stable, pleasant tint per plugin so the sidebar reads like macOS's varied icons.
    private func pluginTint(_ pluginID: PluginID) -> Color {
        let palette: [Color] = [.orange, .green, .pink, .teal, .purple, .cyan]
        let hash = pluginID.rawValue.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        return palette[Int(hash % UInt64(palette.count))]
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
private struct SettingsIconBadge: View {
    let systemName: String
    let tint: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(tint))
    }
}

// MARK: - Automation

/// T-060: the automation surface. Every armed schedule with its next firing and a
/// per-schedule Run Now, then the recent runs with the facts each firing delivered —
/// the row's evidence is exactly the payload the plugin received plus the delivery
/// outcome. Reads scheduler state DIRECT (same owner, invariant 6); Run Now composes
/// the same delivery path the tick loop uses.
private struct AutomationSettingsDetail: View {
    var host: PluginHost
    var automation: AutomationScheduler
    var runNow: (PluginID, String) async -> Void
    var createWithAI: () -> Void

    var body: some View {
        Form {
            let listings = automation.listings()
            // T-061: present in both states — an empty page's first affordance and a
            // populated page's way to add the next one.
            Section {
                Button("Create with AI…") {
                    createWithAI()
                }
            } footer: {
                Text("Opens a terminal running claude with a guide to pair-write an "
                    + "automation script with you. The script lands in the plugins "
                    + "folder and loads the moment it is saved.")
                    .font(.caption)
            }
            if listings.isEmpty {
                Section {
                    Text("No installed plugin declares an automation schedule.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("A plugin declares schedules in its manifest's "
                        + "\"automation.schedules\" block; they appear here with "
                        + "their next firing.")
                        .font(.caption)
                }
            } else {
                Section("Schedules") {
                    ForEach(listings, id: \.rowID) { listing in
                        scheduleRow(listing)
                    }
                }
            }

            let records = automation.runHistory.records
            if !records.isEmpty {
                Section("Recent runs") {
                    ForEach(
                        Array(records.prefix(30).enumerated()),
                        id: \.offset
                    ) { _, record in
                        runRow(record)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func scheduleRow(
        _ listing: AutomationScheduler.ScheduleListing
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(pluginTitle(listing.pluginID)) · \(listing.spec.id)")
                Text(cadenceText(listing.spec))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text("Next firing")
                    Text(listing.nextDue, style: .relative)
                    Text("(\(listing.nextDue.formatted(date: .abbreviated, time: .shortened)))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Run Now") {
                Task {
                    await runNow(listing.pluginID, listing.spec.id)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func runRow(_ record: AutomationRunRecord) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(
                systemName: record.delivered
                    ? "checkmark.circle.fill"
                    : "exclamationmark.circle.fill"
            )
            .foregroundStyle(record.delivered ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(pluginTitle(record.pluginID)) · \(record.scheduleID)")
                Text(evidenceText(record))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(
                record.firedAt.formatted(
                    .relative(presentation: .named)
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }

    private func pluginTitle(_ pluginID: PluginID) -> String {
        host.plugins.first(where: { $0.id == pluginID })?.settingsTitle
            ?? pluginID.rawValue
    }

    private func cadenceText(_ spec: AutomationScheduleSpec) -> String {
        switch spec.cadence {
        case .every(let interval):
            return "Every \(durationText(interval))"
        case .daily(let hour, let minute):
            return String(format: "Daily at %02d:%02d", hour, minute)
        }
    }

    private func durationText(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        if seconds % 86400 == 0 { return "\(seconds / 86400)d" }
        if seconds % 3600 == 0 { return "\(seconds / 3600)h" }
        if seconds % 60 == 0 { return "\(seconds / 60)m" }
        return "\(seconds)s"
    }

    private func evidenceText(_ record: AutomationRunRecord) -> String {
        var parts = [
            "trigger \(record.trigger.rawValue)",
            "scheduled for "
                + record.scheduledFor.formatted(
                    date: .abbreviated,
                    time: .standard
                ),
        ]
        if record.late { parts.append("late") }
        parts.append(
            record.delivered
                ? "delivered"
                : "dropped — no live plugin took it"
        )
        return parts.joined(separator: " · ")
    }
}

private extension AutomationScheduler.ScheduleListing {
    /// View identity for the settings list: (plugin, schedule) is unique by the
    /// manifest's own duplicate-id rule.
    var rowID: String {
        pluginID.rawValue + "/" + spec.id
    }
}

// MARK: - CLI

/// The "CLI" settings page: an Install button that copies the self-contained `tenon-cli` binary
/// into `~/.local/bin` so agents and scripts can drive Tenon from any terminal.
private struct CLISettingsDetail: View {
    @State private var installedPath: String?
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
                    Button(CLICommandInstaller.isInstalled ? "Reinstall Command" : "Install Command") {
                        install()
                    }
                    .disabled(!CLICommandInstaller.canInstall)

                    if CLICommandInstaller.isInstalled {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                    }
                }

                if let installedPath {
                    Text("Installed to \(installedPath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else if CLICommandInstaller.isInstalled {
                    Text("Installed to \(CLICommandInstaller.installedURL.path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if !CLICommandInstaller.canInstall {
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
        .formStyle(.grouped)
    }

    private func install() {
        do {
            installedPath = try CLICommandInstaller.install().path
            errorMessage = nil
        } catch {
            errorMessage = "\(error)"
        }
    }
}

// MARK: - General

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

// MARK: - Per-plugin settings (generic renderer — the whole point)

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

// MARK: - Extensions (enable/permissions for every plugin, settings or not)

private struct ExtensionsDetail: View {
    var host: PluginHost

    var body: some View {
        Form {
            if host.plugins.isEmpty {
                Section { Text("No plugins installed.").foregroundStyle(.secondary) }
            }
            ForEach(host.plugins) { plugin in
                ExtensionPluginSection(host: host, plugin: plugin)
            }
        }
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
