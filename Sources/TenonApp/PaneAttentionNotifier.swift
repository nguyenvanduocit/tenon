// @domain: attention
import AppKit
import Foundation
import UserNotifications

/// The host-native completion-notification adapter (T-029): projects one poll pass's
/// `.becameUnseen` batch into at most one system notification, and only while the app
/// is not frontmost — a human already looking at Tenon needs no banner. Delivery is an
/// injected closure so the decision (fire or not, one alert per burst, wording) stays
/// headlessly asserted; the system half lives in `SystemNotificationDelivery`.
@MainActor
final class PaneAttentionNotifier {
    struct Alert: Equatable {
        let title: String
        let body: String
        /// The panes this alert speaks for. Activation focuses the first, which makes
        /// it viewed, which clears the bold — the machine's one clearing path.
        let slotIDs: [UUID]
    }

    private let isAppFrontmost: () -> Bool
    private let deliver: (Alert) -> Void

    init(
        isAppFrontmost: @escaping () -> Bool,
        deliver: @escaping (Alert) -> Void
    ) {
        self.isAppFrontmost = isAppFrontmost
        self.deliver = deliver
    }

    /// One poll pass's batch of panes that started needing a human.
    func panesBecameUnseen(_ slotIDs: [UUID], titles: [UUID: String]) {
        guard !isAppFrontmost(),
              let alert = Self.alert(for: slotIDs, titles: titles)
        else { return }
        deliver(alert)
    }

    /// The pure wording rule: one pane is named by its title, a burst is counted.
    static func alert(for slotIDs: [UUID], titles: [UUID: String]) -> Alert? {
        guard let first = slotIDs.first else { return nil }
        if slotIDs.count == 1 {
            return Alert(
                title: "Tenon",
                body: "\(titles[first] ?? "A pane") needs your attention",
                slotIDs: slotIDs
            )
        }
        return Alert(
            title: "Tenon",
            body: "\(slotIDs.count) panes need your attention",
            slotIDs: slotIDs
        )
    }
}

/// The system half: hands an `Alert` to `UNUserNotificationCenter` and routes the
/// click back to the pane. Activation focuses the pane, which satisfies the viewed
/// rule, which clears the bold — this adapter owns no second clearing path.
///
/// `UNUserNotificationCenter` requires a real app bundle; a bare `swift run tenon`
/// executable has no bundle identifier, so delivery degrades to a silent no-op there
/// instead of crashing the host. Tests never reach this type — they inject `deliver`.
@MainActor
final class SystemNotificationDelivery: NSObject, UNUserNotificationCenterDelegate {
    static let shared = SystemNotificationDelivery()

    /// Wired by the composition root: activate the app and focus this slot.
    var onActivate: ((UUID) -> Void)?

    private var authorizationRequested = false

    func deliver(_ alert: PaneAttentionNotifier.Alert) {
        guard Bundle.main.bundleIdentifier != nil,
              NSClassFromString("XCTestCase") == nil
        else { return }
        let center = UNUserNotificationCenter.current()
        if !authorizationRequested {
            authorizationRequested = true
            center.delegate = self
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        if let first = alert.slotIDs.first {
            content.userInfo = ["tenonSlotID": first.uuidString]
        }
        center.add(
            UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
        )
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let slotString = response.notification.request.content
            .userInfo["tenonSlotID"] as? String
        if let slotID = slotString.flatMap(UUID.init(uuidString:)) {
            Task { @MainActor in
                SystemNotificationDelivery.shared.onActivate?(slotID)
            }
        }
        completionHandler()
    }
}
