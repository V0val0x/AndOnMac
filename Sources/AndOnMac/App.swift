import SwiftUI
import AppKit

@main
enum AndOnMacEntryPoint {
    static func main() {
        if CommandLine.arguments.contains("--mcp-stdio") {
            MCPStdioTransport.runBlocking()
            return
        }
        AndOnMacApp.main()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        MirrorService.shared.stopMirroring()
        MirrorService.shared.stopRecording()
        AndroidAppLauncherService.shared.stopAllAppWindows()
        ContinuityBridge.shared.stop()
        ScreenMemorySnapshotter.shared.stop()
        MCPHTTPServer.shared.stop()
        ProcessLifecycleManager.shared.terminateAllProcesses(synchronousWait: true, gracePeriodMs: 250)
    }
}

struct AndOnMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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

                Button(L10n.tr("Распознать текст с экрана", "Grab Text from Screen", lang: appState.lang)) {
                    appState.triggerScreenOCR()
                }
                .keyboardShortcut("x", modifiers: [.command, .shift])

                Button(L10n.tr("Поиск по истории экрана (Recall)", "Recall Screen Memory", lang: appState.lang)) {
                    appState.triggerRecallSearch()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])

                Button(L10n.tr("Создать MCP-инструмент", "Create MCP Tool", lang: appState.lang)) {
                    appState.triggerVisualMCPCapture()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                
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
                        Button {
                            appState.frameStyle = style
                        } label: {
                            if appState.frameStyle == style {
                                Label(style.displayName, systemImage: "checkmark")
                            } else {
                                Text(style.displayName)
                            }
                        }
                    }
                    
                    Divider()
                    
                    Toggle(L10n.tr("Показывать рамку устройства", "Show Device Bezel", lang: appState.lang), isOn: $appState.showDeviceBezel)
                    Toggle(L10n.tr("Показывать вырез камеры", "Show Camera Punch-hole", lang: appState.lang), isOn: $appState.showFrontCamera)
                    Toggle(L10n.tr("Цвет корпуса под устройство", "Match Device Color", lang: appState.lang), isOn: $appState.matchDeviceColor)
                    Toggle(L10n.tr("Адаптивная подсветка Ambilight", "Adaptive Ambilight Glow", lang: appState.lang), isOn: $appState.enableAmbilight)
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
            MenuBarView(appState: appState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(appState: appState)
        }

        Window("MCP Tool Hub", id: "tool-hub") {
            ToolHubView(appState: appState)
        }
        .defaultSize(width: 620, height: 480)
    }
}

private struct SettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        let lang = appState.lang
        TabView {
            generalTab(lang: lang)
                .tabItem {
                    Label(L10n.tr("Основные", "General", lang: lang), systemImage: "gearshape")
                }

            appearanceTab(lang: lang)
                .tabItem {
                    Label(L10n.tr("Оформление", "Appearance", lang: lang), systemImage: "paintbrush")
                }
        }
        .frame(width: 490, height: 560)
    }

    private func generalTab(lang: AppLanguage) -> some View {
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
                Toggle(L10n.tr("Фоновый Continuity Bridge (текст и фото)", "Background Continuity Bridge (Text & Images)", lang: lang), isOn: $appState.continuityBridgeEnabled)
                    .onChange(of: appState.continuityBridgeEnabled) { _, _ in
                        appState.syncContinuityBridgeState()
                    }
                Toggle(L10n.tr("Скрыть иконку из Dock", "Hide Dock Icon", lang: lang), isOn: $appState.hideDockIcon)
                    .onChange(of: appState.hideDockIcon) { _, _ in
                        appState.applyDockVisibility()
                    }
            }

            Section(L10n.tr("MCP и макро-автоматизация", "MCP & Macro Automation", lang: lang)) {
                Toggle(
                    L10n.tr(
                        "Self-Healing через Vision OCR при смене UI ID",
                        "Self-Healing Vision OCR Fallback when UI ID changes",
                        lang: lang
                    ),
                    isOn: $appState.mcpSelfHealingEnabled
                )

                Stepper(
                    value: $appState.macroDefaultStepDelayMs,
                    in: MCPExecutionDefaults.minStepDelayMs...MCPExecutionDefaults.maxStepDelayMs,
                    step: 50
                ) {
                    HStack {
                        Text(L10n.tr("Пауза между шагами макроса", "Default Macro Step Wait", lang: lang))
                        Spacer()
                        Text("\(appState.macroDefaultStepDelayMs) ms")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }

                Stepper(
                    value: $appState.macroMaxSteps,
                    in: MCPExecutionDefaults.minMaxSteps...MCPExecutionDefaults.maxMaxSteps,
                    step: 1
                ) {
                    HStack {
                        Text(L10n.tr("Макс. шагов в макросе", "Max Steps per Macro", lang: lang))
                        Spacer()
                        Text("\(appState.macroMaxSteps)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }

                Stepper(
                    value: $appState.macroMaxTotalWaitSeconds,
                    in: MCPExecutionDefaults.minMaxDurationSeconds...MCPExecutionDefaults.maxMaxDurationSeconds,
                    step: 1
                ) {
                    HStack {
                        Text(L10n.tr("Лимит времени макроса", "Macro Duration Cap", lang: lang))
                        Spacer()
                        Text("\(appState.macroMaxTotalWaitSeconds) s")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }

            if let device = appState.selectedDevice {
                let currentProfile = appState.profile(for: device.id)
                Section(L10n.tr("Профиль устройства: \(device.displayName)", "Device Profile: \(device.displayName)", lang: lang)) {
                    Picker(L10n.tr("Макс. FPS", "Max FPS", lang: lang), selection: Binding(
                        get: { currentProfile.maxFps },
                        set: { newFps in
                            var updated = currentProfile
                            updated.maxFps = newFps
                            appState.updateProfile(updated, for: device.id)
                        }
                    )) {
                        Text("30 FPS").tag(30)
                        Text("60 FPS").tag(60)
                        Text("90 FPS").tag(90)
                        Text("120 FPS").tag(120)
                    }

                    Picker(L10n.tr("Битрейт", "Bitrate", lang: lang), selection: Binding(
                        get: { currentProfile.bitRate },
                        set: { newBitrate in
                            var updated = currentProfile
                            updated.bitRate = newBitrate
                            appState.updateProfile(updated, for: device.id)
                        }
                    )) {
                        Text("4 Mbps").tag(4_000_000)
                        Text("8 Mbps").tag(8_000_000)
                        Text("16 Mbps").tag(16_000_000)
                    }

                    Picker(L10n.tr("Разрешение", "Resolution", lang: lang), selection: Binding(
                        get: { currentProfile.maxSize },
                        set: { newSize in
                            var updated = currentProfile
                            updated.maxSize = newSize
                            appState.updateProfile(updated, for: device.id)
                        }
                    )) {
                        Text("1080p").tag(1080)
                        Text("1440p").tag(1440)
                        Text("Native").tag(0)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func appearanceTab(lang: AppLanguage) -> some View {
        let activeSpec = appState.effectiveHardwareSpec
        return Form {
            Section(L10n.tr("Рамка и оптика устройства", "Device Frame & Optics", lang: lang)) {
                Toggle(L10n.tr("Показывать рамку устройства", "Show Device Bezel", lang: lang), isOn: $appState.showDeviceBezel)
                Toggle(L10n.tr("Показывать вырез фронтальной камеры", "Show Camera Punch-hole", lang: lang), isOn: $appState.showFrontCamera)
                Toggle(L10n.tr("Подбирать цвет корпуса под устройство", "Match Device Color", lang: lang), isOn: $appState.matchDeviceColor)
                Toggle(L10n.tr("Адаптивная подсветка Ambilight", "Adaptive Ambilight Glow", lang: lang), isOn: $appState.enableAmbilight)
            }

            Section(L10n.tr("Масштаб и модель корпуса", "Window Preset & Hardware Profile", lang: lang)) {
                Picker(L10n.tr("Размер окна", "Window Size Preset", lang: lang), selection: $appState.windowScale) {
                    ForEach(PhoneWindowScale.allCases) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }

                Picker(L10n.tr("Модель смартфона", "Device Frame Model", lang: lang), selection: $appState.frameStyle) {
                    ForEach(PhoneFrameStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }

                LabeledContent(L10n.tr("Активный профиль", "Active Profile", lang: lang)) {
                    Text("\(activeSpec.displayName) • R\(Int(activeSpec.baseCornerRadius))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
