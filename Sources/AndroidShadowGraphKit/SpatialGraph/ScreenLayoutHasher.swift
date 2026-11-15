import Foundation

public struct ScreenSemanticFingerprint: Sendable, Hashable, Codable {
    public let layoutHash: UInt64
    public let activePackage: String
    public let activeWindowId: Int
    public let tokens: Set<String>
    public let sampleInteractiveLabels: [String]

    public init(
        layoutHash: UInt64,
        activePackage: String,
        activeWindowId: Int,
        tokens: Set<String>,
        sampleInteractiveLabels: [String] = []
    ) {
        self.layoutHash = layoutHash
        self.activePackage = activePackage
        self.activeWindowId = activeWindowId
        self.tokens = tokens
        self.sampleInteractiveLabels = sampleInteractiveLabels
    }
}

/// Produces a deterministic structural-semantic fingerprint of an Android screen.
/// Invariant to status-bar clock ticks, battery percentage updates, and minor numeric counter drift.
public struct ScreenLayoutHasher: Sendable {
    public let ignoredPackages: Set<String>

    public init(ignoredPackages: Set<String> = ["com.android.systemui"]) {
        self.ignoredPackages = ignoredPackages
    }

    public func fingerprint(for index: ShadowTreeIndex) -> ScreenSemanticFingerprint {
        let activePkg = index.activePackage
        let skipIgnored = !ignoredPackages.contains(activePkg)

        var tokenSet = Set<String>()
        tokenSet.reserveCapacity(min(256, index.orderedNodes.count))

        var nonTemporalLabels: [String] = []
        var temporalLabels: [String] = []
        var seenLabels = Set<String>()

        for node in index.orderedNodes {
            guard node.visible else { continue }
            if skipIgnored, Self.isIgnoredSystemNode(node, ignoredPackages: ignoredPackages) {
                continue
            }

            let rawLabel = !node.text.isEmpty ? node.text : node.contentDesc
            let temporalKind = Self.temporalKind(for: node, activePackage: activePkg)
            let normalizedLabel = Self.normalizeLabel(rawLabel)
            let isInteractive = node.clickable || node.scrollable || node.editable

            // Keep static chrome, resource-id-anchored views, and interactive elements;
            // omit unlabeled non-interactive layout wrappers.
            let hasIdentity = !node.resourceId.isEmpty || isInteractive || !normalizedLabel.isEmpty
            guard hasIdentity else { continue }

            // For non-interactive, non-resourceId body text blobs (e.g. long scrolling paragraphs),
            // collapse to structural class token to avoid graph explosion while scrolling feeds.
            let tokenLabel: String
            if let temporalKind, !normalizedLabel.isEmpty {
                tokenLabel = temporalKind.token
            } else if !node.resourceId.isEmpty || isInteractive {
                tokenLabel = normalizedLabel
            } else {
                tokenLabel = normalizedLabel.count <= 32 ? normalizedLabel : "<TEXT>"
            }

            let token = "\(node.className)|\(node.resourceId)|\(tokenLabel)"
            tokenSet.insert(token)

            if !rawLabel.isEmpty, (isInteractive || !node.resourceId.isEmpty) {
                let compactLabel = String(rawLabel.prefix(40))
                if seenLabels.insert(compactLabel).inserted {
                    if temporalKind != nil {
                        if temporalLabels.count < 8 {
                            temporalLabels.append(compactLabel)
                        }
                    } else if nonTemporalLabels.count < 8 {
                        nonTemporalLabels.append(compactLabel)
                    }
                }
            }
        }

        let interactiveLabels = Array((nonTemporalLabels + temporalLabels).prefix(8))

        let sortedTokens = tokenSet.sorted()
        let hash = Self.fnv1a64(activePackage: activePkg, sortedTokens: sortedTokens)

        return ScreenSemanticFingerprint(
            layoutHash: hash,
            activePackage: activePkg,
            activeWindowId: index.activeWindowId,
            tokens: tokenSet,
            sampleInteractiveLabels: interactiveLabels
        )
    }

    /// Computes Jaccard similarity in `[0.0, 1.0]` between two semantic fingerprints without heap allocations.
    @inlinable
    public static func similarity(_ lhs: ScreenSemanticFingerprint, _ rhs: ScreenSemanticFingerprint) -> Double {
        guard lhs.activePackage == rhs.activePackage else { return 0.0 }
        return jaccardSimilarity(lhs.tokens, rhs.tokens)
    }

    /// Computes zero-allocation Jaccard similarity in `[0.0, 1.0]` between two token sets
    /// by iterating the smaller set against the larger set.
    @inlinable
    public static func jaccardSimilarity(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        if lhs.isEmpty && rhs.isEmpty { return 1.0 }
        if lhs.isEmpty || rhs.isEmpty { return 0.0 }
        let (smaller, larger) = lhs.count <= rhs.count ? (lhs, rhs) : (rhs, lhs)
        var intersectionCount = 0
        for token in smaller where larger.contains(token) {
            intersectionCount &+= 1
        }
        let unionCount = lhs.count &+ rhs.count &- intersectionCount
        guard unionCount > 0 else { return 1.0 }
        return Double(intersectionCount) / Double(unionCount)
    }

    /// Package-aware zero-allocation Jaccard similarity for graph vertices.
    @inlinable
    public static func similarity(
        packageA: String,
        tokensA: Set<String>,
        packageB: String,
        tokensB: Set<String>
    ) -> Double {
        guard packageA == packageB else { return 0.0 }
        return jaccardSimilarity(tokensA, tokensB)
    }

    private enum TemporalKind {
        case clock
        case date

        var token: String {
            switch self {
            case .clock: return "<CLOCK>"
            case .date: return "<DATE>"
            }
        }
    }

    private static let clockClassSuffixes: Set<String> = [
        "Clock", "TextClock", "AnalogClock", "DigitalClock", "Chronometer", "DateTimeView"
    ]

    private static let clockResourceIds: Set<String> = [
        "clock", "a11y_clock", "digital_clock", "analog_clock", "analogue_clock",
        "analog_appwidget", "digital_appwidget", "clock_display",
        "status_bar_clock", "qs_clock", "keyguard_clock", "keyguard_clock_view",
        "keyguard_clock_container", "lockscreen_clock", "lockscreen_clock_view",
        "big_clock", "small_clock", "aod_clock", "world_clock", "city_clock",
        "widget_clock", "clock_time", "clock_view", "time_view",
        "hours", "minutes", "seconds", "am_pm", "next_alarm", "nextalarm"
    ]

    private static let dateResourceIds: Set<String> = [
        "date", "date_text", "date_view", "date_display", "clock_date", "date_clock",
        "smartspace_date", "keyguard_date", "lockscreen_date", "weekday", "day_of_week"
    ]

    private static let embeddedClockWidgetPackages: Set<String> = [
        "com.google.android.deskclock",
        "com.android.deskclock",
        "com.android.alarmclock",
        "com.sec.android.app.clockpackage",
        "com.oneplus.deskclock",
        "com.oplus.alarmclock",
        "com.coloros.alarmclock",
        "com.miui.clock"
    ]

    private static func isIgnoredSystemNode(_ node: ShadowUINode, ignoredPackages: Set<String>) -> Bool {
        if !node.packageName.isEmpty && ignoredPackages.contains(node.packageName) {
            return true
        }
        if !node.resourceId.isEmpty {
            for pkg in ignoredPackages where node.resourceId.hasPrefix("\(pkg):") {
                return true
            }
        }
        return false
    }

    private static func shortClassName(_ className: String) -> String {
        if let idx = className.lastIndex(of: ".") {
            return String(className[className.index(after: idx)...])
        }
        return className
    }

    private static func shortResourceId(_ resourceId: String) -> String {
        if let range = resourceId.range(of: ":id/") {
            return String(resourceId[range.upperBound...]).lowercased()
        }
        if let idx = resourceId.lastIndex(of: "/") {
            return String(resourceId[resourceId.index(after: idx)...]).lowercased()
        }
        return resourceId.lowercased()
    }

    private static func resourcePackage(_ resourceId: String) -> String? {
        guard let colonIdx = resourceId.firstIndex(of: ":"), colonIdx > resourceId.startIndex else {
            return nil
        }
        return String(resourceId[..<colonIdx])
    }

    private static func temporalKind(for node: ShadowUINode, activePackage: String) -> TemporalKind? {
        temporalKind(
            className: node.className,
            resourceId: node.resourceId,
            packageName: node.packageName,
            activePackage: activePackage
        )
    }

    private static func temporalKind(
        className: String,
        resourceId: String,
        packageName: String,
        activePackage: String
    ) -> TemporalKind? {
        let shortClass = shortClassName(className)
        if clockClassSuffixes.contains(shortClass) {
            return .clock
        }

        if !resourceId.isEmpty {
            let shortId = shortResourceId(resourceId)
            if clockResourceIds.contains(shortId) || shortId.hasSuffix("_clock") || shortId.hasSuffix("_a11y_clock") {
                return .clock
            }
            if dateResourceIds.contains(shortId) || shortId.hasSuffix("_date") {
                return .date
            }
        }

        if !packageName.isEmpty,
           packageName != activePackage,
           embeddedClockWidgetPackages.contains(packageName) {
            return .clock
        }

        if let resPkg = resourcePackage(resourceId),
           resPkg != activePackage,
           embeddedClockWidgetPackages.contains(resPkg) {
            return .clock
        }

        return nil
    }

    /// Re-canonicalizes a persisted `className|resourceId|label` semantic token under the current
    /// temporal and label-normalization rules (e.g. when upgrading pre-existing persisted graphs).
    public static func canonicalizeToken(_ token: String, activePackage: String) -> String {
        let parts = token.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return token }

        let className = String(parts[0])
        let resourceId = String(parts[1])
        let label = String(parts[2])
        guard !label.isEmpty else { return token }
        if label == "<TEXT>" || label == "<CLOCK>" || label == "<DATE>" {
            return token
        }

        if let kind = temporalKind(
            className: className,
            resourceId: resourceId,
            packageName: "",
            activePackage: activePackage
        ) {
            return "\(className)|\(resourceId)|\(kind.token)"
        }

        let normalized = normalizeLabel(label)
        return "\(className)|\(resourceId)|\(normalized)"
    }

    private static let timeRegex = try! NSRegularExpression(
        pattern: #"(?<!\p{L})#(?:\s*:\s*#){1,2}(?:\s*(?:[ap]\.?m\.?|д\.?п\.?|п\.?п\.?))?(?!\p{L})"#,
        options: [.caseInsensitive]
    )

    private static let weekdayRegex = try! NSRegularExpression(
        pattern: #"(?<!\p{L})(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon\.?|tues?\.?|wed\.?|thur?s?\.?|fri\.?|sat\.?|понедельник|вторник|сред[ау]|четверг|пятниц[ау]|суббот[ау]|воскресенье|пн\.?|вт\.?|ср\.?|чт\.?|пт\.?|сб\.?|вс\.?)(?!\p{L})"#,
        options: [.caseInsensitive]
    )

    private static let monthRegex = try! NSRegularExpression(
        pattern: #"(?<!\p{L})(?:january|jan\.?|february|feb\.?|april|apr\.?|june|jun\.?|july|jul\.?|august|aug\.?|september|sept?\.?|october|oct\.?|november|nov\.?|december|dec\.?|январ[ья]|янв\.?|феврал[ья]|февр?\.?|марта?|мар\.?|апрел[ья]|апр\.?|ма[йя]|июн(?:[ья]|\.)?|июл(?:[ья]|\.)?|августа?|авг\.?|сентябр[ья]|сент?\.?|октябр[ья]|окт\.?|ноябр[ья]|нояб?\.?|декабр[ья]|дек\.?)(?!\p{L})"#,
        options: [.caseInsensitive]
    )

    private static let sunContextRegex = try! NSRegularExpression(
        pattern: #"(?:(?<!\p{L})Sun\.?(?=\s*,\s*(?:#|<MONTH>|<TIME>)|\s+(?:#|<MONTH>|<TIME>))|(?<=(?:#|<MONTH>|<TIME>)[,\s]{1,3})Sun\.?(?!\p{L}))"#
    )

    private static let marchMayContextRegex = try! NSRegularExpression(
        pattern: #"(?:(?<!\p{L})(?:March|Mar\.?|May)(?=\s*,\s*#|\s+#)|(?<=#\.?[\s,]{1,2}|<DAY>[\s,]{1,2})(?:March|Mar\.?|May)(?!\p{L}))"#
    )

    private static let relativeDayRegex = try! NSRegularExpression(
        pattern: #"(?<!\p{L})(?:today|tomorrow|yesterday|сегодня|завтра|вчера)(?!\p{L})"#,
        options: [.caseInsensitive]
    )

    private static let dateFragmentRegex = try! NSRegularExpression(
        pattern: #"(?:#\.?\s+<MONTH>|<MONTH>[,\s]+#\.?)(?:\s*,?\s*#(?:\s*г\.?)?)?"#
    )

    private static func replacing(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    /// Normalizes volatile digit sequences (`13:49`, `85%`, `42 unread`) and temporal clock/date
    /// strings (`16:19:05`, `5:54 pm`, `Sun, 15 Nov`) into canonical placeholders.
    public static func normalizeLabel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var collapsed = ""
        collapsed.reserveCapacity(min(256, trimmed.count))
        var inDigits = false
        var lastWasSpace = false

        for scalar in trimmed.unicodeScalars {
            if scalar.value >= 48 && scalar.value <= 57 { // ASCII '0'...'9'
                if !inDigits {
                    collapsed.append("#")
                    inDigits = true
                }
                lastWasSpace = false
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                inDigits = false
                if !lastWasSpace {
                    collapsed.append(" ")
                    lastWasSpace = true
                }
            } else {
                inDigits = false
                lastWasSpace = false
                collapsed.unicodeScalars.append(scalar)
            }
            if collapsed.unicodeScalars.count >= 256 { break }
        }

        var normalized = collapsed.trimmingCharacters(in: .whitespaces)
        normalized = replacing(timeRegex, in: normalized, with: "<TIME>")

        let hasTimeOrDigit = normalized.contains("#") || normalized.contains("<TIME>")
        if hasTimeOrDigit {
            normalized = replacing(monthRegex, in: normalized, with: "<MONTH>")
            normalized = replacing(weekdayRegex, in: normalized, with: "<DAY>")
            // Run March/May before Sun so "Sun, May 15" becomes "Sun, <MONTH> #" before sunContextRegex inspects it.
            normalized = replacing(marchMayContextRegex, in: normalized, with: "<MONTH>")
            normalized = replacing(sunContextRegex, in: normalized, with: "<DAY>")
            normalized = replacing(dateFragmentRegex, in: normalized, with: "<DATE>")
        }
        if normalized.contains("<TIME>") {
            normalized = replacing(relativeDayRegex, in: normalized, with: "<DAY>")
        }

        let trimmedNormalized = normalized.trimmingCharacters(in: .whitespaces)
        if trimmedNormalized.unicodeScalars.count <= 48 {
            return trimmedNormalized
        }
        return String(String.UnicodeScalarView(trimmedNormalized.unicodeScalars.prefix(48)))
            .trimmingCharacters(in: .whitespaces)
    }

    /// Process-independent deterministic FNV-1a 64-bit hash.
    private static func fnv1a64(activePackage: String, sortedTokens: [String]) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        let prime: UInt64 = 1_099_511_628_211

        @inline(__always)
        func mixBytes(_ string: String) {
            for byte in string.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* prime
            }
            hash ^= 0x1F // separator
            hash = hash &* prime
        }

        mixBytes(activePackage)
        for token in sortedTokens {
            mixBytes(token)
        }
        return hash
    }
}
