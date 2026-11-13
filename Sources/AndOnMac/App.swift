import SwiftUI
import AppKit

@main
struct AndOnMacApp: App {
    @StateObject private var appState = AppState()
    
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }
    
    var body: some Scene {
        WindowGroup {
            MainWindowView(appState: appState)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .windowResizability(.contentSize)
        .defaultSize(width: 420, height: 820)
        .commands {
            // macOS Sequoia iPhone Mirroring Menu & Shortcuts
            CommandMenu("Дисплей телефона") {
                Button("Домой") {
                    appState.triggerHome()
                }
                .keyboardShortcut("1", modifiers: .command)
                
                Button("Переключатель приложений") {
                    appState.triggerAppSwitch()
                }
                .keyboardShortcut("2", modifiers: .command)
                
                Button("Центр уведомлений") {
                    appState.triggerNotifications()
                }
                .keyboardShortcut("3", modifiers: .command)
                
                Button("Медиатека и перенос фото") {
                    appState.showPhotoDrawer.toggle()
                }
                .keyboardShortcut("4", modifiers: .command)
                
                Divider()
                
                Button("Назад") {
                    appState.triggerBack()
                }
                .keyboardShortcut(.delete, modifiers: .command)
                
                Button("Блокировка / Экран") {
                    appState.triggerPower()
                }
                .keyboardShortcut("p", modifiers: .command)
                
                Divider()
                
                Button("Стандартный размер (100%)") {
                    appState.windowScale = .standard
                }
                .keyboardShortcut("0", modifiers: .command)
                
                Button("Увеличить (125%)") {
                    appState.windowScale = .larger
                }
                .keyboardShortcut("+", modifiers: .command)
                
                Button("Уменьшить (75%)") {
                    appState.windowScale = .smaller
                }
                .keyboardShortcut("-", modifiers: .command)
                
                Divider()
                
                Menu("Корпус и модель смартфона") {
                    ForEach(PhoneFrameStyle.allCases) { style in
                        Button(style.displayName) {
                            appState.frameStyle = style
                        }
                    }
                    
                    Divider()
                    
                    Toggle("Фронтальная камера (Punch Hole)", isOn: $appState.showFrontCamera)
                }
                
                Toggle("Отправка по Enter (Shift+Enter для новой строки)", isOn: $appState.sendOnEnter)
                
                Divider()
                
                Button("Завершить трансляцию") {
                    if appState.isMirroring {
                        appState.toggleMirroring()
                    } else {
                        NSApp.keyWindow?.performClose(nil)
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
            }
        }
        
        // Menu Bar Extra for fast quick-access like Control Center
        MenuBarExtra("AndOnMac", systemImage: "iphone.gen3") {
            VStack(alignment: .leading, spacing: 8) {
                if let device = appState.selectedDevice {
                    Text(device.displayName)
                        .font(.headline)
                    Text("\(device.connectionType.rawValue) • \(device.batteryLevel.map { "\($0)%" } ?? "")")
                        .font(.caption)
                    
                    Divider()
                    
                    Button(appState.isMirroring ? "Остановить экран" : "Открыть экран") {
                        appState.toggleMirroring()
                    }
                } else {
                    Text("Нет подключенных устройств")
                        .font(.caption)
                }
                
                Divider()
                
                Button("Поиск устройств") {
                    appState.refreshDevices()
                }
                
                Button("Подключить по Wi-Fi...") {
                    appState.showPairingSheet = true
                    NSApp.activate(ignoringOtherApps: true)
                }
                
                Divider()
                
                Button("Выход") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(6)
        }
    }
}
