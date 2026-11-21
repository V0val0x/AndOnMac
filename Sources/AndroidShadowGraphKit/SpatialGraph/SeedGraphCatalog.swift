import Foundation

public struct SeedMergeReport: Sendable, Codable, Equatable {
    public let verticesAdded: Int
    public let edgesAdded: Int
    public let aliasesMerged: Int

    public init(verticesAdded: Int = 0, edgesAdded: Int = 0, aliasesMerged: Int = 0) {
        self.verticesAdded = verticesAdded
        self.edgesAdded = edgesAdded
        self.aliasesMerged = aliasesMerged
    }
}

/// Cross-device, Zero-PII canonical Seed Graph catalog for Android Settings (`com.android.settings`).
///
/// All hashes, deterministic edge UUIDs, tokens, labels, and multilingual/OEM semantic aliases
/// are bit-exact identical to Rust `droidpath_core::SeedGraphCatalog`.
public enum SeedGraphCatalog {
    public static let androidSettingsPackage = "com.android.settings"
    public static let seedMatchThreshold: Double = 0.60

    /// Fixed epoch (`2026-01-01T00:00:00Z`) so seed snapshots carry zero device/user timestamps.
    private static let seedEpoch = Date(timeIntervalSince1970: 1_767_225_600)

    private static func buildSeedVertex(
        title: String,
        anchorLabels: [String],
        aliases: [String],
        parentHash: UInt64?,
        depth: Int
    ) -> ScreenStateVertex {
        var tokens = Set<String>()
        tokens.insert("TextView||\(ScreenLayoutHasher.normalizeLabel(title))")

        var sampleLabels: [String] = []
        sampleLabels.reserveCapacity(anchorLabels.count + 1)
        sampleLabels.append(title)
        for anchor in anchorLabels {
            let norm = ScreenLayoutHasher.normalizeLabel(anchor)
            tokens.insert("TextView|android:id/title|\(norm)")
            if !sampleLabels.contains(anchor) {
                sampleLabels.append(anchor)
            }
        }

        // UTF-8 lexicographical sort matches Rust BTreeSet<String> iteration order bit-for-bit.
        let sortedTokens = tokens.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        let hash = ScreenLayoutHasher.fnv1a64(activePackage: androidSettingsPackage, sortedTokens: sortedTokens)

        var semanticAliases: [String] = []
        semanticAliases.reserveCapacity(aliases.count + 1)
        semanticAliases.append(title)
        for alias in aliases {
            if !semanticAliases.contains(where: { $0.caseInsensitiveCompare(alias) == .orderedSame }) {
                semanticAliases.append(alias)
            }
        }

        return ScreenStateVertex(
            layoutHash: hash,
            activePackage: androidSettingsPackage,
            sampleInteractiveLabels: sampleLabels,
            semanticTokens: tokens,
            firstSeenAt: seedEpoch,
            lastSeenAt: seedEpoch,
            visitCount: 0,
            discoveryParentHash: parentHash,
            discoveryDepth: depth,
            isSeed: true,
            semanticAliases: semanticAliases
        )
    }

    private static func buildSeedEdge(
        uuidString: String,
        fromHash: UInt64,
        toHash: UInt64,
        primarySelector: String,
        selectorAliases: [String]
    ) -> ScreenTransitionEdge {
        let action = AttributedUIAction(
            kind: .tap,
            targetDescription: primarySelector,
            selectorText: primarySelector,
            selectorAliases: selectorAliases,
            timestamp: seedEpoch
        )
        return ScreenTransitionEdge(
            id: UUID(uuidString: uuidString)!,
            fromHash: fromHash,
            toHash: toHash,
            action: action,
            actionSignature: action.signature,
            traversalCount: 0,
            averageTransitionMs: 250.0,
            isSpanningTreeEdge: true,
            lastTraversedAt: seedEpoch,
            isHazardous: false,
            hazardReason: nil,
            consecutiveFailures: 0,
            isSeed: true
        )
    }

    /// Returns the deterministic, coordinate-free, Zero-PII Android Settings (`com.android.settings`)
    /// Seed Graph covering common AOSP / Pixel / OneUI / HyperOS / OxygenOS screens in EN & RU.
    public static func androidSettingsSeedGraph() -> SpatialGraphSnapshot {
        let root = buildSeedVertex(
            title: "Settings",
            anchorLabels: [
                "Search settings",
                "Network & internet",
                "Connected devices",
                "Apps",
                "Notifications",
                "Battery",
                "Storage",
                "Sound & vibration",
                "Display & touch",
                "Security & privacy",
                "Location",
                "Accessibility",
                "System",
                "About phone",
            ],
            aliases: ["Android Settings", "Настройки", "com.android.settings"],
            parentHash: nil,
            depth: 0
        )
        let rootHash = root.layoutHash

        let network = buildSeedVertex(
            title: "Network & internet",
            anchorLabels: [
                "Internet",
                "SIMs",
                "Airplane mode",
                "Hotspot & tethering",
                "Data Saver",
                "VPN",
                "Private DNS",
            ],
            aliases: [
                "Network and internet",
                "Connections",
                "Wi-Fi & network",
                "Сеть и интернет",
                "Подключения",
            ],
            parentHash: rootHash,
            depth: 1
        )
        let internet = buildSeedVertex(
            title: "Internet",
            anchorLabels: ["Wi-Fi", "Add network", "Network preferences", "Saved networks"],
            aliases: ["Wi-Fi", "WLAN", "Интернет", "Wi‑Fi"],
            parentHash: network.layoutHash,
            depth: 2
        )

        let connectedDevices = buildSeedVertex(
            title: "Connected devices",
            anchorLabels: [
                "Pair new device",
                "Connection preferences",
                "Bluetooth",
                "Cast",
                "NFC",
            ],
            aliases: [
                "Bluetooth",
                "Bluetooth & devices",
                "Подключённые устройства",
                "Подключенные устройства",
            ],
            parentHash: rootHash,
            depth: 1
        )

        let apps = buildSeedVertex(
            title: "Apps",
            anchorLabels: [
                "See all apps",
                "Default apps",
                "Screen time",
                "Unused apps",
                "Special app access",
            ],
            aliases: ["Apps & notifications", "Applications", "Приложения"],
            parentHash: rootHash,
            depth: 1
        )

        let notifications = buildSeedVertex(
            title: "Notifications",
            anchorLabels: [
                "App notifications",
                "Notification history",
                "Conversations",
                "Bubbles",
                "Do Not Disturb",
            ],
            aliases: ["Notifications & status bar", "Уведомления"],
            parentHash: rootHash,
            depth: 1
        )

        let battery = buildSeedVertex(
            title: "Battery",
            anchorLabels: [
                "Battery usage",
                "Battery Saver",
                "Charging optimization",
                "Battery percentage",
                "Adaptive Battery",
            ],
            aliases: ["Battery & device care", "Power", "Батарея", "Питание"],
            parentHash: rootHash,
            depth: 1
        )

        let storage = buildSeedVertex(
            title: "Storage",
            anchorLabels: [
                "Free up space",
                "Images",
                "Videos",
                "Audio",
                "Documents & other",
                "Games",
                "Trash",
            ],
            aliases: ["Memory & storage", "Хранилище", "Память"],
            parentHash: rootHash,
            depth: 1
        )

        let sound = buildSeedVertex(
            title: "Sound & vibration",
            anchorLabels: [
                "Media volume",
                "Call volume",
                "Ring volume",
                "Alarm volume",
                "Do Not Disturb",
                "Phone ringtone",
                "Vibration & haptics",
            ],
            aliases: [
                "Sound and vibration",
                "Sound",
                "Sounds and vibration",
                "Звук и вибрация",
                "Звук",
            ],
            parentHash: rootHash,
            depth: 1
        )

        let display = buildSeedVertex(
            title: "Display & touch",
            anchorLabels: [
                "Brightness level",
                "Adaptive brightness",
                "Lock screen",
                "Screen timeout",
                "Dark theme",
                "Night Light",
                "Display size and text",
                "Auto-rotate screen",
            ],
            aliases: [
                "Display and touch",
                "Display",
                "Display & brightness",
                "Screen",
                "Экран",
                "Дисплей",
            ],
            parentHash: rootHash,
            depth: 1
        )
        let nightLight = buildSeedVertex(
            title: "Night Light",
            anchorLabels: ["Use Night Light", "Schedule", "Intensity"],
            aliases: [
                "Night light",
                "Eye comfort shield",
                "Reading mode",
                "Ночная подсветка",
                "Ночной режим",
                "Защита зрения",
            ],
            parentHash: display.layoutHash,
            depth: 2
        )
        let darkTheme = buildSeedVertex(
            title: "Dark theme",
            anchorLabels: ["Use Dark theme", "Schedule"],
            aliases: ["Dark mode", "Тёмная тема", "Темная тема"],
            parentHash: display.layoutHash,
            depth: 2
        )

        let security = buildSeedVertex(
            title: "Security & privacy",
            anchorLabels: [
                "Device unlock",
                "App security",
                "System & updates",
                "Privacy controls",
                "More security & privacy",
            ],
            aliases: [
                "Security and privacy",
                "Security",
                "Privacy",
                "Biometrics and security",
                "Безопасность и конфиденциальность",
                "Безопасность",
            ],
            parentHash: rootHash,
            depth: 1
        )

        let location = buildSeedVertex(
            title: "Location",
            anchorLabels: [
                "Use location",
                "App location permissions",
                "Location services",
            ],
            aliases: ["Местоположение", "Геолокация"],
            parentHash: rootHash,
            depth: 1
        )

        let accessibility = buildSeedVertex(
            title: "Accessibility",
            anchorLabels: [
                "TalkBack",
                "Color and motion",
                "Magnification",
                "Caption preferences",
                "Timing controls",
            ],
            aliases: ["Специальные возможности"],
            parentHash: rootHash,
            depth: 1
        )

        let system = buildSeedVertex(
            title: "System",
            anchorLabels: [
                "Languages",
                "Keyboard",
                "Gestures",
                "Date & time",
                "Backup",
                "System update",
                "Developer options",
            ],
            aliases: [
                "General management",
                "Additional settings",
                "Система",
                "Расширенные настройки",
            ],
            parentHash: rootHash,
            depth: 1
        )
        let languages = buildSeedVertex(
            title: "Languages",
            anchorLabels: ["System languages", "App languages", "Regional preferences"],
            aliases: [
                "Languages & input",
                "Language & region",
                "Language",
                "Языки",
                "Язык и ввод",
            ],
            parentHash: system.layoutHash,
            depth: 2
        )
        let dateTime = buildSeedVertex(
            title: "Date & time",
            anchorLabels: [
                "Set time automatically",
                "Time zone",
                "Use 24-hour format",
            ],
            aliases: ["Date and time", "Дата и время"],
            parentHash: system.layoutHash,
            depth: 2
        )
        let developerOptions = buildSeedVertex(
            title: "Developer options",
            anchorLabels: [
                "Use developer options",
                "Memory",
                "Stay awake",
                "USB debugging",
                "Wireless debugging",
                "Show layout bounds",
                "Window animation scale",
                "Animator duration scale",
            ],
            aliases: ["Developer mode", "Для разработчиков"],
            parentHash: system.layoutHash,
            depth: 2
        )

        let aboutPhone = buildSeedVertex(
            title: "About phone",
            anchorLabels: [
                "Device name",
                "Android version",
                "Model",
                "Build number",
                "IP address",
            ],
            aliases: ["About device", "About tablet", "О телефоне", "Об устройстве"],
            parentHash: rootHash,
            depth: 1
        )

        let edges: [ScreenTransitionEdge] = [
            buildSeedEdge(
                uuidString: "A0000001-0000-4000-8000-000000000001",
                fromHash: rootHash,
                toHash: network.layoutHash,
                primarySelector: "Network & internet",
                selectorAliases: [
                    "Network and internet",
                    "Connections",
                    "Wi-Fi & network",
                    "Сеть и интернет",
                    "Подключения",
                ]
            ),
            buildSeedEdge(
                uuidString: "A0000001-0000-4000-8000-000000000002",
                fromHash: network.layoutHash,
                toHash: internet.layoutHash,
                primarySelector: "Internet",
                selectorAliases: ["Wi-Fi", "WLAN", "Интернет", "Wi‑Fi"]
            ),
            buildSeedEdge(
                uuidString: "A0000001-0000-4000-8000-000000000003",
                fromHash: rootHash,
                toHash: connectedDevices.layoutHash,
                primarySelector: "Connected devices",
                selectorAliases: [
                    "Bluetooth",
                    "Bluetooth & devices",
                    "Подключённые устройства",
                    "Подключенные устройства",
                ]
            ),
            buildSeedEdge(
                uuidString: "A0000001-0000-4000-8000-000000000004",
                fromHash: rootHash,
                toHash: apps.layoutHash,
                primarySelector: "Apps",
                selectorAliases: ["Apps & notifications", "Applications", "Приложения"]
            ),
            buildSeedEdge(
                uuidString: "A0000001-0000-4000-8000-000000000005",
                fromHash: rootHash,
                toHash: notifications.layoutHash,
                primarySelector: "Notifications",
                selectorAliases: ["Notifications & status bar", "Уведомления"]
            ),
            buildSeedEdge(
                uuidString: "A0000001-0000-4000-8000-000000000006",
                fromHash: rootHash,
                toHash: battery.layoutHash,
                primarySelector: "Battery",
                selectorAliases: ["Battery & device care", "Power", "Батарея", "Питание"]
            ),
            buildSeedEdge(
                uuidString: "A0000001-0000-4000-8000-000000000007",
                fromHash: rootHash,
                toHash: storage.layoutHash,
                primarySelector: "Storage",
                selectorAliases: ["Memory & storage", "Хранилище", "Память"]
            ),
            buildSeedEdge(
                uuidString: "A0000001-0000-4000-8000-000000000008",
                fromHash: rootHash,
                toHash: sound.layoutHash,
                primarySelector: "Sound & vibration",
                selectorAliases: [
                    "Sound and vibration",
                    "Sound",
                    "Sounds and vibration",
                    "Звук и вибрация",
                    "Звук",
                ]
            ),
            buildSeedEdge(
                uuidString: "A0000001-0000-4000-8000-000000000009",
                fromHash: rootHash,
                toHash: display.layoutHash,
                primarySelector: "Display & touch",
                selectorAliases: [
                    "Display and touch",
                    "Display",
                    "Display & brightness",
                    "Screen",
                    "Экран",
                    "Дисплей",
                ]
            ),
            buildSeedEdge(
                uuidString: "A0000001-0000-4000-8000-000000000010",
                fromHash: display.layoutHash,
                toHash: nightLight.layoutHash,
                primarySelector: "Night Light",
                selectorAliases: [
                    "Night light",
                    "Eye comfort shield",
                    "Reading mode",
                    "Ночная подсветка",
                    "Ночной режим",
                    "Защита зрения",
                ]
            ),
            buildSeedEdge(
                uuidString: "A0000001-0000-4000-8000-000000000011",
                fromHash: display.layoutHash,
                toHash: darkTheme.layoutHash,
                primarySelector: "Dark theme",
                selectorAliases: ["Dark mode", "Тёмная тема", "Темная тема"]
            ),
            buildSeedEdge(
                uuidString: "A0000001-0000-4000-8000-000000000012",
                fromHash: rootHash,
                toHash: security.layoutHash,
                primarySelector: "Security & privacy",
                selectorAliases: [
                    "Security and privacy",
                    "Security",
                    "Privacy",
                    "Biometrics and security",
                    "Безопасность и конфиденциальность",
                    "Безопасность",
                ]
            ),
            buildSeedEdge(
                uuidString: "A0000001-0000-4000-8000-000000000013",
                fromHash: rootHash,
                toHash: location.layoutHash,
                primarySelector: "Location",
                selectorAliases: ["Местоположение", "Геолокация"]
            ),
            buildSeedEdge(
                uuidString: "A0000001-0000-4000-8000-000000000014",
                fromHash: rootHash,
                toHash: accessibility.layoutHash,
                primarySelector: "Accessibility",
                selectorAliases: ["Специальные возможности"]
            ),
            buildSeedEdge(
                uuidString: "A0000001-0000-4000-8000-000000000015",
                fromHash: rootHash,
                toHash: system.layoutHash,
                primarySelector: "System",
                selectorAliases: [
                    "General management",
                    "Additional settings",
                    "Система",
                    "Расширенные настройки",
                ]
            ),
            buildSeedEdge(
                uuidString: "A0000001-0000-4000-8000-000000000016",
                fromHash: system.layoutHash,
                toHash: languages.layoutHash,
                primarySelector: "Languages",
                selectorAliases: [
                    "Languages & input",
                    "Language & region",
                    "Language",
                    "Языки",
                    "Язык и ввод",
                ]
            ),
            buildSeedEdge(
                uuidString: "A0000001-0000-4000-8000-000000000017",
                fromHash: system.layoutHash,
                toHash: dateTime.layoutHash,
                primarySelector: "Date & time",
                selectorAliases: ["Date and time", "Дата и время"]
            ),
            buildSeedEdge(
                uuidString: "A0000001-0000-4000-8000-000000000018",
                fromHash: system.layoutHash,
                toHash: developerOptions.layoutHash,
                primarySelector: "Developer options",
                selectorAliases: ["Developer mode", "Для разработчиков"]
            ),
            buildSeedEdge(
                uuidString: "A0000001-0000-4000-8000-000000000019",
                fromHash: rootHash,
                toHash: aboutPhone.layoutHash,
                primarySelector: "About phone",
                selectorAliases: ["About device", "About tablet", "О телефоне", "Об устройстве"]
            ),
        ]

        var spanningChildren: [UInt64: [UInt64]] = [:]
        for edge in edges {
            spanningChildren[edge.fromHash, default: []].append(edge.toHash)
        }

        let vertices: [ScreenStateVertex] = [
            root,
            network,
            internet,
            connectedDevices,
            apps,
            notifications,
            battery,
            storage,
            sound,
            display,
            nightLight,
            darkTheme,
            security,
            location,
            accessibility,
            system,
            languages,
            dateTime,
            developerOptions,
            aboutPhone,
        ]

        return SpatialGraphSnapshot(
            rootStateHash: rootHash,
            currentStateHash: nil,
            vertices: vertices,
            edges: edges,
            spanningChildren: spanningChildren
        )
    }

    /// Normalizes a UI label into a cross-OEM, cross-locale canonical concept key
    /// so Pixel, AOSP, Samsung OneUI, Xiaomi HyperOS, and EN/RU Android Settings match deterministically.
    public static func canonicalConceptKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return "" }

        let cleaned = trimmed
            .replacingOccurrences(of: "\u{2011}", with: "-")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "-")
            .replacingOccurrences(of: "&", with: " and ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")

        switch cleaned {
        // Root Settings & search
        case "settings", "android settings", "настройки":
            return "settings"
        case "search settings", "поиск настроек", "поиск в настройках":
            return "search_settings"
        // Top-level categories
        case "network and internet", "connections", "wi-fi and network", "сеть и интернет", "подключения":
            return "network_internet"
        case "internet", "wi-fi", "wifi", "wlan", "интернет":
            return "internet_wifi"
        case "connected devices", "bluetooth", "bluetooth and devices", "подключённые устройства", "подключенные устройства":
            return "connected_devices"
        case "apps", "apps and notifications", "applications", "app management", "приложения":
            return "apps"
        case "notifications", "notifications and status bar", "уведомления":
            return "notifications"
        case "battery", "battery and device care", "power", "батарея", "питание":
            return "battery"
        case "storage", "memory and storage", "хранилище", "память":
            return "storage"
        case "sound and vibration", "sound", "sounds and vibration", "звук и вибрация", "звук":
            return "sound_vibration"
        case "display and touch", "display", "display and brightness", "screen", "экран", "дисплей":
            return "display_touch"
        case "security and privacy", "security", "privacy", "biometrics and security", "безопасность и конфиденциальность", "безопасность":
            return "security_privacy"
        case "location", "местоположение", "геолокация":
            return "location"
        case "accessibility", "специальные возможности":
            return "accessibility"
        case "system", "general management", "additional settings", "система", "расширенные настройки":
            return "system"
        case "about phone", "about device", "about tablet", "о телефоне", "об устройстве":
            return "about_phone"
        // Display sub-items
        case "brightness level", "brightness", "яркость", "уровень яркости":
            return "brightness_level"
        case "adaptive brightness", "автояркость", "адаптивная яркость":
            return "adaptive_brightness"
        case "lock screen", "экран блокировки":
            return "lock_screen"
        case "screen timeout", "тайм-аут экрана", "спящий режим":
            return "screen_timeout"
        case "dark theme", "dark mode", "тёмная тема", "темная тема":
            return "dark_theme"
        case "use dark theme", "использовать тёмную тему", "использовать темную тему":
            return "use_dark_theme"
        case "night light", "eye comfort shield", "reading mode", "ночная подсветка", "ночной режим", "защита зрения":
            return "night_light"
        case "use night light", "включить ночную подсветку":
            return "use_night_light"
        case "schedule", "расписание":
            return "schedule"
        case "intensity", "интенсивность":
            return "intensity"
        case "auto-rotate screen", "автоповорот экрана":
            return "auto_rotate"
        // System & Developer sub-items
        case "languages", "languages and input", "language and region", "language", "языки", "язык и ввод":
            return "languages"
        case "system languages", "языки системы":
            return "system_languages"
        case "app languages", "языки приложений":
            return "app_languages"
        case "date and time", "дата и время":
            return "date_time"
        case "set time automatically", "использовать время сети", "время сети":
            return "auto_time"
        case "time zone", "часовой пояс":
            return "time_zone"
        case "developer options", "developer mode", "для разработчиков":
            return "developer_options"
        case "use developer options", "использовать параметры разработчика":
            return "use_developer_options"
        case "usb debugging", "отладка по usb":
            return "usb_debugging"
        case "wireless debugging", "беспроводная отладка":
            return "wireless_debugging"
        case "show layout bounds", "показывать границы элементов", "границы элементов":
            return "show_layout_bounds"
        case "stay awake", "не выключать экран":
            return "stay_awake"
        // Network / Battery / About sub-items
        case "airplane mode", "режим полёта", "режим полета":
            return "airplane_mode"
        case "hotspot and tethering", "точка доступа и модем":
            return "hotspot_tethering"
        case "private dns", "персональный dns-сервер":
            return "private_dns"
        case "battery usage", "использование батареи":
            return "battery_usage"
        case "battery saver", "экономия заряда":
            return "battery_saver"
        case "battery percentage", "заряд батареи в процентах":
            return "battery_percentage"
        case "android version", "версия android":
            return "android_version"
        case "build number", "номер сборки":
            return "build_number"
        case "device name", "имя устройства":
            return "device_name"
        case "pair new device", "подключить новое устройство":
            return "pair_new_device"
        case "app notifications", "уведомления приложений":
            return "app_notifications"
        case "do not disturb", "не беспокоить":
            return "do_not_disturb"
        case "see all apps", "показать все приложения":
            return "see_all_apps"
        case "default apps", "приложения по умолчанию":
            return "default_apps"
        case "use location", "использовать геолокацию":
            return "use_location"
        default:
            return cleaned
        }
    }

    private static func extractLiveConceptKeys(labels: [String], tokens: Set<String>) -> Set<String> {
        var keys = Set<String>()
        for raw in labels {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || (trimmed.hasPrefix("<") && trimmed.hasSuffix(">")) {
                continue
            }
            let key = canonicalConceptKey(trimmed)
            if !key.isEmpty {
                keys.insert(key)
            }
        }
        for token in tokens {
            let parts = token.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count == 3 {
                let trimmed = String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || (trimmed.hasPrefix("<") && trimmed.hasSuffix(">")) {
                    continue
                }
                let key = canonicalConceptKey(trimmed)
                if !key.isEmpty {
                    keys.insert(key)
                }
            }
        }
        return keys
    }

    /// Computes a cross-device semantic match score in `[0.0, 1.0]` between a live screen fingerprint
    /// and an unhydrated Seed Graph vertex (`seedVertex.isSeed == true`).
    public static func seedMatchScore(
        liveFingerprint: ScreenSemanticFingerprint,
        seedVertex: ScreenStateVertex
    ) -> Double {
        guard seedVertex.isSeed, liveFingerprint.activePackage == seedVertex.activePackage else {
            return 0.0
        }
        let liveKeys = extractLiveConceptKeys(
            labels: liveFingerprint.sampleInteractiveLabels,
            tokens: liveFingerprint.tokens
        )
        return seedMatchScore(liveKeys: liveKeys, seedVertex: seedVertex)
    }

    public static func seedMatchScore(
        realVertex: ScreenStateVertex,
        seedVertex: ScreenStateVertex
    ) -> Double {
        guard seedVertex.isSeed,
              !realVertex.isSeed,
              realVertex.activePackage == seedVertex.activePackage else {
            return 0.0
        }
        let liveKeys = extractLiveConceptKeys(
            labels: realVertex.sampleInteractiveLabels,
            tokens: realVertex.semanticTokens
        )
        return seedMatchScore(liveKeys: liveKeys, seedVertex: seedVertex)
    }

    private static func seedMatchScore(liveKeys: Set<String>, seedVertex: ScreenStateVertex) -> Double {
        guard !liveKeys.isEmpty else { return 0.0 }

        var titleKeys = Set<String>()
        for alias in seedVertex.semanticAliases {
            let k = canonicalConceptKey(alias)
            if !k.isEmpty {
                titleKeys.insert(k)
            }
        }
        if let first = seedVertex.sampleInteractiveLabels.first {
            let k = canonicalConceptKey(first)
            if !k.isEmpty {
                titleKeys.insert(k)
            }
        }

        let allSeedAnchors = extractLiveConceptKeys(
            labels: seedVertex.sampleInteractiveLabels,
            tokens: seedVertex.semanticTokens
        )

        let titleMatched = titleKeys.contains(where: { liveKeys.contains($0) })
        let nonTitleAnchors = allSeedAnchors.filter { !titleKeys.contains($0) }
        let matchedNonTitle = nonTitleAnchors.filter { liveKeys.contains($0) }.count

        if seedVertex.discoveryDepth == 0 {
            let totalMatched = allSeedAnchors.filter { liveKeys.contains($0) }.count
            guard totalMatched >= 3 else { return 0.0 }
            let denom = Double(min(max(allSeedAnchors.count, 3), 6))
            let ratio = min(Double(totalMatched) / denom, 1.0)
            return 0.65 + 0.30 * ratio
        }

        if titleMatched && matchedNonTitle >= 1 {
            let denom = Double(min(max(nonTitleAnchors.count, 1), 3))
            let ratio = min(Double(matchedNonTitle) / denom, 1.0)
            return 0.76 + 0.20 * ratio
        }

        if matchedNonTitle >= 2 {
            let denom = Double(min(max(nonTitleAnchors.count, 2), 4))
            let ratio = min(Double(matchedNonTitle) / denom, 1.0)
            return 0.64 + 0.22 * ratio
        }

        return 0.0
    }
}
