import SwiftUI
import AppKit

/// Native macOS Control Center-style Menu Bar popover for AndOnMac.
public struct MenuBarView: View {
    @ObservedObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var discovery = DiscoveryService.shared
    @ObservedObject private var qrPairing = QRPairingService.shared
    @ObservedObject private var routerBypass = RouterlessBypassService.shared
    @State private var appSearchQuery: String = ""
    @State private var showQRPairing: Bool = false

    public init(appState: AppState) {
        self.appState = appState
    }

    private var filteredApps: [AndroidAppItem] {
        let q = appSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return Array(appState.installedApps.prefix(12)) }
        return appState.installedApps.filter {
            $0.displayName.localizedCaseInsensitiveContains(q) ||
            $0.packageName.localizedCaseInsensitiveContains(q)
        }
    }

    public var body: some View {
        let lang = appState.lang
        VStack(alignment: .leading, spacing: 10) {
            // Header: Connection status, Battery & USB/Wi-Fi badge
            HStack(spacing: 10) {
                Image(systemName: appState.selectedDevice?.connectionType == .wifi ? "wifi" : "cable.connector")
                    .symbolRenderingMode(.hierarchical)
                    .symbolEffect(.pulse, isActive: appState.selectedDevice != nil && appState.isMirroring)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(appState.selectedDevice != nil ? .green : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.selectedDevice?.displayName ?? L10n.tr("Нет подключённых устройств", "No Connected Devices", lang: lang))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    if let device = appState.selectedDevice {
                        HStack(spacing: 6) {
                            Text(device.connectionType.rawValue)
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.primary.opacity(0.08))
                                .cornerRadius(4)

                            if let battery = device.batteryLevel {
                                Label("\(battery)%", systemImage: battery > 20 ? "battery.75" : "battery.25")
                                    .font(.system(size: 11))
                                    .foregroundColor(battery > 20 ? .secondary : .orange)
                            }
                        }
                    } else if let host = discovery.detectedConnectHost, let port = discovery.detectedConnectPort {
                        Button {
                            Task { await appState.connectWireless(host: host, port: port) }
                        } label: {
                            Label(L10n.tr("Подключить \(host):\(port)", "Connect \(host):\(port)", lang: lang), systemImage: "bolt.horizontal.circle.fill")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.link)
                    }
                }

                Spacer()

                if appState.selectedDevice != nil {
                    Button {
                        appState.toggleMirroring()
                    } label: {
                        Text(appState.isMirroring
                             ? L10n.tr("Стоп", "Stop", lang: lang)
                             : L10n.tr("Экран", "Mirror", lang: lang))
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            Divider()

            // Quick Toggles
            VStack(alignment: .leading, spacing: 6) {
                Toggle(L10n.tr("Выключать экран телефона", "Screen Off (--turn-screen-off)", lang: lang), isOn: $appState.turnScreenOff)
                Toggle(L10n.tr("Не давать засыпать", "Stay Awake", lang: lang), isOn: $appState.stayAwake)
                Toggle(L10n.tr("Передавать звук на Mac", "Audio Forwarding", lang: lang), isOn: $appState.forwardAudio)
                Toggle(L10n.tr("Фоновый Continuity Bridge", "Background Continuity Bridge", lang: lang), isOn: $appState.continuityBridgeEnabled)
                    .onChange(of: appState.continuityBridgeEnabled) { _, _ in
                        appState.syncContinuityBridgeState()
                    }
                Toggle(L10n.tr("120Hz Performance HUD", "120Hz Performance HUD", lang: lang), isOn: $appState.showPerformanceHUD)
                Toggle(L10n.tr("Авто-Hotspot при изоляции сети (USB)", "Auto-Hotspot on Isolated Wi-Fi (USB)", lang: lang), isOn: $appState.autoHotspotOnIsolation)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.system(size: 12))

            if routerBypass.isRouterIsolationDetected {
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        L10n.tr("Изоляция роутера — прямой канал", "Router Isolation Detected — Switch to Direct Link", lang: lang),
                        systemImage: "wifi.exclamationmark"
                    )
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.orange)

                    HStack(spacing: 6) {
                        Button(L10n.tr("Hotspot телефона", "Direct Hotspot", lang: lang)) {
                            Task {
                                let (ok, msg) = await routerBypass.connectDirectHotspot()
                                appState.statusMessage = ok ? "Hotspot: \(msg)" : msg
                                if ok { appState.refreshDevices() }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)

                        Button("BT PAN") {
                            Task {
                                let names = appState.knownDevices.map(\.name)
                                let (ok, msg) = await routerBypass.setupAndConnectBluetoothPAN(
                                    preferredDeviceNames: names,
                                    openSettingsIfUnavailable: true
                                )
                                appState.statusMessage = ok ? "BT PAN: \(msg)" : msg
                                if ok { appState.refreshDevices() }
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
                .padding(8)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(8)
            }

            if appState.selectedDevice == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            showQRPairing.toggle()
                        }
                        if showQRPairing {
                            qrPairing.onPairedSuccessfully = { _ in
                                Task { @MainActor in
                                    appState.refreshDevices()
                                }
                            }
                            qrPairing.startSession()
                        } else {
                            qrPairing.stopSession()
                        }
                    } label: {
                        HStack {
                            Label(L10n.tr("Беспроводной QR-код (Android 11+)", "QR Code Wireless Pairing", lang: lang), systemImage: "qrcode")
                                .font(.system(size: 11, weight: .semibold))
                            Spacer()
                            Image(systemName: showQRPairing ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10))
                        }
                    }
                    .buttonStyle(.plain)

                    if showQRPairing && !qrPairing.qrPayload.isEmpty {
                        HStack(spacing: 10) {
                            QRCodeView(payload: qrPairing.qrPayload, size: 104)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.tr("Откройте «Отладка по Wi-Fi» → «Подключить по QR»", "Open Wireless Debugging → Pair with QR code", lang: lang))
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(qrPairing.serviceName)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.cyan)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.top, 2)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }

            if appState.selectedDevice != nil {
                HStack(spacing: 8) {
                    Button {
                        appState.toggleRecording()
                    } label: {
                        Label(
                            appState.isRecording
                                ? L10n.tr("Стоп запись", "Stop Rec", lang: lang)
                                : L10n.tr("Запись экрана", "Record Screen", lang: lang),
                            systemImage: appState.isRecording ? "stop.circle.fill" : "record.circle"
                        )
                        .foregroundColor(appState.isRecording ? .red : .primary)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        appState.triggerScreenOCR()
                    } label: {
                        Label(L10n.tr("Текст с экрана", "Grab Text", lang: lang), systemImage: "text.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Divider()

                // Standalone Android App Launcher (Virtual Display Windows)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(L10n.tr("Запуск Android-приложения", "Launch Android App", lang: lang), systemImage: "macwindow.on.rectangle")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button {
                            appState.loadInstalledApps()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                    }

                    TextField(L10n.tr("Поиск пакета или приложения...", "Search apps...", lang: lang), text: $appSearchQuery)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)

                    if appState.isLoadingApps {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else if appState.installedApps.isEmpty {
                        Button(L10n.tr("Загрузить список приложений", "Load Installed Apps", lang: lang)) {
                            appState.loadInstalledApps()
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                    } else if filteredApps.isEmpty {
                        Text(L10n.tr("Приложения не найдены", "No matching apps found", lang: lang))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    } else {
                        ScrollView {
                            VStack(spacing: 3) {
                                ForEach(filteredApps) { app in
                                    Button {
                                        appState.launchStandaloneApp(app)
                                    } label: {
                                        HStack {
                                            Text(app.displayName)
                                                .font(.system(size: 12, weight: .medium))
                                                .lineLimit(1)
                                            Spacer()
                                            Text(app.packageName)
                                                .font(.system(size: 9))
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                        }
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 4)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .frame(height: min(CGFloat(filteredApps.count) * 27.0 + 4.0, 135.0))
                    }
                }
            }

            Divider()

            // AI Agent Bridge (Built-in MCP Server)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Toggle(isOn: $appState.mcpServerEnabled) {
                        HStack(spacing: 6) {
                            Image(systemName: "cpu.fill")
                                .foregroundColor(appState.isMCPRunning ? .green : .secondary)
                            Text("AI Agent Bridge (MCP)")
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .onChange(of: appState.mcpServerEnabled) { _, _ in
                        appState.syncMCPServerState()
                    }
                }

                HStack(spacing: 6) {
                    Circle()
                        .fill(appState.isMCPRunning ? (appState.isMCPAgentPaused ? Color.orange : Color.green) : Color.secondary.opacity(0.4))
                        .frame(width: 7, height: 7)
                    Text(appState.isMCPRunning
                         ? (appState.isMCPAgentPaused
                            ? L10n.tr("Пауза (:\(appState.mcpServerPort))", "Paused (:\(appState.mcpServerPort))", lang: lang)
                            : L10n.tr("Работает на :\(appState.mcpServerPort)", "Running on :\(appState.mcpServerPort)", lang: lang))
                         : L10n.tr("Выключен", "Off", lang: lang))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)

                    Spacer()

                    TextField("Port", value: $appState.mcpServerPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.mini)
                        .frame(width: 56)
                }

                if let activity = appState.mcpAgentActivity {
                    Text(activity)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.cyan)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Button {
                        appState.copyMCPConfigToClipboard()
                    } label: {
                        Label(L10n.tr("Копировать MCP Config", "Copy MCP Config", lang: lang), systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        appState.toggleMCPAgentPause()
                    } label: {
                        Label(
                            appState.isMCPAgentPaused
                                ? L10n.tr("Возобновить", "Resume", lang: lang)
                                : L10n.tr("Пауза агента", "Pause Agent", lang: lang),
                            systemImage: appState.isMCPAgentPaused ? "play.fill" : "hand.raised.fill"
                        )
                        .foregroundColor(appState.isMCPAgentPaused ? .green : .orange)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                HStack(spacing: 6) {
                    Button {
                        appState.triggerVisualMCPCapture()
                    } label: {
                        Label(L10n.tr("Создать MCP Tool", "Create MCP Tool", lang: lang), systemImage: "plus.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!appState.isMirroring)

                    Button {
                        openWindow(id: "tool-hub")
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        Label("Tool Hub", systemImage: "wrench.and.screwdriver")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Divider()

            // Semantic Screen Memory ("Recall")
            HStack(spacing: 8) {
                Toggle(isOn: $appState.screenMemoryEnabled) {
                    HStack(spacing: 6) {
                        Image(systemName: "brain.head.profile")
                            .foregroundColor(appState.screenMemoryEnabled ? .cyan : .secondary)
                        Text("Screen Memory")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .onChange(of: appState.screenMemoryEnabled) { _, _ in
                    appState.syncScreenMemoryState()
                }

                Spacer()

                Button {
                    appState.triggerRecallSearch()
                } label: {
                    Label("Recall", systemImage: "magnifyingglass")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Divider()

            // Device Actions & Dock Toggle
            HStack {
                Button(L10n.tr("Поиск", "Scan", lang: lang)) {
                    appState.refreshDevices()
                }
                Button(L10n.tr("Wi-Fi QR...", "Wi-Fi Pair...", lang: lang)) {
                    appState.showPairingSheet = true
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button(L10n.tr("Сброс ADB", "Reset ADB", lang: lang)) {
                    Task { await appState.resetUSBAndADB() }
                }
            }
            .controlSize(.small)

            Toggle(L10n.tr("Скрыть иконку из Dock", "Hide Dock Icon", lang: lang), isOn: $appState.hideDockIcon)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 11))
                .onChange(of: appState.hideDockIcon) { _, _ in
                    appState.applyDockVisibility()
                }

            HStack {
                Button(L10n.tr("Показать окно", "Show Window", lang: lang)) {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first?.makeKeyAndOrderFront(nil)
                }
                .controlSize(.small)

                Spacer()

                Button(L10n.tr("Выход", "Quit", lang: lang)) {
                    NSApplication.shared.terminate(nil)
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 310)
        .onAppear {
            if appState.selectedDevice != nil && appState.installedApps.isEmpty {
                appState.loadInstalledApps()
            }
        }
        .onChange(of: appState.selectedDevice?.id) { _, newSerial in
            if newSerial != nil {
                appState.loadInstalledApps()
            } else {
                appState.installedApps = []
            }
        }
    }
}
