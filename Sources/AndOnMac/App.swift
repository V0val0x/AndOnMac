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
            MenuBarPopoverView(appState: appState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(appState: appState)
        }
    }
}

private struct MenuBarPopoverView: View {
    @ObservedObject var appState: AppState
    @State private var isHoveringLanguage: Bool = false

    var body: some View {
        let lang = appState.lang
        VStack(alignment: .leading, spacing: 10) {
            if let device = appState.selectedDevice {
                HStack(spacing: 10) {
                    ZStack(alignment: .bottomTrailing) {
                        Image(systemName: device.isPixel ? "g.circle.fill" : "smartphone")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 32, height: 32)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                        Circle()
                            .fill(appState.isMirroring ? Color.green : Color.blue)
                            .frame(width: 8, height: 8)
                            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                            .offset(x: 2, y: 2)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.displayName)
                            .font(.system(size: 13, weight: .semibold))
                        Text("\(device.connectionType.rawValue)\(device.batteryLevel.map { " • \($0)%" } ?? "") • \(appState.effectiveHardwareSpec.displayName)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                Button {
                    appState.toggleMirroring()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: appState.isMirroring ? "stop.circle.fill" : "play.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                        Text(
                            appState.isMirroring
                                ? L10n.tr("Остановить экран", "Stop Mirroring", lang: lang)
                                : L10n.tr("Открыть экран", "Open Screen", lang: lang)
                        )
                        .font(.system(size: 12.5, weight: .semibold))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .opacity(0.75)
                    }
                }
                .buttonStyle(MenuBarPrimaryButtonStyle(isActive: appState.isMirroring))
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "iphone.slash")
                        .foregroundStyle(.secondary)
                    Text(L10n.tr("Нет подключенных устройств", "No connected devices", lang: lang))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            Divider()
                .opacity(0.5)

            VStack(alignment: .leading, spacing: 4) {
                Button {
                    appState.refreshDevices()
                } label: {
                    MenuBarRowContent(
                        icon: "arrow.clockwise",
                        tint: .blue,
                        title: L10n.tr("Поиск устройств", "Scan Devices", lang: lang)
                    )
                }
                .buttonStyle(MenuBarActionButtonStyle())

                Button {
                    if appState.isMirroring {
                        appState.toggleMirroring()
                    }
                    appState.showPairingSheet = true
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    MenuBarRowContent(
                        icon: "wifi",
                        tint: .cyan,
                        title: L10n.tr("Подключить по Wi-Fi...", "Connect via Wi-Fi...", lang: lang),
                        showsChevron: true
                    )
                }
                .buttonStyle(MenuBarActionButtonStyle())

                Button {
                    Task {
                        await appState.resetUSBAndADB()
                    }
                } label: {
                    MenuBarRowContent(
                        icon: "cable.connector",
                        tint: .orange,
                        title: L10n.tr("Сбросить ADB и восстановить USB", "Restart ADB & Reset USB", lang: lang)
                    )
                }
                .buttonStyle(MenuBarActionButtonStyle())

                SettingsLink {
                    MenuBarRowContent(
                        icon: "slider.horizontal.3",
                        tint: .purple,
                        title: L10n.tr("Настройки и внешний вид...", "Settings & Appearance...", lang: lang),
                        shortcut: "⌘,",
                        showsChevron: true
                    )
                }
                .buttonStyle(MenuBarActionButtonStyle())
            }

            Divider()
                .opacity(0.5)

            HStack {
                Menu {
                    ForEach(AppLanguage.allCases) { language in
                        Button {
                            appState.appLanguage = language
                        } label: {
                            if appState.appLanguage == language {
                                Label(language.displayName(in: lang), systemImage: "checkmark")
                            } else {
                                Text(language.displayName(in: lang))
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "globe")
                        Text(lang == .russian ? "Русский" : "English")
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(isHoveringLanguage ? 0.12 : 0.06))
                    )
                }
                .menuStyle(.borderlessButton)
                .onHover { isHoveringLanguage = $0 }

                Spacer()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    HStack(spacing: 4) {
                        Text(L10n.tr("Выход", "Quit", lang: lang))
                        Text("⌘Q")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(MenuBarFooterButtonStyle())
            }
        }
        .padding(12)
        .frame(width: 280)
        .background(VibrancyBackdrop(material: .popover, blendingMode: .behindWindow))
    }
}

private struct MenuBarRowContent: View {
    let icon: String
    let tint: Color
    let title: String
    var shortcut: String? = nil
    var showsChevron: Bool = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)

            Spacer(minLength: 6)

            if let shortcut {
                Text(shortcut)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct MenuBarActionButtonStyle: ButtonStyle {
    @State private var isHovered: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        configuration.isPressed
                            ? Color.accentColor.opacity(0.24)
                            : (isHovered ? Color.primary.opacity(0.10) : Color.primary.opacity(0.03))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(isHovered ? 0.14 : 0.05), lineWidth: 0.6)
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .onHover { isHovered = $0 }
    }
}

private struct MenuBarPrimaryButtonStyle: ButtonStyle {
    let isActive: Bool
    @State private var isHovered: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        let baseColor = isActive ? Color.red : Color.accentColor
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(baseColor.opacity(configuration.isPressed ? 0.72 : (isHovered ? 0.96 : 0.86)))
            )
            .shadow(color: baseColor.opacity(isHovered ? 0.28 : 0.14), radius: 6, y: 2)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .onHover { isHovered = $0 }
    }
}

private struct MenuBarFooterButtonStyle: ButtonStyle {
    @State private var isHovered: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed ? Color.red.opacity(0.20) : (isHovered ? Color.primary.opacity(0.11) : Color.primary.opacity(0.05)))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onHover { isHovered = $0 }
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
        .frame(width: 470, height: 390)
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
