// @domain: intent-bus

import Foundation
import Observation
import SwiftUI
import TenonCore
import TenonIntentCore

struct IntentUIPickItem: Identifiable, Sendable, Equatable {
    let id: String
    let label: String
    let detail: String?
    let icon: String?
}

enum IntentToastKind: String, Sendable, Equatable {
    case info
    case success
    case warning
    case error
}

enum IntentUIRequestKind: Sendable, Equatable {
    case pick(items: [IntentUIPickItem], placeholder: String?)
    case prompt(title: String, initialValue: String, multiline: Bool)
    case confirm(title: String, detail: String?, destructive: Bool)
    case permission(title: String, detail: String, destructive: Bool)
}

struct IntentUIRequest: Identifiable, Sendable, Equatable {
    let id: UUID
    let kind: IntentUIRequestKind
}

enum IntentUIResponse: Sendable, Equatable {
    case selectedID(String?)
    case text(String?)
    case confirmed(Bool)
    case permission(IntentConfirmationDecision)
}

/// App-owned presentation state for interactive intents.
///
/// Requests are queued in arrival order. Their continuations remain private to this
/// MainActor-isolated state machine, so provider cancellation and user dismissal both
/// settle exactly once without exposing callbacks or untyped values to the plugin host.
@MainActor
@Observable
final class PluginUIState {
    struct Toast: Identifiable, Sendable, Equatable {
        let id: UUID
        let message: String
        let kind: IntentToastKind
    }

    private enum Registration {
        case registering
        case waiting(CheckedContinuation<IntentUIResponse, any Error>)
        case cancelled
    }

    private(set) var pending: [IntentUIRequest] = []
    private(set) var toasts: [Toast] = []

    var query = ""
    var selection = 0
    var draft = ""
    var promptError: String?

    var canSubmitPrompt: Bool {
        draft.utf8.count
            <= CoreIntentPayloadPolicy.maximumInlineTextCharacters
    }

    /// Where the operator's standing answer to permission confirmations comes from.
    ///
    /// A closure the composition root points at the preferences store, read at the moment a
    /// confirmation arrives rather than copied into a stored flag — so the switch in
    /// Settings governs the next request with nothing to keep in step and nothing to go
    /// stale. It starts off: the safe direction for a wiring mistake is asking a question
    /// nobody wanted rather than silently answering one nobody saw, and only one of those
    /// two failures is visible.
    @ObservationIgnored
    var bypassesPermissionPrompts: @MainActor @Sendable () -> Bool = { false }

    @ObservationIgnored private var registrations: [UUID: Registration] = [:]
    @ObservationIgnored private var toastTasks: [UUID: Task<Void, Never>] = [:]

    var current: IntentUIRequest? {
        pending.first
    }

    func request(
        id: UUID = UUID(),
        kind: IntentUIRequestKind
    ) async throws -> IntentUIResponse {
        guard registrations[id] == nil else {
            throw CancellationError()
        }

        let request = IntentUIRequest(id: id, kind: kind)
        registrations[id] = .registering

        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    register(request, continuation: continuation)
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.cancel(id: id)
                }
            }
        } catch {
            registrations.removeValue(forKey: id)
            removePending(id: id)
            throw error
        }
    }

    func showToast(
        message: String,
        kind: IntentToastKind,
        id: UUID = UUID()
    ) {
        toastTasks[id]?.cancel()
        toasts.removeAll { $0.id == id }
        toasts.append(Toast(id: id, message: message, kind: kind))

        toastTasks[id] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(3_200))
            } catch {
                return
            }
            guard let self else { return }
            self.toasts.removeAll { $0.id == id }
            self.toastTasks.removeValue(forKey: id)
        }
    }

    func dismissCurrent() {
        guard let request = current else { return }
        switch request.kind {
        case .pick:
            completeCurrent(with: .selectedID(nil))
        case .prompt:
            completeCurrent(with: .text(nil))
        case .confirm:
            completeCurrent(with: .confirmed(false))
        case .permission:
            completeCurrent(with: .permission(.denied))
        }
    }

    func choose(_ itemID: String) {
        guard let request = current,
              case let .pick(items, _) = request.kind,
              items.contains(where: { $0.id == itemID })
        else {
            return
        }
        completeCurrent(with: .selectedID(itemID))
    }

    func submitPrompt() {
        guard let request = current,
              case .prompt = request.kind
        else {
            return
        }
        guard canSubmitPrompt else {
            promptError =
                "Text exceeds the \(CoreIntentPayloadPolicy.maximumInlineTextCharacters)-byte limit."
            return
        }
        promptError = nil
        completeCurrent(with: .text(draft))
    }

    func confirmCurrent() {
        guard let request = current,
              case .confirm = request.kind
        else {
            return
        }
        completeCurrent(with: .confirmed(true))
    }

    func resolvePermission(_ decision: IntentConfirmationDecision) {
        guard let request = current,
              case .permission = request.kind
        else {
            return
        }
        completeCurrent(with: .permission(decision))
    }

    func filteredItems(_ items: [IntentUIPickItem]) -> [IntentUIPickItem] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return items }
        return items.filter {
            $0.label.lowercased().contains(needle)
                || ($0.detail?.lowercased().contains(needle) ?? false)
        }
    }

    /// Points the permission answer at the live preferences store. One call, at the
    /// composition root, and every later change to the switch is already accounted for.
    func adopt(_ preferences: AppPreferencesStore) {
        bypassesPermissionPrompts = { preferences.preferences.bypassAllPermissionPrompts }
    }

    /// Takes the operator's standing answer, or nothing when they still have to be asked.
    ///
    /// `.allowOnce` and not `.alwaysAllow`: the switch leaves no consent record behind, so
    /// turning it off restores asking with nothing carried over from the time it was on.
    /// A remembered grant would outlive the switch and quietly keep approving.
    func standingPermissionAnswer() -> IntentConfirmationDecision? {
        bypassesPermissionPrompts() ? .allowOnce : nil
    }

    func confirmationAuthorizer() -> IntentConfirmationAuthorizer {
        IntentConfirmationAuthorizer { [weak self] request in
            guard let self else { return .denied }
            if let standing = await self.standingPermissionAnswer() {
                return standing
            }
            do {
                let title = request.contract.title
                    ?? request.contract.name.rawValue
                let detail = await Self.confirmationDetail(request)
                let kind: IntentUIRequestKind = if request.confirmation == .policy {
                    .permission(
                        title: title,
                        detail: detail,
                        destructive: request.contract.effects.kind == .destructive
                    )
                } else {
                    .confirm(
                        title: title,
                        detail: detail,
                        destructive: request.contract.effects.kind == .destructive
                    )
                }
                let response = try await self.request(
                    kind: kind
                )
                switch response {
                case let .permission(decision):
                    return decision
                case .confirmed(true):
                    return .allowOnce
                case .confirmed(false), .selectedID, .text:
                    return .denied
                }
            } catch {
                return .denied
            }
        }
    }
}

private extension PluginUIState {
    func register(
        _ request: IntentUIRequest,
        continuation: CheckedContinuation<IntentUIResponse, any Error>
    ) {
        switch registrations[request.id] {
        case .registering:
            registrations[request.id] = .waiting(continuation)
            pending.append(request)
            if pending.count == 1 {
                resetEditingState(for: request)
            }

        case .cancelled:
            registrations.removeValue(forKey: request.id)
            continuation.resume(throwing: CancellationError())

        case .waiting, .none:
            continuation.resume(throwing: CancellationError())
        }
    }

    func cancel(id: UUID) {
        switch registrations[id] {
        case .registering:
            registrations[id] = .cancelled

        case let .waiting(continuation):
            registrations.removeValue(forKey: id)
            removePending(id: id)
            continuation.resume(throwing: CancellationError())

        case .cancelled, .none:
            break
        }
    }

    func completeCurrent(with response: IntentUIResponse) {
        guard let request = pending.first else { return }
        pending.removeFirst()

        guard case let .waiting(continuation) =
            registrations.removeValue(forKey: request.id)
        else {
            if let next = pending.first {
                resetEditingState(for: next)
            }
            return
        }

        if let next = pending.first {
            resetEditingState(for: next)
        }
        continuation.resume(returning: response)
    }

    func removePending(id: UUID) {
        let removedCurrent = pending.first?.id == id
        pending.removeAll { $0.id == id }
        if removedCurrent, let next = pending.first {
            resetEditingState(for: next)
        }
    }

    func resetEditingState(for request: IntentUIRequest) {
        query = ""
        selection = 0
        promptError = nil
        if case let .prompt(_, initialValue, _) = request.kind {
            draft = initialValue
        } else {
            draft = ""
        }
    }

    static func confirmationDetail(
        _ request: IntentConfirmationRequest
    ) -> String {
        let effect = request.contract.effects.kind.rawValue
        let destination = request.contract.effects.external
            ? "external destination"
            : "this Mac"
        return "\(request.envelope.caller.id) requests a \(effect) action on \(destination)."
    }
}

@MainActor
final class UserInteractionIntentProvider {
    private let state: PluginUIState

    init(state: PluginUIState) {
        self.state = state
    }

    func bindings() throws -> [IntentProviderBinding] {
        [
            IntentProviderBinding(
                intentID: try CoreIntentName.uiPick.intentID
            ) { envelope, context in
                try context.checkCancellation()
                let reply = try await self.pick(envelope.input)
                try context.checkCancellation()
                return reply
            },
            IntentProviderBinding(
                intentID: try CoreIntentName.uiPrompt.intentID
            ) { envelope, context in
                try context.checkCancellation()
                let reply = try await self.prompt(envelope.input)
                try context.checkCancellation()
                return reply
            },
            IntentProviderBinding(
                intentID: try CoreIntentName.uiConfirm.intentID
            ) { envelope, context in
                try context.checkCancellation()
                let reply = try await self.confirm(envelope.input)
                try context.checkCancellation()
                return reply
            },
            IntentProviderBinding(
                intentID: try CoreIntentName.uiToast.intentID
            ) { envelope, context in
                try context.checkCancellation()
                let reply = await self.toast(envelope.input)
                try context.checkCancellation()
                return reply
            },
        ]
    }
}

private extension UserInteractionIntentProvider {
    func pick(_ input: IntentValue) async throws -> IntentProviderReply {
        do {
            let object = try AppIntentProviderSupport.object(input)
            let items = try AppIntentProviderSupport
                .objectArray("items", in: object)
                .map { item in
                    IntentUIPickItem(
                        id: try AppIntentProviderSupport.string(
                            "id",
                            in: item
                        ),
                        label: try AppIntentProviderSupport.string(
                            "label",
                            in: item
                        ),
                        detail: try AppIntentProviderSupport.optionalString(
                            "detail",
                            in: item
                        ),
                        icon: try AppIntentProviderSupport.optionalString(
                            "icon",
                            in: item
                        )
                    )
                }
            let response = try await state.request(
                kind: .pick(
                    items: items,
                    placeholder: try AppIntentProviderSupport.optionalString(
                        "placeholder",
                        in: object
                    )
                )
            )
            guard case let .selectedID(selectedID) = response else {
                return AppIntentProviderSupport.invalidInput(.expectedObject)
            }
            return .success(
                .object([
                    "selectedID": selectedID.map(IntentValue.string) ?? .null,
                ])
            )
        } catch let error as AppIntentInputError {
            return AppIntentProviderSupport.invalidInput(error)
        }
    }

    func prompt(_ input: IntentValue) async throws -> IntentProviderReply {
        do {
            let object = try AppIntentProviderSupport.object(input)
            let response = try await state.request(
                kind: .prompt(
                    title: try AppIntentProviderSupport.string(
                        "title",
                        in: object
                    ),
                    initialValue: try AppIntentProviderSupport.optionalString(
                        "initialValue",
                        in: object
                    ) ?? "",
                    multiline: try AppIntentProviderSupport.bool(
                        "multiline",
                        in: object
                    )
                )
            )
            guard case let .text(value) = response else {
                return AppIntentProviderSupport.invalidInput(.expectedObject)
            }
            return .success(
                .object([
                    "value": value.map(IntentValue.string) ?? .null,
                ])
            )
        } catch let error as AppIntentInputError {
            return AppIntentProviderSupport.invalidInput(error)
        }
    }

    func confirm(_ input: IntentValue) async throws -> IntentProviderReply {
        do {
            let object = try AppIntentProviderSupport.object(input)
            let response = try await state.request(
                kind: .confirm(
                    title: try AppIntentProviderSupport.string(
                        "title",
                        in: object
                    ),
                    detail: nil,
                    destructive: try AppIntentProviderSupport.bool(
                        "destructive",
                        in: object
                    )
                )
            )
            guard case let .confirmed(confirmed) = response else {
                return AppIntentProviderSupport.invalidInput(.expectedObject)
            }
            return .success(
                .object(["confirmed": .bool(confirmed)])
            )
        } catch let error as AppIntentInputError {
            return AppIntentProviderSupport.invalidInput(error)
        }
    }

    func toast(_ input: IntentValue) -> IntentProviderReply {
        do {
            let object = try AppIntentProviderSupport.object(input)
            let kindValue = try AppIntentProviderSupport.string(
                "kind",
                in: object
            )
            guard let kind = IntentToastKind(rawValue: kindValue) else {
                return AppIntentProviderSupport.invalidInput(
                    .missingOrInvalidField("kind")
                )
            }
            state.showToast(
                message: try AppIntentProviderSupport.string(
                    "message",
                    in: object
                ),
                kind: kind
            )
            return AppIntentProviderSupport.emptySuccess
        } catch let error as AppIntentInputError {
            return AppIntentProviderSupport.invalidInput(error)
        } catch {
            return AppIntentProviderSupport.invalidInput(.expectedObject)
        }
    }
}

/// Renders the presented interactive intent plus any live toasts.
struct PluginUIOverlay: View {
    @Bindable var state: PluginUIState
    /// How far above the window's bottom edge a toast must sit so it clears the foot row.
    /// Supplied rather than assumed, because that row is as tall as whichever strip the
    /// chrome order gave it — 24 pt of status text, or a 34 pt row of tab chips.
    let bottomInset: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var inputFocused: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let request = state.current {
                dialog(request)
            }
            if !state.toasts.isEmpty {
                toastStack
            }
        }
    }

    @ViewBuilder
    private func dialog(_ request: IntentUIRequest) -> some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { state.dismissCurrent() }

            card(request)
                .frame(width: 560)
                .background(TenonTheme.chromeRaised)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 12,
                        style: .continuous
                    )
                )
                .overlay(
                    RoundedRectangle(
                        cornerRadius: 12,
                        style: .continuous
                    )
                    .strokeBorder(TenonTheme.line, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
                .padding(.top, 120)

            Button("", action: state.dismissCurrent)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .onAppear { inputFocused = true }
        .onChange(of: request.id) { _, _ in inputFocused = true }
    }

    @ViewBuilder
    private func card(_ request: IntentUIRequest) -> some View {
        switch request.kind {
        case let .pick(items, placeholder):
            pickCard(
                items: items,
                placeholder: placeholder ?? "Select…"
            )
        case let .prompt(title, _, multiline):
            promptCard(title: title, multiline: multiline)
        case let .confirm(title, detail, destructive):
            confirmCard(
                title: title,
                detail: detail,
                destructive: destructive
            )
        case let .permission(title, detail, destructive):
            permissionCard(
                title: title,
                detail: detail,
                destructive: destructive
            )
        }
    }

    private func pickCard(
        items: [IntentUIPickItem],
        placeholder: String
    ) -> some View {
        let matches = state.filteredItems(items)
        let selected = matches.isEmpty
            ? 0
            : min(state.selection, matches.count - 1)

        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(TenonTheme.muted)
                TextField(placeholder, text: $state.query)
                    .textFieldStyle(.plain)
                    .font(TenonTheme.interfaceFont(size: 16))
                    .foregroundStyle(TenonTheme.text)
                    .focused($inputFocused)
                    .onSubmit { choose(matches, at: selected) }
                    .onChange(of: state.query) { _, _ in
                        state.selection = 0
                    }
                    .accessibilityIdentifier("tenon.ui.pick.search")
            }
            .padding(.horizontal, 16)
            .frame(height: 52)

            Rectangle().fill(TenonTheme.line).frame(height: 1)

            if matches.isEmpty {
                Text("No matches")
                    .font(TenonTheme.interfaceFont(size: 13))
                    .foregroundStyle(TenonTheme.muted)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                    .padding(.horizontal, 16)
                    .frame(height: 56)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(
                            Array(matches.enumerated()),
                            id: \.element.id
                        ) { index, item in
                            Button { state.choose(item.id) } label: {
                                pickRow(
                                    item,
                                    isSelected: index == selected
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(
                                index == selected ? .isSelected : []
                            )
                            .accessibilityIdentifier(
                                "tenon.ui.pick.row.\(item.id)"
                            )
                        }
                    }
                    .padding(.vertical, 6)
                }
                .tenonScrollbarStyle()
                .frame(maxHeight: 320)
            }
        }
        .onKeyPress(.downArrow) {
            move(1, in: matches)
            return .handled
        }
        .onKeyPress(.upArrow) {
            move(-1, in: matches)
            return .handled
        }
    }

    private func pickRow(
        _ item: IntentUIPickItem,
        isSelected: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon ?? "circle.fill")
                .font(.system(size: item.icon == nil ? 5 : 12))
                .frame(width: 18)
                .foregroundStyle(
                    isSelected ? TenonTheme.amber : TenonTheme.muted
                )
            Text(item.label)
                .font(TenonTheme.interfaceFont(size: 14))
                .foregroundStyle(TenonTheme.text)
                .lineLimit(1)
            Spacer(minLength: 12)
            if let detail = item.detail {
                Text(detail)
                    .font(TenonTheme.interfaceFont(size: 12))
                    .foregroundStyle(TenonTheme.muted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(
            isSelected
                ? TenonTheme.amber.opacity(0.16)
                : Color.clear
        )
    }

    private func promptCard(
        title: String,
        multiline: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(
                    TenonTheme.interfaceFont(
                        size: 15,
                        weight: .semibold
                    )
                )
                .foregroundStyle(TenonTheme.text)

            Group {
                if multiline {
                    TextEditor(text: $state.draft)
                        .font(TenonTheme.interfaceFont(size: 13))
                        .scrollContentBackground(.hidden)
                        .tenonScrollbarStyle()
                        .frame(height: 96)
                } else {
                    TextField("", text: $state.draft)
                        .textFieldStyle(.plain)
                        .font(TenonTheme.interfaceFont(size: 14))
                        .onSubmit(state.submitPrompt)
                }
            }
            .foregroundStyle(TenonTheme.text)
            .focused($inputFocused)
            .onChange(of: state.draft) { _, _ in
                if state.canSubmitPrompt {
                    state.promptError = nil
                }
            }
            .padding(8)
            .background(TenonTheme.panel)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 6,
                    style: .continuous
                )
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: 6,
                    style: .continuous
                )
                .strokeBorder(TenonTheme.line, lineWidth: 1)
            )
            .accessibilityIdentifier("tenon.ui.prompt.field")

            if let promptError = state.promptError {
                Text(promptError)
                    .font(TenonTheme.utilityFont(size: 10))
                    .foregroundStyle(Color.red.opacity(0.9))
            }

            buttons(
                confirmLabel: "OK",
                destructive: false,
                confirmDisabled: !state.canSubmitPrompt,
                confirm: state.submitPrompt
            )
        }
        .padding(18)
    }

    private func confirmCard(
        title: String,
        detail: String?,
        destructive: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(
                    TenonTheme.interfaceFont(
                        size: 15,
                        weight: .semibold
                    )
                )
                .foregroundStyle(TenonTheme.text)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(TenonTheme.interfaceFont(size: 12))
                    .foregroundStyle(TenonTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons(
                confirmLabel: destructive ? "Confirm" : "Allow",
                destructive: destructive,
                confirm: state.confirmCurrent
            )
            .padding(.top, 6)
        }
        .padding(18)
    }

    private func permissionCard(
        title: String,
        detail: String,
        destructive: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(
                    TenonTheme.interfaceFont(
                        size: 15,
                        weight: .semibold
                    )
                )
                .foregroundStyle(TenonTheme.text)
                .fixedSize(horizontal: false, vertical: true)

            Text(detail)
                .font(TenonTheme.interfaceFont(size: 12))
                .foregroundStyle(TenonTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            Text(
                "Always Allow remembers this intent. Always Allow for This User trusts "
                    + "this requester for every permission-gated intent."
            )
            .font(TenonTheme.utilityFont(size: 10))
            .foregroundStyle(TenonTheme.muted)
            .fixedSize(horizontal: false, vertical: true)

            permissionButtons(destructive: destructive)
                .padding(.top, 6)
        }
        .padding(18)
    }

    private func permissionButtons(destructive: Bool) -> some View {
        HStack(spacing: 8) {
            Button("Cancel", action: state.dismissCurrent)
                .buttonStyle(.plain)
                .font(TenonTheme.interfaceFont(size: 12))
                .foregroundStyle(TenonTheme.muted)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(TenonTheme.panel)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 6,
                        style: .continuous
                    )
                )

            Spacer(minLength: 4)

            permissionButton(
                "Always Allow for This User",
                decision: .alwaysAllowForCaller,
                destructive: destructive
            )
            permissionButton(
                "Always Allow",
                decision: .alwaysAllow,
                destructive: destructive
            )
            permissionButton(
                "Allow Once",
                decision: .allowOnce,
                destructive: destructive,
                primary: true
            )
            .keyboardShortcut(.defaultAction)
        }
    }

    private func permissionButton(
        _ label: String,
        decision: IntentConfirmationDecision,
        destructive: Bool,
        primary: Bool = false
    ) -> some View {
        Button(label) {
            state.resolvePermission(decision)
        }
        .buttonStyle(.plain)
        .font(
            TenonTheme.interfaceFont(
                size: 12,
                weight: primary ? .semibold : .regular
            )
        )
        .foregroundStyle(
            primary
                ? (destructive ? Color.white : TenonTheme.ink)
                : (destructive ? Color.red.opacity(0.9) : TenonTheme.text)
        )
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            primary
                ? (destructive ? Color.red.opacity(0.85) : TenonTheme.amber)
                : TenonTheme.panel
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: 6,
                style: .continuous
            )
        )
        .accessibilityIdentifier(
            "tenon.ui.permission.\(permissionIdentifier(for: decision))"
        )
    }

    private func permissionIdentifier(
        for decision: IntentConfirmationDecision
    ) -> String {
        switch decision {
        case .allowOnce:
            "allow-once"
        case .alwaysAllow:
            "always-allow"
        case .alwaysAllowForCaller:
            "always-allow-for-caller"
        case .denied:
            "deny"
        }
    }

    private func buttons(
        confirmLabel: String,
        destructive: Bool,
        confirmDisabled: Bool = false,
        confirm: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Spacer()
            Button("Cancel", action: state.dismissCurrent)
                .buttonStyle(.plain)
                .font(TenonTheme.interfaceFont(size: 13))
                .foregroundStyle(TenonTheme.muted)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(TenonTheme.panel)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 6,
                        style: .continuous
                    )
                )

            Button(confirmLabel, action: confirm)
                .disabled(confirmDisabled)
                .buttonStyle(.plain)
                .font(
                    TenonTheme.interfaceFont(
                        size: 13,
                        weight: .semibold
                    )
                )
                .foregroundStyle(
                    destructive ? Color.white : TenonTheme.ink
                )
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(
                    destructive
                        ? Color.red.opacity(0.85)
                        : TenonTheme.amber
                )
                .opacity(confirmDisabled ? 0.45 : 1)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 6,
                        style: .continuous
                    )
                )
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("tenon.ui.confirm")
        }
    }

    private func move(
        _ delta: Int,
        in matches: [IntentUIPickItem]
    ) {
        guard !matches.isEmpty else { return }
        state.selection = min(
            max(state.selection + delta, 0),
            matches.count - 1
        )
    }

    private func choose(
        _ matches: [IntentUIPickItem],
        at index: Int
    ) {
        guard matches.indices.contains(index) else {
            state.dismissCurrent()
            return
        }
        state.choose(matches[index].id)
    }

    private var toastStack: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(state.toasts) { toast in
                HStack(spacing: 8) {
                    Image(systemName: icon(for: toast.kind))
                        .foregroundStyle(tint(for: toast.kind))
                    Text(toast.message)
                        .font(TenonTheme.interfaceFont(size: 13))
                        .foregroundStyle(TenonTheme.text)
                        .lineLimit(2)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(TenonTheme.chromeRaised)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 8,
                        style: .continuous
                    )
                )
                .overlay(
                    RoundedRectangle(
                        cornerRadius: 8,
                        style: .continuous
                    )
                    .strokeBorder(TenonTheme.line, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                .frame(maxWidth: 380, alignment: .trailing)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .move(edge: .trailing).combined(with: .opacity)
                )
            }
        }
        .padding(.trailing, 16)
        .padding(.bottom, bottomInset)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: state.toasts)
    }

    private func icon(for kind: IntentToastKind) -> String {
        switch kind {
        case .success:
            "checkmark.circle.fill"
        case .error:
            "exclamationmark.triangle.fill"
        case .warning:
            "exclamationmark.circle.fill"
        case .info:
            "info.circle.fill"
        }
    }

    private func tint(for kind: IntentToastKind) -> Color {
        switch kind {
        case .success:
            .green
        case .error:
            .red
        case .warning:
            TenonTheme.amber
        case .info:
            TenonTheme.muted
        }
    }
}
