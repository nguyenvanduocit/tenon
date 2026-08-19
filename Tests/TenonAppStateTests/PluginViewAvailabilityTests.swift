import TenonCore
import TenonIntentCore
import XCTest
@testable import TenonApp

/// T-182 follow-up: `PluginSlotView` used to have exactly one signal — whether
/// `host.pluginViews` already contains this pane's section — and showed the same
/// "Plugin view unavailable" error UI whether a healthy plugin simply hadn't finished
/// activating yet or the generation had genuinely failed. An operator watching a normal load
/// had no way to tell it apart from watching a permanent failure. `PluginViewAvailability`
/// pulls the decision into a pure function so the distinction can be pinned without mounting
/// any view.
final class PluginViewAvailabilityTests: XCTestCase {
    private static let pluginID: PluginID = "dev.tenon.file-explorer"

    func testASectionAlreadyPresentIsReadyRegardlessOfPluginState() {
        let availability = PluginViewAvailability.resolve(
            pluginID: Self.pluginID,
            hasSection: true,
            plugins: []
        )
        XCTAssertEqual(availability, .ready)
    }

    func testALoadedEnabledErrorFreePluginWithNoSectionYetIsActivating() {
        let availability = PluginViewAvailability.resolve(
            pluginID: Self.pluginID,
            hasSection: false,
            plugins: [Self.snapshot(isLoaded: true, isEnabled: true, error: nil)]
        )
        XCTAssertEqual(availability, .activating)
    }

    func testAFailedPluginIsUnavailableWithItsErrorSurfaced() {
        let availability = PluginViewAvailability.resolve(
            pluginID: Self.pluginID,
            hasSection: false,
            plugins: [Self.snapshot(isLoaded: false, isEnabled: true, error: "runtime entered failed phase")]
        )
        XCTAssertEqual(availability, .unavailable(reason: "runtime entered failed phase"))
    }

    func testADisabledPluginIsUnavailableEvenWithoutAnError() {
        let availability = PluginViewAvailability.resolve(
            pluginID: Self.pluginID,
            hasSection: false,
            plugins: [Self.snapshot(isLoaded: false, isEnabled: false, error: nil)]
        )
        XCTAssertEqual(availability, .unavailable(reason: nil))
    }

    func testAPluginMissingFromTheInventoryEntirelyIsUnavailable() {
        let availability = PluginViewAvailability.resolve(
            pluginID: Self.pluginID,
            hasSection: false,
            plugins: []
        )
        XCTAssertEqual(availability, .unavailable(reason: nil))
    }

    /// A generation that is `.active` but flagged an error mid-flight (still loaded, not yet
    /// failed) reads as unavailable rather than activating — an error is never silently upgraded
    /// back to a loading state.
    func testALoadedPluginCarryingAnErrorIsUnavailableNotActivating() {
        let availability = PluginViewAvailability.resolve(
            pluginID: Self.pluginID,
            hasSection: false,
            plugins: [Self.snapshot(isLoaded: true, isEnabled: true, error: "something is wrong")]
        )
        XCTAssertEqual(availability, .unavailable(reason: "something is wrong"))
    }

    private static func snapshot(
        isLoaded: Bool,
        isEnabled: Bool,
        error: String?
    ) -> PluginSnapshot {
        PluginSnapshot(
            id: pluginID,
            installationID: nil,
            name: "File Explorer",
            version: "1.0.0",
            permissions: [],
            unknownPermissions: [],
            settingSpecs: [],
            icon: nil,
            displayName: nil,
            isLoaded: isLoaded,
            isEnabled: isEnabled,
            permissionViolations: [],
            error: error
        )
    }
}
