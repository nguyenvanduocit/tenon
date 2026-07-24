import SwiftUI
import TenonCore

/// The Settings window (⌘,). Everything here is a projection of PluginHost state;
/// per-plugin setting forms are rendered from the manifest's setting specs and
/// written back through `host.setSetting`, which also notifies the plugin.
struct SettingsView: View {
    var host: PluginHost

    var body: some View {
        TabView {
            pluginsTab
                .tabItem { Label("Plugins", systemImage: "puzzlepiece.extension") }
        }
        .frame(width: 560, height: 520)
    }

    private var pluginsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(host.plugins) { plugin in
                    PluginSettingsSection(host: host, plugin: plugin)
                    Divider()
                }
            }
            .padding(16)
        }
    }
}

private struct PluginSettingsSection: View {
    var host: PluginHost
    let plugin: PluginSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(plugin.name) v\(plugin.version)")
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.semibold)
                Spacer()
                Toggle("Enabled", isOn: Binding(
                    get: { plugin.isEnabled },
                    set: { host.setEnabled($0, pluginNamed: plugin.name) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            Text(plugin.permissions.isEmpty
                ? "permissions: none"
                : "permissions: \(plugin.permissions.joined(separator: ", "))")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            if !plugin.unknownPermissions.isEmpty {
                Text("⚠️ unknown: \(plugin.unknownPermissions.joined(separator: ", "))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.orange)
            }
            ForEach(plugin.permissionViolations, id: \.self) { violation in
                Text("⛔ \(violation)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.red)
            }

            ForEach(plugin.settingSpecs, id: \.key) { spec in
                SettingRow(host: host, pluginName: plugin.name, spec: spec)
            }
        }
    }
}

private struct SettingRow: View {
    var host: PluginHost
    let pluginName: String
    let spec: PluginSettingSpec

    @State private var draft = ""
    @State private var numberDraft = 0.0

    var body: some View {
        HStack(spacing: 8) {
            Text(spec.label)
                .frame(width: 160, alignment: .leading)
            switch spec.type {
            case .boolean:
                Toggle(spec.label, isOn: Binding(
                    get: { currentValue() as? Bool ?? false },
                    set: { host.setSetting($0, forKey: spec.key, pluginNamed: pluginName) }
                ))
                .labelsHidden()
            case .string:
                TextField(spec.label, text: $draft)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onAppear { draft = currentValue() as? String ?? "" }
                    .onSubmit { host.setSetting(draft, forKey: spec.key, pluginNamed: pluginName) }
            case .number:
                TextField(spec.label, value: $numberDraft, format: .number)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    .onAppear { numberDraft = currentValue() as? Double ?? 0 }
                    .onSubmit { host.setSetting(numberDraft, forKey: spec.key, pluginNamed: pluginName) }
            }
        }
        .font(.system(size: 12))
    }

    private func currentValue() -> Any? {
        host.settings.value(for: spec.key, plugin: pluginName, default: spec.defaultValue?.anyValue)
    }
}
