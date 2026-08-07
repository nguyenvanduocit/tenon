// @domain: plugin-contributions
import Foundation
import TenonIntentCore

/// What the live generations put on screen, derived in one place from their snapshots.
///
/// Six published surfaces — the status bar, the view sections, the intent presentations, the
/// palette provider sections, the key-binding index and the command index — all fall out of the
/// same ordered list of snapshots, and used to be computed inline in `PluginHost.publish()`
/// among the host's own bookkeeping. They are not bookkeeping: they are a projection, total and
/// deterministic, and the only thing they need from the host is the order and the palette
/// revision.
///
/// Pure by construction, so what a generation may put on screen can be asserted without a host,
/// a runtime, or a window.
struct PluginContributionProjection: Equatable {
    let statusItems: [StatusItem]
    let views: [PluginViewSection]
    let intentPresentations: [PluginIntentPresentation]
    let paletteSections: [PaletteProviderSection]
    let keyBindingIndex: KeyBindingIndex
    let commandIndex: CommandIndex

    /// - Parameter orderedSnapshots: live generations in the host's stable publish order. The
    ///   order is the host's to decide and this type's to preserve: a contribution list that
    ///   reshuffles between renders moves what a person is about to click.
    /// - Parameter paletteQueryRevision: the question currently being asked. A provider's
    ///   results are shown only when they answer *this* revision; anything older is the
    ///   provider's pending row, because a stale answer under a new question is a wrong answer.
    static func make(
        orderedSnapshots: [(PluginID, PluginRuntimeSnapshot)],
        paletteQueryRevision: Int
    ) -> PluginContributionProjection {
        let statusItems = orderedSnapshots.compactMap { pluginID, snapshot in
            snapshot.statusBarText.map { StatusItem(pluginID: pluginID, text: $0) }
        }

        let views = orderedSnapshots.flatMap { pluginID, snapshot in
            snapshot.views.map { view in
                PluginViewSection(
                    pluginID: pluginID,
                    viewID: view.viewID,
                    instanceID: view.instanceID,
                    instanced: view.instanced,
                    title: view.title,
                    items: view.items,
                    body: view.body,
                    header: view.header,
                    modal: view.modal
                )
            }
        }

        let presentations = orderedSnapshots.flatMap { pluginID, snapshot in
            PluginIntentPresentation.projected(
                for: snapshot.manifest,
                pluginID: pluginID
            )
        }

        let paletteSections = orderedSnapshots.flatMap { pluginID, snapshot in
            snapshot.paletteProviders.map { provider in
                let isCurrent = provider.publishedRevision == paletteQueryRevision
                    && paletteQueryRevision > 0
                return PaletteProviderSection(
                    pluginID: pluginID,
                    providerID: provider.providerID,
                    title: provider.title,
                    isPending: !isCurrent && paletteQueryRevision > 0,
                    results: isCurrent ? provider.results : []
                )
            }
        }

        let keyBindingIndex = KeyBindingIndex(
            requests: presentations.compactMap { presentation in
                presentation.key.map { key in
                    KeyBindingRequest(
                        target: KeyBindingTarget(
                            pluginID: presentation.pluginID,
                            intentID: presentation.intentID
                        ),
                        rawKey: key
                    )
                }
            },
            reserved: KeyBindingIndex.shellReserved
        )

        let commandIndex = CommandIndex(
            presentations.map { presentation in
                presentation.command(
                    assignedKey: keyBindingIndex.binding(
                        for: KeyBindingTarget(
                            pluginID: presentation.pluginID,
                            intentID: presentation.intentID
                        )
                    )?.chord
                )
            }
        )

        return PluginContributionProjection(
            statusItems: statusItems,
            views: views,
            intentPresentations: presentations,
            paletteSections: paletteSections,
            keyBindingIndex: keyBindingIndex,
            commandIndex: commandIndex
        )
    }
}
