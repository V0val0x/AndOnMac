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
            CommandMenu(L10n.tr("Дисплей телефона", "Phone Display", lang: appState.lang)) {
                Button(L10n.tr("Домой", "Home", lang: appState.lang)) {
                    appState.triggerHome()
                }
                .keyboardShortcut("1", modifiers: .command)
                
                Button(L10n.tr("Переключатель приложений", "App Switcher", lang: appState.lang)) {
                    appState.triggerAppSwitch()
                }
                .keyboardShortcut("2", modifiers: .command)
                
                Button(L10n.tr("Центр уведомлений", "Notification Center", lang: appState.lang)) {
                    appState.triggerNotifications()
                }
                .keyboardShortcut("3", modifiers: .command)
                
                Button(L10n.tr("Медиатека и перенос фото", "Phone Gallery & Photo Transfer", lang: appState.lang)) {
                    appState.openDrawer(mode: .gallery)
                }
                .keyboardShortcut("4", modifiers: .command)

                Button(L10n.tr("Файловый менеджер (Android)", "File Manager (Android)", lang: appState.lang)) {
                    appState.openDrawer(mode: .files)
                }
                .keyboardShortcut("5", modifiers: .command)
                
                Divider()
                
                Button(L10n.tr("Назад", "Back", lang: appState.lang)) {
                    appState.triggerBack()
                }
                .keyboardShortcut(.delete, modifiers: .command)
                
                Button(L10n.tr("Блокировка / Экран", "Lock / Screen", lang: appState.lang)) {
                    appState.triggerPower()
                }
                .keyboardShortcut("p", modifiers: .command)
                
                Divider()
                
                Button(L10n.tr("Стандартный размер (100%)", "Standard Size (100%)", lang: appState.lang)) {
                    appState.windowScale = .standard
                }
                .keyboardShortcut("0", modifiers: .command)
                
                Button(L10n.tr("Увеличить (125%)", "Zoom In (125%)", lang: appState.lang)) {
                    appState.windowScale = .larger
                }
                .keyboardShortcut("+", modifiers: .command)
                
                Button(L10n.tr("Уменьшить (75%)", "Zoom Out (75%)", lang: appState.lang)) {
                    appState.windowScale = .smaller
                }
                .keyboardShortcut("-", modifiers: .command)
                
                Divider()
                
                Menu(L10n.tr("Корпус и модель смартфона", "Phone Frame & Model", lang: appState.lang)) {
                    ForEach(PhoneFrameStyle.allCases) { style in
                        Button(style.displayName) {
                            appState.frameStyle = style
                        }
                    }
                    
                    Divider()
                    
                    Toggle(L10n.tr("Фронтальная камера (Punch Hole)", "Front Camera (Punch Hole)", lang: appState.lang), isOn: $appState.showFrontCamera)
                }

                Menu(L10n.tr("Язык / Language", "Language / Язык", lang: appState.lang)) {
                    ForEach(AppLanguage.allCases) { language in
                        Button {
                            appState.appLanguage = language
                        } label: {
                            if appState.appLanguage == language {
                                Label(language.displayName(in: appState.lang), systemImage: "checkmark")
                            } else {
                                Text(language.displayName(in: appState.lang))
                            }
                        }
                    }
                }
                
                Toggle(L10n.tr("Отправка по Enter (Shift+Enter для новой строки)", "Send on Enter (Shift+Enter for newline)", lang: appState.lang), isOn: $appState.sendOnEnter)
                
                Divider()
                
                Button(L10n.tr("Перезапустить ADB и восстановить USB", "Restart ADB & Reset USB", lang: appState.lang)) {
                    Task {
                        await appState.resetUSBAndADB()
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                
                Button(L10n.tr("Завершить трансляцию", "Stop Mirroring", lang: appState.lang)) {
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
                    
                    Button(appState.isMirroring
                           ? L10n.tr("Остановить экран", "Stop Mirroring", lang: appState.lang)
                           : L10n.tr("Открыть экран", "Open Screen", lang: appState.lang)) {
                        appState.toggleMirroring()
                    }
                } else {
                    Text(L10n.tr("Нет подключенных устройств", "No connected devices", lang: appState.lang))
                        .font(.caption)
                }
                
                Divider()
                
                Button(L10n.tr("Поиск устройств", "Scan Devices", lang: appState.lang)) {
                    appState.refreshDevices()
                }
                
                Button(L10n.tr("Подключить по Wi-Fi...", "Connect via Wi-Fi...", lang: appState.lang)) {
                    appState.showPairingSheet = true
                    NSApp.activate(ignoringOtherApps: true)
                }
                
                Button(L10n.tr("Сбросить ADB и восстановить USB", "Restart ADB & Reset USB", lang: appState.lang)) {
                    Task {
                        await appState.resetUSBAndADB()
                    }
                }

                Menu(L10n.tr("Язык / Language", "Language", lang: appState.lang)) {
                    ForEach(AppLanguage.allCases) { language in
                        Button {
                            appState.appLanguage = language
                        } label: {
                            if appState.appLanguage == language {
                                Label(language.displayName(in: appState.lang), systemImage: "checkmark")
                            } else {
                                Text(language.displayName(in: appState.lang))
                            }
                        }
                    }
                }
                
                Divider()
                
                Button(L10n.tr("Выход", "Quit", lang: appState.lang)) {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(6)
        }

        Settings {
            SettingsView(appState: appState)
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        let lang = appState.lang
        Form {
            Section(L10n.tr("Язык интерфейса", "Interface Language", lang: lang)) {
                Picker(L10n.tr("Язык", "Language", lang: lang), selection: $appState.appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName(in: lang)).tag(language)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section(L10n.tr("Зеркалирование и ввод", "Mirroring & Input", lang: lang)) {
                Toggle(L10n.tr("Выключать экран телефона при трансляции", "Turn off phone screen while mirroring", lang: lang), isOn: $appState.turnScreenOff)
                Toggle(L10n.tr("Передавать звук на Mac", "Forward audio to Mac", lang: lang), isOn: $appState.forwardAudio)
                Toggle(L10n.tr("Не давать телефону засыпать", "Keep phone awake", lang: lang), isOn: $appState.stayAwake)
                Toggle(L10n.tr("Отправка по Enter (Shift+Enter — новая строка)", "Send on Enter (Shift+Enter for newline)", lang: lang), isOn: $appState.sendOnEnter)
                Toggle(L10n.tr("Фронтальная камера (Punch Hole)", "Front Camera (Punch Hole)", lang: lang), isOn: $appState.showFrontCamera)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 320)
    }
}
