import SwiftUI

public struct MainWindowView: View {
    @ObservedObject var appState: AppState
    
    public init(appState: AppState) {
        self.appState = appState
    }
    
    public var body: some View {
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
                        Text("Устройства не найдены")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 8)
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
                VStack(alignment: .leading, spacing: 18) {
                    Text("Настройки iPhone Mirroring")
                        .font(.title3.bold())
                    
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
                .frame(width: 300)
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
