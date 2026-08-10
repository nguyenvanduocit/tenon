// @domain: plugin-host
import Foundation
import TenonIntentCore

struct PluginParsedViewBody: Sendable {
    let items: [TreeRowItem]
    let body: PluginViewNode?
    let header: PaneHeader
    let modal: PluginViewModal?
    /// One line per header item the plugin wrote and the host will not draw.
    ///
    /// They are carried OUT rather than logged here because parsing a CONTRIBUTION may perform
    /// no imperative mutation — including writing to the plugin's log, which is a host facility
    /// and not a value. The runtime, which knows who published and into which view, emits them.
    let diagnostics: [String]
}

/// A decoded header and the reasons any of its items are missing from it.
struct PluginParsedHeader: Sendable {
    /// The most lines one `views.set` may say back about its header. Sized just above the
    /// thirteen items a header can hold, so a plausible mistake is named in full and only an
    /// implausible one is counted.
    static let maximumDiagnostics = 16

    let header: PaneHeader
    let diagnostics: [String]

    static let empty = PluginParsedHeader(header: .empty, diagnostics: [])
}

enum PluginRuntimeValueParsing {
    static func rows(from value: IntentValue?) -> [TreeRowItem] {
        guard let values = value?.arrayValue else { return [] }
        return values.compactMap { row in
            guard let object = row.objectValue,
                  let idValue = object["id"],
                  let label = object["label"]?.stringValue
            else {
                return nil
            }

            return TreeRowItem(
                // Unrecognised is `.row`, like every other token field in this decoder: a
                // typo in an adjective costs the adjective, never the row.
                kind: TreeRowItem.Kind(rawValue: object["kind"]?.stringValue ?? "") ?? .row,
                id: actionIdentifier(from: idValue),
                label: label,
                detail: object["detail"]?.stringValue,
                depth: max(0, object["depth"]?.intValue ?? 0),
                icon: object["icon"]?.stringValue,
                expanded: object["expanded"]?.boolValue,
                menu: menu(from: object["menu"]),
                editing: object["editing"]?.boolValue ?? false,
                placeholder: object["placeholder"]?.stringValue,
                selected: object["selected"]?.boolValue ?? false,
                accessory: accessory(from: object["accessory"]),
                path: object["path"]?.stringValue
            )
        }
    }

    /// A row's trailing token. `RowAccessory.init?` owns the bound, so an over-long or empty
    /// one drops the accessory and keeps the row — the same fail-soft rule the header items
    /// follow, for the same reason: an author's mistake about ONE decoration must not cost
    /// the file name it was decorating.
    private static func accessory(from value: IntentValue?) -> RowAccessory? {
        guard let object = value?.objectValue,
              let text = object["text"]?.stringValue
        else {
            return nil
        }
        return RowAccessory(text: text, tint: ColorToken(token: object["tint"]?.stringValue))
    }

    static func viewBody(from value: IntentValue) -> PluginParsedViewBody {
        let object = value.objectValue ?? [:]
        let header = header(from: object["header"])
        return PluginParsedViewBody(
            items: rows(from: object["items"]),
            body: object["body"]?.objectValue.flatMap(node(from:)),
            header: header.header,
            modal: object["modal"]?.objectValue.flatMap(modal(from:)),
            diagnostics: header.diagnostics
        )
    }

    /// A header is present or it is not: an absent, null or non-object `header` clears the
    /// previous one. That is how a plugin takes a control away — `views.set` without the key —
    /// and it is the same rule `modal` follows, for the same reason: the published state IS the
    /// state, so anything the plugin stopped saying it stopped meaning.
    ///
    /// Bounds are not applied here. `PaneHeader.admitting` runs `PaneHeaderItem.bounded()` over
    /// everything it accepts, so a plugin's header is clamped by the same code a built-in
    /// pane's is (invariant 10) rather than by a second, JSON-side copy of the rules.
    static func header(from value: IntentValue?) -> PluginParsedHeader {
        guard let object = value?.objectValue else { return .empty }
        let leading = headerItems(from: object["leading"], slot: "leading")
        let trailing = headerItems(from: object["trailing"], slot: "trailing")
        // Admission decides the two drops this decoder cannot see coming — an id already
        // spoken for, and a slot that is full — so it is asked for its reasons rather than
        // only for its result. Every way an item can be lost is now a sentence, which is
        // what the contract above actually promises.
        let admission = PaneHeader.admitting(
            leading: leading.compactMap(\.item),
            trailing: trailing.compactMap(\.item)
        )
        return PluginParsedHeader(
            header: admission.header,
            diagnostics: capped(
                (leading + trailing).compactMap(\.diagnostic)
                    + admission.refused.map(sentence(for:))
            )
        )
    }

    /// One sentence per item admission refused, in the same shape the field-level ones take:
    /// the slot, the item, then what went wrong in the author's own vocabulary.
    private static func sentence(for refused: PaneHeader.RefusedItem) -> String {
        let subject = "dropped \(refused.slot.rawValue) header item \"\(refused.id)\": "
        switch refused.reason {
        case .duplicateID:
            return subject + "another header item is already using that id"
        case .slotIsFull:
            return subject
                + "a header's \(refused.slot.rawValue) slot holds at most "
                + "\(refused.slot.capacity) items"
        }
    }

    /// Bounds what one `views.set` can say back.
    ///
    /// Each line is delivered by launching a host task, and that ledger is finite (512 per
    /// runtime): a `header` may legally carry one full `IntentValue` collection per slot —
    /// 1,024 each, 2,048 lines — so an all-malformed header would saturate the ledger four
    /// times over and start dropping the very diagnostics this feature exists to deliver,
    /// along with every other log line the plugin has in flight. Reporting the first few and
    /// counting the rest keeps the channel inside its own bound (invariant 10) while still
    /// telling an author both what went wrong and how much of it there was.
    private static func capped(_ diagnostics: [String]) -> [String] {
        guard diagnostics.count > PluginParsedHeader.maximumDiagnostics else {
            return diagnostics
        }
        let named = diagnostics.prefix(PluginParsedHeader.maximumDiagnostics - 1)
        return named + [
            "dropped \(diagnostics.count - named.count) further header items, "
                + "not named here because a header holds at most "
                + "\(PaneHeader.maximumLeadingItems + PaneHeader.maximumTrailingItems)",
        ]
    }

    /// One decoded item, or the sentence its author gets instead of it. Exactly one side is
    /// non-nil; the pair exists so a malformed item can be reported without the decoder
    /// reaching out to a log it is not allowed to touch.
    private struct ParsedHeaderItem: Sendable {
        let item: PaneHeaderItem?
        let diagnostic: String?

        static func kept(_ item: PaneHeaderItem) -> ParsedHeaderItem {
            ParsedHeaderItem(item: item, diagnostic: nil)
        }

        static func dropped(_ reason: String) -> ParsedHeaderItem {
            ParsedHeaderItem(item: nil, diagnostic: reason)
        }
    }

    private static func headerItems(
        from value: IntentValue?,
        slot: String
    ) -> [ParsedHeaderItem] {
        guard let values = value?.arrayValue else { return [] }
        return values.map { headerItem(from: $0, slot: slot) }
    }

    /// One header item, keyed by `type`.
    ///
    /// A missing REQUIRED field costs THAT ONE item its place and nothing else: its siblings
    /// are drawn, the view is published, and the plugin stays active. A header is a strip of
    /// independent controls, so one malformed entry is a defect in one control — refusing the
    /// whole header over it would take away the nine that were fine.
    ///
    /// Token fields never drop an item. `tint`, `color`, `weight` and `truncation` all degrade
    /// to their documented default, because an unrecognised adjective is a typo about
    /// APPEARANCE and the item still has something true to say.
    ///
    /// `accessibilityID` is absent by construction: it is XCUITest identity rather than
    /// contributor data, and a plugin able to mint one could rename the host's own test anchors
    /// out from under the UI suite.
    private static func headerItem(
        from value: IntentValue,
        slot: String
    ) -> ParsedHeaderItem {
        guard let object = value.objectValue else {
            return .dropped("dropped a \(slot) header item that is not an object")
        }
        guard let type = object["type"]?.stringValue, !type.isEmpty else {
            return .dropped("dropped a \(slot) header item with no \"type\"")
        }
        guard let id = object["id"]?.stringValue else {
            return .dropped("dropped a \(slot) \(type) header item with no \"id\"")
        }

        // "an iconButton", never "a iconButton". This sentence is the whole of what an author
        // gets instead of the control they asked for, so it is written to be read; the two
        // vowel-initial kinds in the vocabulary are `image` and `iconButton`.
        let article = "aeiou".contains(type.lowercased().first ?? " ") ? "an" : "a"

        func missing(_ field: String) -> ParsedHeaderItem {
            .dropped(
                "dropped \(slot) header item \"\(id)\": \(article) \(type) needs \"\(field)\""
            )
        }

        func admit(_ item: PaneHeaderItem) -> ParsedHeaderItem {
            // The vocabulary's own bounds, asked BEFORE the item counts against its slot's
            // budget, so a refused item never displaces a usable one — and so the refusal can
            // be explained here instead of vanishing silently inside `PaneHeader.init`.
            guard let bounded = item.bounded() else {
                return .dropped(
                    "dropped \(slot) header item \"\(id)\": \(article) \(type) with this id, "
                        + "symbol name or set of options is outside the header's bounds"
                )
            }
            return .kept(bounded)
        }

        let tint = ColorToken(token: object["tint"]?.stringValue)
        let tooltip = object["tooltip"]?.stringValue
        let isEnabled = object["isEnabled"]?.boolValue ?? true

        switch type {
        case "dot":
            return admit(.dot(id: id, tint: tint, tooltip: tooltip))
        case "label":
            guard let text = object["text"]?.stringValue else { return missing("text") }
            return admit(.label(
                id: id,
                text: text,
                weight: FontWeight(token: object["weight"]?.stringValue),
                color: ColorToken(token: object["color"]?.stringValue),
                truncation: PaneHeaderTruncation(token: object["truncation"]?.stringValue),
                tooltip: tooltip
            ))
        case "badge":
            guard let text = object["text"]?.stringValue else { return missing("text") }
            return admit(.badge(id: id, text: text, tint: tint, tooltip: tooltip))
        case "image":
            guard let systemName = object["systemName"]?.stringValue else {
                return missing("systemName")
            }
            return admit(.image(id: id, systemName: systemName, tint: tint, tooltip: tooltip))
        case "spinner":
            return admit(.spinner(id: id))
        case "iconButton":
            guard let systemName = object["systemName"]?.stringValue else {
                return missing("systemName")
            }
            return admit(.iconButton(
                id: id,
                systemName: systemName,
                tint: tint,
                isEnabled: isEnabled,
                tooltip: tooltip,
                accessibilityID: nil
            ))
        case "toggle":
            guard let systemName = object["systemName"]?.stringValue else {
                return missing("systemName")
            }
            return admit(.toggle(
                id: id,
                systemName: systemName,
                isOn: object["isOn"]?.boolValue ?? false,
                isEnabled: isEnabled,
                tooltip: tooltip,
                accessibilityID: nil
            ))
        case "segmented":
            guard let rawSegments = object["segments"]?.arrayValue else {
                return missing("segments")
            }
            guard let selection = object["selection"]?.stringValue else {
                return missing("selection")
            }
            return admit(.segmented(
                id: id,
                segments: rawSegments.compactMap(headerSegment(from:)),
                selection: selection,
                isEnabled: isEnabled,
                accessibilityID: nil
            ))
        case "menu":
            guard let systemName = object["systemName"]?.stringValue else {
                return missing("systemName")
            }
            guard let rawEntries = object["entries"]?.arrayValue else {
                return missing("entries")
            }
            return admit(.menu(
                id: id,
                systemName: systemName,
                entries: rawEntries.compactMap(headerMenuEntry(from:)),
                isEnabled: isEnabled,
                tooltip: tooltip,
                accessibilityID: nil
            ))
        case "textfield":
            return admit(.textfield(
                id: id,
                value: object["value"]?.stringValue ?? "",
                placeholder: object["placeholder"]?.stringValue ?? "",
                flex: object["flex"]?.boolValue ?? false,
                isEnabled: isEnabled,
                accessibilityID: nil
            ))
        default:
            return .dropped(
                "dropped \(slot) header item \"\(id)\": \"\(type)\" is not a header item type"
            )
        }
    }

    /// `PaneHeaderSegment.init?` decides what an option has to carry; this only unpacks the
    /// JSON. A refused option is not reported on its own — starving a picker below its minimum
    /// drops the whole control, and THAT is what its author is told about.
    private static func headerSegment(from value: IntentValue) -> PaneHeaderSegment? {
        guard let object = value.objectValue,
              let segmentValue = object["value"]?.stringValue
        else {
            return nil
        }
        return PaneHeaderSegment(
            value: segmentValue,
            label: object["label"]?.stringValue,
            systemName: object["systemName"]?.stringValue,
            accessibilityLabel: object["accessibilityLabel"]?.stringValue,
            tooltip: object["tooltip"]?.stringValue
        )
    }

    private static func headerMenuEntry(from value: IntentValue) -> PaneHeaderMenuEntry? {
        guard let object = value.objectValue,
              let entryValue = object["value"]?.stringValue,
              let label = object["label"]?.stringValue
        else {
            return nil
        }
        return PaneHeaderMenuEntry(
            value: entryValue,
            label: label,
            systemName: object["systemName"]?.stringValue,
            isOn: object["isOn"]?.boolValue ?? false,
            separatorBefore: object["separatorBefore"]?.boolValue ?? false
        )
    }

    /// A modal is present or it is not: a `modal` that is null, or any other shape,
    /// clears it. That is how a plugin closes one — `views.set` without the key.
    static func modal(from object: [String: IntentValue]) -> PluginViewModal? {
        let dismiss = object["dismissAction"].map(actionIdentifier(from:))
        return PluginViewModal(
            title: object["title"]?.stringValue ?? "",
            body: object["body"]?.objectValue.flatMap(node(from:)),
            dismissAction: dismiss.flatMap { $0.isEmpty ? nil : $0 }
                ?? PluginViewModal.defaultDismissAction
        )
    }

    static func node(from object: [String: IntentValue]) -> PluginViewNode? {
        guard let type = object["type"]?.stringValue else { return nil }
        let children = object["children"]?.arrayValue?.compactMap {
            $0.objectValue.flatMap(node(from:))
        } ?? []

        switch type {
        case "vstack":
            return .vstack(spacing: object["spacing"]?.doubleValue ?? 8, children: children)
        case "hstack":
            return .hstack(spacing: object["spacing"]?.doubleValue ?? 8, children: children)
        case "box":
            return .box(
                padding: object["padding"]?.doubleValue ?? 12,
                background: object["background"]?.boolValue ?? false,
                cornerRadius: object["cornerRadius"]?.doubleValue ?? 8,
                width: object["width"]?.doubleValue.map(boxWidth(_:)),
                children: children
            )
        case "card":
            return .card(children: children)
        case "text":
            return .text(
                object["value"]?.stringValue ?? "",
                style: TextStyle(token: object["style"]?.stringValue),
                weight: FontWeight(token: object["weight"]?.stringValue),
                color: ColorToken(token: object["color"]?.stringValue)
            )
        case "badge":
            return .badge(
                object["value"]?.stringValue ?? "",
                tint: ColorToken(token: object["tint"]?.stringValue)
            )
        case "button":
            guard let action = object["action"] else { return nil }
            return .button(
                label: object["label"]?.stringValue ?? "",
                action: actionIdentifier(from: action),
                style: ButtonStyle(token: object["style"]?.stringValue)
            )
        case "textfield":
            guard let action = object["action"] else { return nil }
            return .textfield(
                value: object["value"]?.stringValue ?? "",
                placeholder: object["placeholder"]?.stringValue ?? "",
                action: actionIdentifier(from: action)
            )
        case "webview":
            guard let surfaceID = object["surfaceID"]?.stringValue else { return nil }
            return .webview(surfaceID: surfaceID)
        case "image":
            guard let systemName = object["systemName"]?.stringValue else { return nil }
            return .image(systemName: systemName)
        case "spacer":
            return .spacer
        case "divider":
            return .divider
        case "scroll":
            return .scroll(
                axis: ScrollAxis(token: object["axis"]?.stringValue),
                children: children
            )
        case "grid":
            return .grid(
                columns: max(1, object["columns"]?.intValue ?? 2),
                spacing: object["spacing"]?.doubleValue ?? 8,
                children: children
            )
        case "stat":
            return .stat(
                label: object["label"]?.stringValue ?? "",
                value: object["value"]?.stringValue ?? ""
            )
        case "keyValue":
            return .keyValue(
                label: object["label"]?.stringValue ?? "",
                value: object["value"]?.stringValue ?? "",
                tint: ColorToken(token: object["tint"]?.stringValue)
            )
        case "progress":
            let progress = min(1, max(0, object["value"]?.doubleValue ?? 0))
            return .progress(
                value: progress,
                tint: ColorToken(token: object["tint"]?.stringValue)
            )
        case "field":
            return .field(
                label: object["label"]?.stringValue ?? "",
                children: children
            )
        // A malformed drag wrapper keeps its subtree and loses only the gesture. `button`
        // returns nil for a missing action because a button IS its content; these two wrap
        // content the plugin still meant to show, and blanking a card because its payload
        // was too long is a worse answer than a card you have to move with the buttons.
        case "dragSource":
            return .dragSource(
                payload: PluginViewDrag.admissiblePayload(
                    object["payload"]?.stringValue
                ) ?? "",
                children: children
            )
        case "dropTarget":
            return .dropTarget(
                action: object["action"].map(actionIdentifier(from:)) ?? "",
                children: children
            )
        default:
            return nil
        }
    }

    /// Bounds a declared `box` width at the parsing boundary, like `progress`'s clamp:
    /// a pane is a few hundred points wide, and a column narrower than 60 or wider than
    /// 1200 is a bug in the plugin rather than a layout anyone asked for.
    static func boxWidth(_ value: Double) -> Double {
        min(1200, max(60, value))
    }

    static func foundationObject(from value: IntentValue) -> Any {
        switch value {
        case .null:
            return NSNull()
        case let .bool(value):
            return value
        case let .integer(value):
            return NSNumber(value: value)
        case let .number(value):
            return NSNumber(value: value)
        case let .string(value):
            return value
        case let .array(values):
            return values.map(foundationObject(from:))
        case let .object(values):
            return values.mapValues(foundationObject(from:))
        }
    }

    static func intentResultValue(_ result: IntentResult) -> IntentValue {
        switch result {
        case let .success(success):
            return .object([
                "ok": .bool(true),
                "value": success.value,
                "meta": .object([
                    "requestID": .string(success.meta.requestID.uuidString),
                    "providerID": .string(success.meta.providerID.rawValue),
                ]),
            ])
        case let .failure(failure):
            var error: [String: IntentValue] = [
                "code": .string(failure.error.code.rawValue),
                "retryable": .bool(failure.error.retryable),
                "outcome": .string(failure.error.outcome.rawValue),
            ]
            if let details = failure.error.details {
                error["details"] = details
            }
            if let retryAfter = failure.error.retryAfterMilliseconds {
                error["retryAfterMs"] = retryAfter > UInt64(Int64.max)
                    ? .number(Double(retryAfter))
                    : .integer(Int64(retryAfter))
            }

            var metadata: [String: IntentValue] = [
                "requestID": .string(failure.meta.requestID.uuidString),
            ]
            if let providerID = failure.meta.providerID {
                metadata["providerID"] = .string(providerID.rawValue)
            }
            return .object([
                "ok": .bool(false),
                "error": .object(error),
                "meta": .object(metadata),
            ])
        }
    }

    static func intentRequest(
        name: IntentValue?,
        input: IntentValue?,
        options: IntentValue?
    ) throws -> PluginIntentSendRequest {
        guard let rawName = name?.stringValue else {
            throw PluginRuntimeError.bridgeProtocolViolation("intent name is missing")
        }
        let intentID = try IntentID(rawName)
        let options = options?.objectValue ?? [:]

        let target: ProviderID?
        if let rawTarget = options["target"]?.objectValue?["providerID"]?.stringValue {
            target = try ProviderID(rawTarget)
        } else {
            target = nil
        }

        let requestedTimeout: Duration?
        if let milliseconds = options["timeoutMs"]?.int64Value, milliseconds > 0 {
            requestedTimeout = .milliseconds(milliseconds)
        } else if let milliseconds = options["timeoutMs"]?.doubleValue,
                  milliseconds.isFinite,
                  milliseconds > 0,
                  milliseconds <= Double(Int64.max)
        {
            requestedTimeout = .milliseconds(Int64(milliseconds))
        } else {
            requestedTimeout = nil
        }

        let idempotencyKey = options["idempotencyKey"]?.stringValue
        guard (idempotencyKey?.utf8.count ?? 0) <= 256 else {
            throw PluginRuntimeError.bridgeProtocolViolation("idempotency key is too long")
        }

        let scopeOverride: InvocationScopeOverride?
        if let scopeValue = options["scope"] {
            guard let scope = scopeValue.objectValue else {
                throw PluginRuntimeError.bridgeProtocolViolation(
                    "intent scope override must be an object"
                )
            }
            guard scope["userGestureID"] == nil else {
                throw PluginRuntimeError.bridgeProtocolViolation(
                    "intent userGestureID is host-owned"
                )
            }
            let workspaceID = try scopeUUID(
                scope["workspaceID"],
                field: "workspaceID"
            )
            let tabID = try scopeUUID(
                scope["tabID"],
                field: "tabID"
            )
            let paneID = try scopeUUID(
                scope["paneID"],
                field: "paneID"
            )
            scopeOverride = workspaceID == nil && tabID == nil && paneID == nil
                ? nil
                : InvocationScopeOverride(
                    workspaceID: workspaceID,
                    tabID: tabID,
                    paneID: paneID
                )
        } else {
            scopeOverride = nil
        }

        return PluginIntentSendRequest(
            intentID: intentID,
            input: input ?? .null,
            target: target,
            idempotencyKey: idempotencyKey,
            requestedTimeout: requestedTimeout,
            scopeOverride: scopeOverride
        )
    }

    private static func scopeUUID(
        _ value: IntentValue?,
        field: String
    ) throws -> UUID? {
        guard let value else { return nil }
        guard let raw = value.stringValue,
              let uuid = UUID(uuidString: raw)
        else {
            throw PluginRuntimeError.bridgeProtocolViolation(
                "intent scope \(field) must be a UUID string"
            )
        }
        return uuid
    }

    static func providerFailure(from value: IntentValue?) -> IntentProviderFailure {
        let object = value?.objectValue ?? [:]
        let rawCode = object["code"]?.stringValue ?? IntentKernelErrorCode.handlerFailed.rawValue
        let code: IntentErrorCode
        if let kernel = IntentKernelErrorCode(rawValue: rawCode) {
            code = .kernel(kernel)
        } else if let domain = try? IntentDomainErrorCode(rawCode) {
            code = .domain(domain)
        } else {
            code = .kernel(.handlerFailed)
        }

        let retryAfter: UInt64?
        if let value = object["retryAfterMs"]?.int64Value, value >= 0 {
            retryAfter = UInt64(value)
        } else {
            retryAfter = nil
        }

        return IntentProviderFailure(
            code: code,
            details: object["details"],
            retryable: object["retryable"]?.boolValue ?? false,
            retryAfterMilliseconds: retryAfter
        )
    }

    static func progress(from value: IntentValue?) -> IntentProgress? {
        guard let object = value?.objectValue,
              let completed = object["completed"]?.doubleValue
        else {
            return nil
        }
        return try? IntentProgress(
            completed: completed,
            total: object["total"]?.doubleValue,
            message: object["message"]?.stringValue
        )
    }

    private static func menu(from value: IntentValue?) -> [RowMenuItem] {
        value?.arrayValue?.compactMap { item in
            guard let object = item.objectValue,
                  let id = object["id"]?.stringValue,
                  let label = object["label"]?.stringValue
            else {
                return nil
            }
            return RowMenuItem(
                id: id,
                label: label,
                destructive: object["destructive"]?.boolValue ?? false,
                separatorBefore: object["separatorBefore"]?.boolValue ?? false
            )
        } ?? []
    }

    private static func actionIdentifier(from value: IntentValue) -> String {
        if let string = value.stringValue {
            return string
        }
        guard let data = try? value.canonicalJSONData(),
              let json = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        return "\u{1}" + json
    }
}

extension IntentValue {
    var objectValue: [String: IntentValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var arrayValue: [IntentValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    var int64Value: Int64? {
        switch self {
        case let .integer(value):
            value
        case let .number(value) where value.rounded(.towardZero) == value
            && value >= Double(Int64.min)
            && value <= Double(Int64.max):
            Int64(value)
        default:
            nil
        }
    }

    var intValue: Int? {
        int64Value.flatMap(Int.init(exactly:))
    }

    var doubleValue: Double? {
        switch self {
        case let .integer(value):
            Double(value)
        case let .number(value):
            value
        default:
            nil
        }
    }
}
