import SwiftUI
import AppKit

/// Native macOS Control Center-style Menu Bar popover for AndOnMac.
public struct MenuBarView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var discovery = DiscoveryService.shared
    @State private var appSearchQuery: String = ""

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
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.system(size: 12))

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
                    } else if filteredApps.isEmpty {
                        Button(L10n.tr("Загрузить список приложений", "Load Installed Apps", lang: lang)) {
                            appState.loadInstalledApps()
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
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
                        .frame(maxHeight: 130)
                    }
                }
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
    }
}
