import Foundation

public enum HazardCategory: String, Sendable, Codable, Equatable {
    case payment
    case destructive
    case externalSideEffect
}

public struct HazardousActionAssessment: Sendable, Codable, Equatable {
    public let isHazardous: Bool
    public let category: HazardCategory?
    public let matchedPattern: String?
    public let matchedLabel: String?

    public var reason: String {
        guard isHazardous else { return "" }
        let kind = category?.rawValue ?? "hazardous"
        if let matchedLabel, !matchedLabel.isEmpty {
            return "Blocked \(kind) action '\(matchedLabel)'"
        }
        if let matchedPattern, !matchedPattern.isEmpty {
            return "Matched hazardous rule '\(matchedPattern)'"
        }
        return "Blocked \(kind) action"
    }

    public static let safe = HazardousActionAssessment(
        isHazardous: false,
        category: nil,
        matchedPattern: nil,
        matchedLabel: nil
    )
}

/// Classifies UI actions, graph edges, and live Accessibility nodes that trigger irreversible
/// financial, destructive, or external side effects requiring Human-in-the-Loop approval (#2).
public enum HazardousActionClassifier {
    private static let paymentRegex = try! NSRegularExpression(
        pattern: #"(?<!\p{L})(?:оплат(?:ить|а|еж|у|ы)?|купить|оформить\s+заказ|подтвердить\s+заказ|списать|перевести|подписаться|pay(?:\s+now)?|buy(?:\s+now)?|purchase|place\s+order|confirm\s+order|complete\s+order|charge|transfer|send\s+money|subscribe)(?!\p{L})"#,
        options: [.caseInsensitive]
    )

    private static let destructiveRegex = try! NSRegularExpression(
        pattern: #"(?<!\p{L})(?:удалить|стереть|очистить\s+вс[её]|сбросить|деактивировать|отвязать|заблокировать|отменить\s+заказ|delete|remove\s+account|erase|wipe|factory\s+reset|reset\s+all|destroy|uninstall|deactivate|terminate|revoke|purge|close\s+account|cancel\s+subscription)(?!\p{L})"#,
        options: [.caseInsensitive]
    )

    private static let paymentResourceSuffixes: Set<String> = [
        "btn_pay", "pay_button", "btn_buy", "buy_now", "buy_button",
        "confirm_purchase", "place_order", "btn_purchase"
    ]

    private static let destructiveResourceSuffixes: Set<String> = [
        "btn_delete", "delete_button", "delete_account", "confirm_delete",
        "action_delete", "btn_erase", "btn_wipe", "factory_reset"
    ]

    public static func assess(
        action: AttributedUIAction?,
        actionSignature: String,
        liveLabel: String? = nil,
        liveResourceId: String? = nil
    ) -> HazardousActionAssessment {
        var labels: [String] = []
        if let liveLabel, !liveLabel.isEmpty { labels.append(liveLabel) }
        if let action {
            if let s = action.selectorText, !s.isEmpty { labels.append(s) }
            if let d = action.selectorContentDesc, !d.isEmpty { labels.append(d) }
            if !action.targetDescription.isEmpty { labels.append(action.targetDescription) }
        }
        let cleanedSignature = stripSignaturePrefix(actionSignature)
        if !cleanedSignature.isEmpty { labels.append(cleanedSignature) }

        var resourceIds: [String] = []
        if let liveResourceId, !liveResourceId.isEmpty { resourceIds.append(liveResourceId) }
        if let rid = action?.selectorResourceId, !rid.isEmpty { resourceIds.append(rid) }

        return evaluate(labels: labels, resourceIds: resourceIds)
    }

    public static func assess(node: ShadowUINode) -> HazardousActionAssessment {
        var labels: [String] = []
        if !node.text.isEmpty { labels.append(node.text) }
        if !node.contentDesc.isEmpty { labels.append(node.contentDesc) }
        let resourceIds = node.resourceId.isEmpty ? [] : [node.resourceId]
        return evaluate(labels: labels, resourceIds: resourceIds)
    }

    private static func evaluate(labels: [String], resourceIds: [String]) -> HazardousActionAssessment {
        for rawLabel in labels {
            let trimmed = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let match = firstMatch(paymentRegex, in: trimmed) {
                return HazardousActionAssessment(
                    isHazardous: true,
                    category: .payment,
                    matchedPattern: match,
                    matchedLabel: trimmed
                )
            }
            if let match = firstMatch(destructiveRegex, in: trimmed) {
                return HazardousActionAssessment(
                    isHazardous: true,
                    category: .destructive,
                    matchedPattern: match,
                    matchedLabel: trimmed
                )
            }
        }

        for rawId in resourceIds {
            let shortId = shortResourceId(rawId)
            guard !shortId.isEmpty else { continue }
            if paymentResourceSuffixes.contains(shortId) || shortId.hasSuffix("_pay") || shortId.hasSuffix("_checkout") {
                return HazardousActionAssessment(
                    isHazardous: true,
                    category: .payment,
                    matchedPattern: shortId,
                    matchedLabel: labels.first ?? shortId
                )
            }
            if destructiveResourceSuffixes.contains(shortId) || shortId.hasSuffix("_delete") {
                return HazardousActionAssessment(
                    isHazardous: true,
                    category: .destructive,
                    matchedPattern: shortId,
                    matchedLabel: labels.first ?? shortId
                )
            }
        }

        return .safe
    }

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let hit = regex.firstMatch(in: text, options: [], range: range),
              let swiftRange = Range(hit.range, in: text) else {
            return nil
        }
        return String(text[swiftRange])
    }

    private static func stripSignaturePrefix(_ signature: String) -> String {
        for prefix in ["tap:", "swipe:", "keyevent:", "typeText:", "launchApp:"] {
            if signature.hasPrefix(prefix) {
                return String(signature.dropFirst(prefix.count))
            }
        }
        return signature
    }

    private static func shortResourceId(_ resourceId: String) -> String {
        if let range = resourceId.range(of: ":id/") {
            return String(resourceId[range.upperBound...]).lowercased()
        }
        if let idx = resourceId.lastIndex(of: "/") {
            let next = resourceId.index(after: idx)
            if next < resourceId.endIndex {
                return String(resourceId[next...]).lowercased()
            }
        }
        return resourceId.lowercased()
    }
}
