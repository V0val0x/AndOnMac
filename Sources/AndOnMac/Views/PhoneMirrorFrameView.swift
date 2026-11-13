import SwiftUI
import AppKit

public struct PhoneMirrorFrameView: View {
    @ObservedObject var appState: AppState
    @State private var isHoveringTop: Bool = false
    @State private var isHoveringHome: Bool = false
    @State private var dragOffset: CGFloat = 0
    @State private var pulseAnimation: Bool = false
    
    public init(appState: AppState) {
        self.appState = appState
    }
    
    private var baseWidth: CGFloat {
        let mult = appState.effectiveFrameStyle.baseWidthMultiplier
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
    
    private var cornerRadius: CGFloat {
        appState.effectiveFrameStyle.cornerRadius
    }
    
    private var innerCornerRadius: CGFloat {
        appState.effectiveFrameStyle.innerCornerRadius
    }
    
    private var screenClipRadius: CGFloat {
        appState.effectiveFrameStyle.screenClipRadius
    }
    
    private var bezelWidth: CGFloat {
        appState.effectiveFrameStyle.bezelWidth
    }
    
    public var body: some View {
        ZStack {
            // Outer Titanium / Aluminum / Glass Phone Chassis tailored per smartphone brand
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(appState.effectiveFrameStyle.chassisFill)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(
                            appState.effectiveFrameStyle.chassisStroke,
                            lineWidth: appState.effectiveFrameStyle == .samsungUltra ? 2.0 : 1.5
                        )
                )
                .overlay(
                    // Subtle glowing Glyph outline for Nothing Phone
                    Group {
                        if appState.effectiveFrameStyle == .nothing {
                            RoundedRectangle(cornerRadius: max(4, cornerRadius - 1), style: .continuous)
                                .stroke(Color.white.opacity(0.35), lineWidth: 1.0)
                                .padding(1.5)
                        }
                    }
                )
                .shadow(color: Color.black.opacity(0.48), radius: 26, x: 0, y: 12)
            
            // Inner Screen Border & Display
            RoundedRectangle(cornerRadius: innerCornerRadius, style: .continuous)
                .fill(Color.black)
                .padding(bezelWidth)
                .overlay(
                    Group {
                        if appState.isMirroring {
                            // Live Embedded Screen
                            liveScreenView
                        } else if appState.showPairingSheet {
                            // In-Phone Pairing & Wireless Setup
                            WirelessPairingView(appState: appState)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .move(edge: .bottom).combined(with: .opacity)
                                ))
                        } else {
                            // Standby / Onboarding Screen
                            standbyScreenView
                                .transition(.opacity)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: screenClipRadius, style: .continuous))
                )
        }
        .frame(width: baseWidth, height: baseHeight)
    }
    
    // MARK: - Front Camera Punch Hole View
    private var frontCameraView: some View {
        let style = appState.effectiveFrameStyle
        let diameter = style.punchHoleDiameter
        return ZStack {
            // Dark outer bezel
            Circle()
                .fill(Color.black)
                .frame(width: diameter + 1.2, height: diameter + 1.2)
            
            // Optical glass lens gradient
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.08, green: 0.12, blue: 0.22),
                            Color(red: 0.02, green: 0.03, blue: 0.05)
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: diameter / 2
                    )
                )
                .frame(width: diameter, height: diameter)
            
            // Tiny glass reflection dot
            Circle()
                .fill(Color.white.opacity(0.65))
                .frame(width: 1.5, height: 1.5)
                .offset(x: -diameter * 0.22, y: -diameter * 0.22)
        }
        .padding(.top, style.punchHoleTopPadding)
        .allowsHitTesting(false)
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
                    withAnimation(.easeInOut(duration: 0.15)) {
                        self.isHoveringTop = isTop
                        self.isHoveringHome = isBottom
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: screenClipRadius, style: .continuous))
            
            // Front Camera Punch Hole Cutout
            if appState.showFrontCamera && appState.effectiveFrameStyle.hasPunchHole && !appState.isLandscape {
                VStack {
                    frontCameraView
                    Spacer()
                }
            }
            
            // Sequoia Top Hover HUD & Home Bar (Fades in smoothly only when hovering near top/bottom)
            VStack {
                topHoverHUDView
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .opacity(isHoveringTop ? 1.0 : 0.0)
                    .allowsHitTesting(isHoveringTop)
                    .animation(.easeInOut(duration: 0.15), value: isHoveringTop)
                
                Spacer()
                
                bottomHomeBarView
                    .padding(.bottom, 6)
                    .opacity(isHoveringHome ? 1.0 : 0.0)
                    .allowsHitTesting(isHoveringHome)
                    .animation(.easeInOut(duration: 0.15), value: isHoveringHome)
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
                            .opacity(isHoveringTop ? 1 : 0)
                    )
            }
            .buttonStyle(.plain)
            .help("Завершить трансляцию (Cmd+W)")
            
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
                    .help("Недавние приложения (Cmd+2)")
                    
                    Button {
                        appState.triggerHome()
                    } label: {
                        Image(systemName: "circle")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    .help("Домой (Cmd+1)")
                    
                    Button {
                        appState.triggerNotifications()
                    } label: {
                        Image(systemName: "bell")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    .help("Уведомления (Cmd+3)")
                    
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            appState.showPhotoDrawer.toggle()
                        }
                    } label: {
                        Image(systemName: "photo.stack")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(appState.showPhotoDrawer ? .cyan : .white)
                    }
                    .buttonStyle(.plain)
                    .help("Медиатека и перенос фото (Cmd+4)")
                    
                    Button {
                        appState.triggerPower()
                    } label: {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    .help("Блокировка / Экран (Cmd+P)")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial)
                .cornerRadius(14)
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
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.4))
            .cornerRadius(8)
        }
        .frame(height: 28)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHoveringTop = hovering
            }
        }
    }
    
    // MARK: - Standby Screen View (When not mirroring)
    private var standbyScreenView: some View {
        VStack(spacing: 0) {
            // Front camera punch hole on standby
            if appState.showFrontCamera && appState.effectiveFrameStyle.hasPunchHole && !appState.isLandscape {
                frontCameraView
                    .padding(.top, 2)
            }
            
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
                .help("Закрыть окно")
                
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
            .padding(.horizontal, 20)
            .padding(.top, 8)
            
            Spacer()
            
            if let unauth = appState.devices.first(where: { $0.state == .unauthorized }) {
                // Unauthorized state
                VStack(spacing: 16) {
                    ZStack {
                        Circle().fill(Color.orange.opacity(0.2)).frame(width: 80, height: 80)
                        Image(systemName: "hand.tap.fill").font(.system(size: 36)).foregroundColor(.orange)
                    }
                    Text("Подтвердите на телефоне")
                        .font(.headline.bold())
                        .foregroundColor(.white)
                    Text("Разблокируйте **\(unauth.displayName)** и нажмите **«Разрешить»**.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.horizontal, 24)
                    ProgressView()
                        .controlSize(.small)
                }
            } else if let device = appState.selectedDevice {
                // Device ready
                VStack(spacing: 20) {
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
                        Text(device.connectionType == .wifi ? "Беспроводное соединение (Wi-Fi)" : "Подключен по Type-C")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.6))
                    }
                    
                    Button {
                        appState.toggleMirroring()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill")
                            Text("Открыть экран")
                        }
                        .font(.headline)
                        .frame(minWidth: 170)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            appState.showPhotoDrawer.toggle()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "photo.stack")
                            Text("Медиатека фото")
                        }
                        .font(.caption.bold())
                    }
                    .buttonStyle(.bordered)
                    .tint(.white.opacity(0.8))
                }
            } else {
                // No device onboarding
                VStack(spacing: 20) {
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
                        Text("Подключите телефон")
                            .font(.title3.bold())
                            .foregroundColor(.white)
                        Text("Подключите кабель Type-C или используйте беспроводное сопряжение по Wi-Fi.")
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.horizontal, 20)
                    }
                    
                    Button {
                        appState.showPairingSheet = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "wifi")
                            Text("Wi-Fi сопряжение")
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
            
            // Frame style switcher button
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
                .foregroundColor(.white.opacity(0.65))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.08))
                .cornerRadius(12)
            }
            .menuStyle(.borderlessButton)
            .padding(.bottom, 4)
            
            bottomHomeBarView
                .padding(.bottom, 8)
        }
        .padding(10)
    }
    
    // MARK: - Bottom Home Bar (Interactive)
    private var bottomHomeBarView: some View {
        VStack {
            Capsule()
                .fill(Color.white.opacity(isHoveringHome ? 0.95 : 0.6))
                .frame(width: 130, height: 5)
                .shadow(color: .black.opacity(0.5), radius: 2)
                .offset(y: dragOffset)
                .gesture(
                    DragGesture(minimumDistance: 5)
                        .onChanged { value in
                            if value.translation.height < 0 {
                                dragOffset = max(value.translation.height, -70)
                            }
                        }
                        .onEnded { value in
                            withAnimation(.spring()) {
                                if value.translation.height < -55 {
                                    // High drag -> App Switcher (Recents)
                                    appState.triggerAppSwitch()
                                } else if value.translation.height < -20 {
                                    // Short drag -> Home
                                    appState.triggerHome()
                                }
                                dragOffset = 0
                            }
                        }
                )
                .onTapGesture {
                    appState.triggerHome()
                }
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isHoveringHome = hovering
                    }
                }
        }
        .frame(height: 18)
    }
}
