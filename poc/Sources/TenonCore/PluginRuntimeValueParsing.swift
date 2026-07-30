import Foundation
import TenonIntentCore

struct PluginParsedViewBody: Sendable {
    let items: [PluginRowItem]
    let body: PluginViewNode?
    let subtitle: String?
    let actions: [ViewAction]
}

enum PluginRuntimeValueParsing {
    static func rows(from value: IntentValue?) -> [PluginRowItem] {
        guard let values = value?.arrayValue else { return [] }
        return values.compactMap { row in
            guard let object = row.objectValue,
                  let idValue = object["id"],
                  let label = object["label"]?.stringValue
            else {
                return nil
            }

            return PluginRowItem(
                id: actionIdentifier(from: idValue),
                label: label,
                depth: max(0, object["depth"]?.intValue ?? 0),
                icon: object["icon"]?.stringValue,
                expanded: object["expanded"]?.boolValue,
                menu: menu(from: object["menu"]),
                editing: object["editing"]?.boolValue ?? false,
                placeholder: object["placeholder"]?.stringValue,
                selected: object["selected"]?.boolValue ?? false,
                path: object["path"]?.stringValue
            )
        }
    }

    static func viewBody(from value: IntentValue) -> PluginParsedViewBody {
        let object = value.objectValue ?? [:]
        return PluginParsedViewBody(
            items: rows(from: object["items"]),
            body: object["body"]?.objectValue.flatMap(node(from:)),
            subtitle: object["subtitle"]?.stringValue,
            actions: actions(from: object["actions"])
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
        case "browserBar":
            return .browserBar(
                url: object["url"]?.stringValue ?? "",
                placeholder: object["placeholder"]?.stringValue ?? "Search or enter website"
            )
        case "image":
            guard let systemName = object["systemName"]?.stringValue else { return nil }
            return .image(systemName: systemName)
        case "spacer":
            return .spacer
        case "divider":
            return .divider
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
        default:
            return nil
        }
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
            let paneID = try scopeUUID(
                scope["paneID"],
                field: "paneID"
            )
            scopeOverride = workspaceID == nil && paneID == nil
                ? nil
                : InvocationScopeOverride(
                    workspaceID: workspaceID,
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

    private static func actions(from value: IntentValue?) -> [ViewAction] {
        value?.arrayValue?.compactMap { action in
            guard let object = action.objectValue,
                  let id = object["id"]?.stringValue,
                  let icon = object["icon"]?.stringValue
            else {
                return nil
            }
            return ViewAction(
                id: id,
                icon: icon,
                tooltip: object["tooltip"]?.stringValue
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
