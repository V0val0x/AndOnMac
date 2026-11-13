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
    
    private var baseWidth: CGFloat { 360 * appState.windowScale.multiplier }
    private var baseHeight: CGFloat {
        let aspect = CGFloat(ScrcpyClient.shared.deviceHeight) / CGFloat(max(1, ScrcpyClient.shared.deviceWidth))
        let effectiveAspect = (aspect >= 1.3 && aspect <= 2.4) ? aspect : (20.0 / 9.0)
        return (360.0 * effectiveAspect) * appState.windowScale.multiplier
    }
    
    public var body: some View {
        ZStack {
            // Outer Titanium / Aluminum Phone Chassis (1-in-1 with Sequoia iPhone Mirroring)
            RoundedRectangle(cornerRadius: 52, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(nsColor: .darkGray).opacity(0.6),
                            Color(nsColor: .black).opacity(0.9)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 52, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.35),
                                    Color.white.opacity(0.08),
                                    Color.black.opacity(0.7)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 3
                        )
                )
                .shadow(color: Color.black.opacity(0.55), radius: 35, x: 0, y: 18)
            
            // Inner Screen Border & Display
            RoundedRectangle(cornerRadius: 44, style: .continuous)
                .fill(Color.black)
                .padding(6)
                .overlay(
                    Group {
                        if appState.isMirroring {
                            // Live Embedded Screen
                            liveScreenView
                        } else {
                            // Standby / Onboarding Screen
                            standbyScreenView
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 42, style: .continuous))
                    .padding(6)
                )
        }
        .frame(width: baseWidth, height: baseHeight)
    }
    
    // MARK: - Live Embedded Screen with ScrcpyVideoView
    private var liveScreenView: some View {
        ZStack {
            // Live Video Stream decoded via VideoToolbox
            ScrcpyVideoView(serial: appState.selectedDevice?.id) { urls in
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
            }
            .clipShape(RoundedRectangle(cornerRadius: 42, style: .continuous))
            
            // Camera Punch Hole / Dynamic Island
            VStack {
                HStack {
                    Spacer()
                    Circle()
                        .fill(Color.black)
                        .frame(width: 12, height: 12)
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        )
                    Spacer()
                }
                .padding(.top, 10)
                Spacer()
            }
            .allowsHitTesting(false)
            
            // Sequoia Top Hover HUD & Home Bar
            VStack {
                topHoverHUDView
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                
                Spacer()
                
                bottomHomeBarView
                    .padding(.bottom, 8)
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
            
            // Status: Battery / Wifi
            HStack(spacing: 4) {
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
                Circle()
                    .fill(Color.black)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
                Spacer()
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
            .padding(.top, 12)
            
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
                                dragOffset = max(value.translation.height, -50)
                            }
                        }
                        .onEnded { value in
                            withAnimation(.spring()) {
                                if value.translation.height < -30 {
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
