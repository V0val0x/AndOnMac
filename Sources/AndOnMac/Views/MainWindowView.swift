import SwiftUI

public struct MainWindowView: View {
    @ObservedObject var appState: AppState
    
    public init(appState: AppState) {
        self.appState = appState
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // 1. Dependency Auto-Installer Banner (if adb/scrcpy missing)
            if let deps = appState.dependencyStatus, !deps.isAllReady {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                        .font(.title3)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Требуется быстрая автоматическая настройка")
                            .font(.subheadline.bold())
                        Text("Для работы зеркалирования нужны компоненты ADB и scrcpy.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    if appState.isInstallingDependencies {
                        ProgressView()
                            .controlSize(.small)
                        Text("Установка...")
                            .font(.caption)
                    } else {
                        Button {
                            appState.runAutoInstaller()
                        } label: {
                            Label("Установить всё в 1 клик", systemImage: "sparkles")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(12)
                .background(Color.yellow.opacity(0.12))
                .overlay(Divider(), alignment: .bottom)
            }
            
            // 2. Unauthorized Device Guidance Banner
            if let unauth = appState.devices.first(where: { $0.state == .unauthorized }) {
                HStack(spacing: 10) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundColor(.orange)
                    Text("Разблокируйте **\(unauth.displayName)** и нажмите на экране **«Разрешить отладку с этого компьютера»**.")
                        .font(.caption)
                    Spacer()
                }
                .padding(10)
                .background(Color.orange.opacity(0.15))
                .overlay(Divider(), alignment: .bottom)
            }
            
            NavigationSplitView {
                // Sidebar: Devices & Notifications
                VStack(alignment: .leading, spacing: 14) {
                    // Devices Section
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Устройства")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            Spacer()
                            if appState.isScanning {
                                ProgressView().controlSize(.small)
                            } else {
                                Button {
                                    appState.refreshDevices()
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        
                        if appState.devices.isEmpty {
                            if appState.knownDevices.isEmpty {
                                Text("Устройства не найдены")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.vertical, 8)
                            } else {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Сохраненные устройства:")
                                        .font(.caption2.bold())
                                        .foregroundColor(.secondary)
                                    ForEach(appState.knownDevices) { known in
                                        HStack(spacing: 8) {
                                            Image(systemName: "wifi")
                                                .foregroundColor(.secondary)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(known.name)
                                                    .font(.caption.bold())
                                                Text("Автоподключение...")
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                            }
                                            Spacer()
                                            ProgressView().controlSize(.mini)
                                        }
                                        .padding(6)
                                        .background(Color.secondary.opacity(0.06))
                                        .cornerRadius(6)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        } else {
                            ForEach(appState.devices) { device in
                                HStack {
                                    Image(systemName: device.connectionType == .wifi ? "wifi" : "cable.connector")
                                        .foregroundColor(device.id == appState.selectedDeviceId ? .accentColor : .secondary)
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(device.displayName)
                                            .font(.subheadline.bold())
                                        Text("\(device.connectionType.rawValue) • \(device.state.rawValue)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if let level = device.batteryLevel {
                                        Text("\(level)%")
                                            .font(.caption2.monospacedDigit())
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(8)
                                .background(device.id == appState.selectedDeviceId ? Color.accentColor.opacity(0.15) : Color.clear)
                                .cornerRadius(8)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    appState.selectedDeviceId = device.id
                                }
                            }
                        }
                    }
                    
                    Divider()
                    
                    // Notifications Feed Section (Mirrored from Android)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Уведомления с телефона")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        
                        if appState.notifications.isEmpty {
                            Text("Входящих уведомлений пока нет")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.top, 4)
                        } else {
                            ScrollView {
                                LazyVStack(spacing: 8) {
                                    ForEach(appState.notifications) { item in
                                        VStack(alignment: .leading, spacing: 3) {
                                            HStack {
                                                Text(item.appName)
                                                    .font(.caption.bold())
                                                    .foregroundColor(.accentColor)
                                                Spacer()
                                                Text(item.timestamp, style: .time)
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                            }
                                            Text(item.title)
                                                .font(.caption.bold())
                                            Text(item.text)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                                .lineLimit(2)
                                        }
                                        .padding(8)
                                        .background(Color.secondary.opacity(0.06))
                                        .cornerRadius(6)
                                    }
                                }
                            }
                        }
                    }
                    
                    Spacer()
                    
                    // Bottom Quick Action
                    Button {
                        appState.showPairingSheet = true
                    } label: {
                        Label("Добавить по Wi-Fi", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
                .frame(minWidth: 240, idealWidth: 260)
            } detail: {
                // Main Detail: Visual Phone Frame & Controls
                HSplitView {
                    // Phone Window Mockup
                    PhoneMirrorFrameView(appState: appState)
                        .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                    
                    // Control Panel & Settings
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            Text("Настройки iPhone Mirroring")
                                .font(.title3.bold())
                            
                            // Automation Section
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Автоматизация (Zero-Config)")
                                    .font(.subheadline.bold())
                                    .foregroundColor(.accentColor)
                                
                                Toggle(isOn: $appState.autoConnect) {
                                    VStack(alignment: .leading) {
                                        Text("Мгновенный старт при подключении")
                                            .font(.subheadline)
                                        Text("Экран открывается сам при подключении телефона")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                
                                Toggle(isOn: $appState.autoWirelessPromote) {
                                    VStack(alignment: .leading) {
                                        Text("Авто-переключение на Wi-Fi")
                                            .font(.subheadline)
                                        Text("Запоминает устройство и переходит на Wi-Fi при отключении кабеля")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .padding(12)
                            .background(Color.accentColor.opacity(0.06))
                            .cornerRadius(10)
                            
                            Toggle(isOn: $appState.turnScreenOff) {
                                VStack(alignment: .leading) {
                                    Text("Выключать дисплей телефона")
                                        .font(.subheadline)
                                    Text("Экран смартфона не светится и экономит заряд батареи")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            Toggle(isOn: $appState.forwardAudio) {
                                VStack(alignment: .leading) {
                                    Text("Транслировать звук на Mac")
                                        .font(.subheadline)
                                    Text("Звуки приложений и видео выводятся через динамики Mac")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            Toggle(isOn: $appState.stayAwake) {
                                VStack(alignment: .leading) {
                                    Text("Не давать телефону уснуть")
                                        .font(.subheadline)
                                    Text("Смартфон остается активным во время работы")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            Divider()
                            
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Стиль рамки:")
                                    .font(.subheadline.bold())
                                Picker("", selection: $appState.frameStyle) {
                                    ForEach(PhoneFrameStyle.allCases) { style in
                                        Text(style.rawValue).tag(style)
                                    }
                                }
                                .pickerStyle(.segmented)
                            }
                            
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Частота кадров (FPS): \(appState.maxFps)")
                                    .font(.subheadline)
                                Slider(value: Binding(
                                    get: { Double(appState.maxFps) },
                                    set: { appState.maxFps = Int($0) }
                                ), in: 30...120, step: 10)
                            }
                            
                            Spacer()
                            
                            // Status Footer
                            HStack {
                                Circle()
                                    .fill(appState.isMirroring ? Color.green : Color.orange)
                                    .frame(width: 8, height: 8)
                                Text(appState.statusMessage)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(20)
                    }
                    .frame(width: 320)
                }
            }
        }
        .sheet(isPresented: $appState.showPairingSheet) {
            WirelessPairingView(appState: appState)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    appState.toggleMirroring()
                } label: {
                    Label(
                        appState.isMirroring ? "Остановить" : "Зеркалировать",
                        systemImage: appState.isMirroring ? "stop.fill" : "play.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(appState.isMirroring ? .red : .accentColor)
            }
        }
    }
}
