import SwiftUI
import AppKit

public struct PhoneMirrorFrameView: View {
    @ObservedObject var appState: AppState
    @State private var isHoveringTop: Bool = false
    @State private var isHoveringTopBar: Bool = false
    @State private var isHoveringHome: Bool = false
    @State private var isHoveringHomePill: Bool = false
    @State private var isDraggingHomeBar: Bool = false
    @State private var dragOffset: CGFloat = 0
    @State private var pulseAnimation: Bool = false

    private var showTopHUD: Bool { isHoveringTop || isHoveringTopBar }
    private var showHomeBar: Bool { isHoveringHome || isHoveringHomePill || isDraggingHomeBar }
    
    public init(appState: AppState) {
        self.appState = appState
    }
    
    private var spec: DeviceHardwareSpec {
        appState.effectiveHardwareSpec
    }

    private var baseWidth: CGFloat {
        let mult = spec.baseWidthMultiplier
        if appState.isLandscape {
            let h = 320.0 * appState.windowScale.multiplier
            return h * appState.effectiveAspect * mult
        } else {
            return 320.0 * appState.windowScale.multiplier * mult
        }
    }
    
    private var baseHeight: CGFloat {
        if appState.isLandscape {
            return 320.0 * appState.windowScale.multiplier
        } else {
            return (320.0 * appState.effectiveAspect) * appState.windowScale.multiplier
        }
    }
    
    public var body: some View {
        DeviceFrameRenderer(
            spec: spec,
            device: appState.selectedDevice,
            width: baseWidth,
            height: baseHeight,
            scaleMultiplier: appState.windowScale.multiplier,
            orientation: appState.displayOrientation,
            showDeviceBezel: appState.showDeviceBezel,
            showCameraPunchHole: appState.showFrontCamera,
            matchDeviceColor: appState.matchDeviceColor,
            enableAmbilight: appState.enableAmbilight && appState.isMirroring
        ) {
            Group {
                if appState.isMirroring {
                    liveScreenView
                } else if appState.showPairingSheet {
                    WirelessPairingView(appState: appState)
                } else {
                    standbyScreenView
                }
            }
        }
    }
    
    // MARK: - Live Embedded Screen with ScrcpyVideoView
    private var liveScreenView: some View {
        ZStack {
            // Live Video Stream decoded via VideoToolbox
            ScrcpyVideoView(
                serial: appState.selectedDevice?.id,
                onFileDrop: { urls in
                    Task {
                        if let serial = appState.selectedDevice?.id {
                            let res = await PhotoTransferService.shared.pushFiles(urls: urls, serial: serial)
                            await MainActor.run {
                                appState.photoTransferNotice = res.message
                                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                                    appState.photoTransferNotice = nil
                                }
                            }
                        }
                    }
                },
                onHoverZonesChanged: { isTop, isBottom in
                    if self.isHoveringTop != isTop || self.isHoveringHome != isBottom {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            self.isHoveringTop = isTop
                            self.isHoveringHome = isBottom
                        }
                    }
                }
            )
            
            // Sequoia Top Hover HUD & Home Bar (Fades in smoothly only when hovering near top/bottom)
            VStack {
                topHoverHUDView
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .onHover { hovering in
                        isHoveringTopBar = hovering
                    }
                    .opacity(showTopHUD ? 1.0 : 0.0)
                    .allowsHitTesting(showTopHUD)
                    .animation(.easeInOut(duration: 0.15), value: showTopHUD)
                
                Spacer()
                
                bottomHomeBarView(interactive: true)
                    .padding(.bottom, 6)
                    .opacity(showHomeBar ? 1.0 : 0.0)
                    .allowsHitTesting(showHomeBar)
                    .animation(.easeInOut(duration: 0.15), value: showHomeBar)
            }
            
            // Photo Transfer Toast Alert
            if let notice = appState.photoTransferNotice {
                VStack {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(notice)
                            .font(.caption.bold())
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .cornerRadius(20)
                    .shadow(radius: 8)
                    .padding(.top, 44)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    
                    Spacer()
                }
            }
            
            // Phone Screen Off / Locked Overlay (1-in-1 with macOS Sequoia iPhone Mirroring)
            if appState.isPhoneScreenOff || appState.isPhoneLocked {
                phoneLockedOrScreenOffOverlay
                    .transition(.opacity)
            }
        }
    }
    
    private var phoneLockedOrScreenOffOverlay: some View {
        ZStack {
            VibrancyBackdrop(material: .hudWindow, blendingMode: .withinWindow)
                .overlay(Color.black.opacity(0.28))
                .makeWindowDraggable()
            
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 64, height: 64)
                    Image(systemName: appState.isPhoneLocked ? "lock.fill" : "moon.zzz.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(.white)
                }
                
                VStack(spacing: 4) {
                    Text(appState.isPhoneLocked
                         ? L10n.tr("Телефон заблокирован", "Phone is locked", lang: appState.lang)
                         : L10n.tr("Экран телефона выключен", "Phone screen is off", lang: appState.lang))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                    Text(L10n.tr("Нажмите кнопку ниже, чтобы разбудить и разблокировать экран устройства.", "Click the button below to wake and unlock your device.", lang: appState.lang))
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                
                Button {
                    appState.triggerUnlock()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        appState.refreshDevices()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.open.fill")
                        Text(L10n.tr("Разбудить и разблокировать", "Wake & Unlock", lang: appState.lang))
                            .font(.system(size: 12, weight: .bold))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(16)
                }
                .buttonStyle(.plain)
            }
            .padding(20)
        }
    }
    
    // MARK: - Top Hover HUD (macOS Sequoia style)
    private var topHoverHUDView: some View {
        HStack(spacing: 8) {
            // Red Close / Stop button
            Button {
                appState.toggleMirroring()
            } label: {
                Circle()
                    .fill(Color.red.opacity(0.85))
                    .frame(width: 12, height: 12)
                    .overlay(
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .black))
                            .foregroundColor(.black.opacity(0.7))
                            .opacity(showTopHUD ? 1 : 0)
                    )
            }
            .buttonStyle(.plain)
            .help(L10n.tr("Завершить трансляцию (Cmd+W)", "Stop mirroring (Cmd+W)", lang: appState.lang))
            
            Spacer()
            
            // Glass action capsule
            if isHoveringTop {
                HStack(spacing: 12) {
                    Button {
                        appState.triggerAppSwitch()
                    } label: {
                        Image(systemName: "square.on.square")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.tr("Недавние приложения (Cmd+2)", "Recent Apps (Cmd+2)", lang: appState.lang))
                    
                    Button {
                        appState.triggerHome()
                    } label: {
                        Image(systemName: "circle")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.tr("Домой (Cmd+1)", "Home (Cmd+1)", lang: appState.lang))
                    
                    Button {
                        appState.triggerNotifications()
                    } label: {
                        Image(systemName: "bell")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.tr("Уведомления (Cmd+3)", "Notifications (Cmd+3)", lang: appState.lang))
                    
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            appState.openDrawer(mode: .gallery)
                        }
                    } label: {
                        Image(systemName: "photo.stack")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(appState.showPhotoDrawer && appState.drawerMode == .gallery ? .cyan : .white)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.tr("Медиатека и перенос фото (Cmd+4)", "Gallery & Photo Transfer (Cmd+4)", lang: appState.lang))

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            appState.openDrawer(mode: .files)
                        }
                    } label: {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(appState.showPhotoDrawer && appState.drawerMode == .files ? .cyan : .white)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.tr("Файловый менеджер (Cmd+5)", "File Manager (Cmd+5)", lang: appState.lang))
                    
                    Button {
                        appState.triggerPower()
                    } label: {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.tr("Блокировка / Экран (Cmd+P)", "Lock / Screen (Cmd+P)", lang: appState.lang))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.6))
                .shadow(color: Color.black.opacity(0.28), radius: 8, y: 3)
                .transition(.scale.combined(with: .opacity))
            }
            
            Spacer()
            
            // Status: Language / Battery / Wifi
            HStack(spacing: 5) {
                if !appState.currentLanguageBadge.isEmpty {
                    Text(appState.currentLanguageBadge)
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .foregroundColor(.cyan)
                        .padding(.trailing, 2)
                }
                
                if let battery = appState.selectedDevice?.batteryLevel {
                    Text("\(battery)%")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.85))
                    Image(systemName: appState.selectedDevice?.isCharging == true ? "battery.100.bolt" : "battery.100")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.85))
                } else {
                    Image(systemName: "wifi")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3.5)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 0.6))
            .allowsHitTesting(false)
        }
        .frame(height: 28)
    }
    
    // MARK: - Standby Screen View (When not mirroring)
    private var standbyScreenView: some View {
        ZStack {
            VibrancyBackdrop(material: .underWindowBackground, blendingMode: .behindWindow)
                .overlay(
                    LinearGradient(
                        colors: [Color.black.opacity(0.58), Color.black.opacity(0.46)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .contentShape(Rectangle())
                .makeWindowDraggable()
            
            VStack(spacing: 0) {
                // Top Bar with standard macOS close traffic light
                HStack {
                    Button {
                        NSApp.keyWindow?.performClose(nil)
                    } label: {
                        Circle()
                            .fill(Color.red.opacity(0.85))
                            .frame(width: 12, height: 12)
                            .overlay(
                                Image(systemName: "xmark")
                                    .font(.system(size: 7, weight: .black))
                                    .foregroundColor(.black.opacity(0.7))
                            )
                    }
                    .buttonStyle(.plain)
                    .help(L10n.tr("Закрыть окно", "Close Window", lang: appState.lang))
                    
                    HStack {
                        Text("AndOnMac")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white.opacity(0.6))
                            .padding(.leading, 4)
                        Spacer()
                        if !appState.currentLanguageBadge.isEmpty {
                            Text(appState.currentLanguageBadge)
                                .font(.system(size: 9, weight: .black, design: .rounded))
                                .foregroundColor(.cyan)
                                .padding(.trailing, 2)
                        }
                        if let battery = appState.selectedDevice?.batteryLevel {
                            Text("\(battery)%")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white.opacity(0.8))
                        } else {
                            Image(systemName: "wifi")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.6))
                        }
                    }
                    .contentShape(Rectangle())
                    .makeWindowDraggable()
                }
                .padding(.horizontal, 20)
                .padding(.top, appState.isLandscape ? 10 : 18)
                
                Spacer()
                
                if let unauth = appState.devices.first(where: { $0.state == .unauthorized }) {
                    // Unauthorized state
                    VStack(spacing: 16) {
                        ZStack {
                            Circle().fill(Color.orange.opacity(0.2)).frame(width: 80, height: 80)
                            Image(systemName: "hand.tap.fill").font(.system(size: 36)).foregroundColor(.orange)
                        }
                        Text(L10n.tr("Подтвердите на телефоне", "Confirm on your phone", lang: appState.lang))
                            .font(.headline.bold())
                            .foregroundColor(.white)
                        Text(L10n.tr("Разблокируйте \(unauth.displayName) и нажмите «Разрешить».", "Unlock \(unauth.displayName) and tap Allow.", lang: appState.lang))
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .foregroundColor(.white.opacity(0.8))
                            .padding(.horizontal, 24)
                        ProgressView()
                            .controlSize(.small)
                    }
                    .contentShape(Rectangle())
                    .makeWindowDraggable()
                } else if let device = appState.selectedDevice {
                    // Device ready
                    VStack(spacing: 20) {
                        VStack(spacing: 16) {
                            VStack(spacing: 4) {
                                Text(Date(), style: .time)
                                    .font(.system(size: 48, weight: .semibold, design: .rounded))
                                    .foregroundColor(.white)
                                Text(Date(), style: .date)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white.opacity(0.7))
                            }
                            
                            ZStack {
                                Circle().fill(Color.white.opacity(0.12)).frame(width: 84, height: 84)
                                Image(systemName: device.isPixel ? "g.circle.fill" : "smartphone")
                                    .font(.system(size: 42))
                                    .foregroundColor(.white)
                            }
                            
                            VStack(spacing: 4) {
                                Text(device.displayName)
                                    .font(.headline)
                                    .foregroundColor(.white)
                                Text(device.connectionType == .wifi
                                     ? L10n.tr("Беспроводное соединение (Wi-Fi)", "Wireless connection (Wi-Fi)", lang: appState.lang)
                                     : L10n.tr("Подключен по Type-C", "Connected via USB-C", lang: appState.lang))
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.6))
                                if appState.isPhoneScreenOff || appState.isPhoneLocked {
                                    HStack(spacing: 5) {
                                        Image(systemName: appState.isPhoneLocked ? "lock.fill" : "moon.zzz.fill")
                                            .font(.system(size: 10))
                                        Text(appState.isPhoneLocked
                                             ? L10n.tr("Телефон заблокирован", "Phone locked", lang: appState.lang)
                                             : L10n.tr("Экран выключен", "Screen off", lang: appState.lang))
                                            .font(.system(size: 10, weight: .semibold))
                                    }
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Color.orange.opacity(0.15))
                                    .cornerRadius(10)
                                    .padding(.top, 2)
                                }
                            }
                        }
                        .contentShape(Rectangle())
                        .makeWindowDraggable()
                        
                        Button {
                            appState.toggleMirroring()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "play.fill")
                                Text(L10n.tr("Открыть экран", "Open Screen", lang: appState.lang))
                            }
                            .font(.headline)
                            .frame(minWidth: 170)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        
                        HStack(spacing: 8) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    appState.openDrawer(mode: .gallery)
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "photo.stack")
                                    Text(L10n.tr("Галерея", "Gallery", lang: appState.lang))
                                }
                                .font(.caption.bold())
                            }
                            .buttonStyle(.bordered)
                            .tint(.white.opacity(0.8))

                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    appState.openDrawer(mode: .files)
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "folder.fill")
                                    Text(L10n.tr("Файлы", "Files", lang: appState.lang))
                                }
                                .font(.caption.bold())
                            }
                            .buttonStyle(.bordered)
                            .tint(.white.opacity(0.8))
                        }

                        HStack(spacing: 8) {
                            if appState.devices.count > 1 {
                                Menu {
                                    ForEach(appState.devices) { candidate in
                                        Button {
                                            appState.selectedDeviceId = candidate.id
                                        } label: {
                                            if candidate.id == device.id {
                                                Label(candidate.displayName, systemImage: "checkmark")
                                            } else {
                                                Text("\(candidate.displayName) (\(candidate.connectionType == .wifi ? "Wi-Fi" : "USB"))")
                                            }
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                        Text(L10n.tr("Сменить", "Switch", lang: appState.lang))
                                    }
                                    .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .tint(.white.opacity(0.65))
                            }

                            Button {
                                appState.showPairingSheet = true
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "iphone.and.arrow.forward")
                                    Text(L10n.tr("Другой телефон", "Another Phone", lang: appState.lang))
                                }
                                .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .tint(.white.opacity(0.65))

                            if device.connectionType == .wifi {
                                Button {
                                    appState.disconnectDevice(device)
                                } label: {
                                    Image(systemName: "wifi.slash")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .tint(.red.opacity(0.75))
                                .help(L10n.tr("Отключить Wi-Fi устройство", "Disconnect Wi-Fi device", lang: appState.lang))
                            }
                        }
                    }
                } else {
                    // No device onboarding
                    VStack(spacing: 20) {
                        VStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .fill(Color.blue.opacity(pulseAnimation ? 0.25 : 0.1))
                                    .frame(width: 90, height: 90)
                                    .scaleEffect(pulseAnimation ? 1.08 : 0.96)
                                    .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: pulseAnimation)
                                Image(systemName: "cable.connector.horizontal")
                                    .font(.system(size: 40))
                                    .foregroundColor(.blue)
                            }
                            .onAppear { pulseAnimation = true }
                            
                            VStack(spacing: 6) {
                                Text(L10n.tr("Подключите телефон", "Connect a Phone", lang: appState.lang))
                                    .font(.title3.bold())
                                    .foregroundColor(.white)
                                Text(L10n.tr("Подключите кабель Type-C или используйте беспроводное сопряжение по Wi-Fi.", "Plug in a USB-C cable or pair wirelessly over Wi-Fi.", lang: appState.lang))
                                    .font(.caption)
                                    .multilineTextAlignment(.center)
                                    .foregroundColor(.white.opacity(0.7))
                                    .padding(.horizontal, 20)
                            }
                        }
                        .contentShape(Rectangle())
                        .makeWindowDraggable()
                        
                        Button {
                            appState.showPairingSheet = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "wifi")
                                Text(L10n.tr("Wi-Fi сопряжение", "Wi-Fi Pairing", lang: appState.lang))
                            }
                            .font(.subheadline.bold())
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(
                                LinearGradient(colors: [Color.blue, Color.cyan], startPoint: .leading, endPoint: .trailing)
                            )
                            .foregroundColor(.white)
                            .cornerRadius(20)
                            .shadow(color: Color.blue.opacity(0.4), radius: 8, x: 0, y: 3)
                        }
                        .buttonStyle(.plain)
                    }
                }
                
                Spacer()
                
                // Frame style & Language switcher row
                HStack(spacing: 8) {
                    Menu {
                        ForEach(PhoneFrameStyle.allCases) { style in
                            Button {
                                appState.frameStyle = style
                            } label: {
                                HStack {
                                    if appState.frameStyle == style {
                                        Image(systemName: "checkmark")
                                    }
                                    Text(style.displayName)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: appState.effectiveFrameStyle.iconName)
                                .font(.system(size: 10))
                            Text(appState.effectiveFrameStyle.displayName)
                                .font(.system(size: 10, weight: .semibold))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8))
                        }
                        .foregroundColor(.white.opacity(0.72))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.6))
                    }
                    .menuStyle(.borderlessButton)

                    Menu {
                        ForEach(AppLanguage.allCases) { language in
                            Button {
                                appState.appLanguage = language
                            } label: {
                                HStack {
                                    if appState.appLanguage == language {
                                        Image(systemName: "checkmark")
                                    }
                                    Text(language.displayName(in: appState.lang))
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "globe")
                                .font(.system(size: 10))
                            Text(appState.lang == .russian ? "RU" : "EN")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundColor(.white.opacity(0.72))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.6))
                    }
                    .menuStyle(.borderlessButton)
                    .help(L10n.tr("Язык интерфейса", "Interface Language", lang: appState.lang))
                }
                .padding(.bottom, 4)
                
                bottomHomeBarView(interactive: false)
                    .padding(.bottom, 8)
                    .allowsHitTesting(false)
            }
            .padding(10)
        }
    }
    
    public enum HomeBarGestureAction: Equatable, Sendable {
        case none
        case home
        case appSwitcher
    }

    public static func classifyHomeBarDrag(translationHeight: CGFloat, holdDuration: TimeInterval = 0) -> HomeBarGestureAction {
        if translationHeight <= -42 || (holdDuration >= 0.20 && translationHeight <= -16) {
            return .appSwitcher
        }
        if translationHeight <= -10 {
            return .home
        }
        return .none
    }

    // MARK: - Bottom Home Bar (Interactive AppKit Control)
    private func bottomHomeBarView(interactive: Bool) -> some View {
        ZStack {
            Capsule()
                .fill(Color.white.opacity(showHomeBar ? 0.95 : 0.6))
                .frame(width: 130, height: 5)
                .shadow(color: .black.opacity(0.5), radius: 2)
                .offset(y: dragOffset)
                .allowsHitTesting(false)

            if interactive {
                HomeBarInteractiveRepresentable(
                    onHoverChanged: { hovering in
                        if isHoveringHomePill != hovering {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isHoveringHomePill = hovering
                            }
                        }
                    },
                    onDragChanged: { offset, dragging in
                        isDraggingHomeBar = dragging
                        if dragging {
                            dragOffset = offset
                        } else {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                dragOffset = offset
                            }
                        }
                    },
                    onAction: { action in
                        switch action {
                        case .appSwitcher:
                            appState.triggerAppSwitch()
                        case .home:
                            appState.triggerHome()
                        case .none:
                            break
                        }
                    }
                )
            }
        }
        .frame(width: 150, height: 24)
    }
}

private struct HomeBarInteractiveRepresentable: NSViewRepresentable {
    let onHoverChanged: (Bool) -> Void
    let onDragChanged: (_ offset: CGFloat, _ isDragging: Bool) -> Void
    let onAction: (PhoneMirrorFrameView.HomeBarGestureAction) -> Void

    func makeNSView(context: Context) -> HomeBarInteractiveNSView {
        let view = HomeBarInteractiveNSView()
        view.onHoverChanged = onHoverChanged
        view.onDragChanged = onDragChanged
        view.onAction = onAction
        return view
    }

    func updateNSView(_ nsView: HomeBarInteractiveNSView, context: Context) {
        nsView.onHoverChanged = onHoverChanged
        nsView.onDragChanged = onDragChanged
        nsView.onAction = onAction
    }
}

public final class HomeBarInteractiveNSView: NSView {
    public var onHoverChanged: ((Bool) -> Void)?
    public var onDragChanged: ((_ offset: CGFloat, _ isDragging: Bool) -> Void)?
    public var onAction: ((PhoneMirrorFrameView.HomeBarGestureAction) -> Void)?

    private var hoverTrackingArea: NSTrackingArea?

    override public var mouseDownCanMoveWindow: Bool { false }
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = hoverTrackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override public func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override public func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override public func mouseDown(with event: NSEvent) {
        let startY = NSEvent.mouseLocation.y
        var latestY = startY
        var maxUpward: CGFloat = 0
        var lastSignificantY = startY
        var lastSignificantMoveTime = event.timestamp
        onDragChanged?(0, true)

        window?.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .greatestFiniteMagnitude, mode: .eventTracking) { trackedEvent, stop in
            switch trackedEvent?.type {
            case .leftMouseDragged:
                latestY = NSEvent.mouseLocation.y
                let dy = latestY - startY
                maxUpward = max(maxUpward, dy)
                if abs(latestY - lastSignificantY) >= 4 {
                    lastSignificantY = latestY
                    lastSignificantMoveTime = trackedEvent?.timestamp ?? lastSignificantMoveTime
                }
                let clampedOffset = min(0, max(-75, -dy))
                self.onDragChanged?(clampedOffset, true)
            case .leftMouseUp:
                latestY = NSEvent.mouseLocation.y
                let dy = latestY - startY
                maxUpward = max(maxUpward, dy)
                let releaseTime = trackedEvent?.timestamp ?? lastSignificantMoveTime
                let holdDuration = max(0, releaseTime - lastSignificantMoveTime)
                let action: PhoneMirrorFrameView.HomeBarGestureAction
                if abs(dy) < 5 && maxUpward < 5 {
                    action = .home
                } else {
                    action = PhoneMirrorFrameView.classifyHomeBarDrag(translationHeight: -dy, holdDuration: holdDuration)
                }
                self.onDragChanged?(0, false)
                self.onAction?(action)
                stop.pointee = true
            default:
                break
            }
        }
    }
}
