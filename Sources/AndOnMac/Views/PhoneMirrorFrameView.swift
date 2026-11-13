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
    
    private var baseWidth: CGFloat { 340 * appState.windowScale.multiplier }
    private var baseHeight: CGFloat { 700 * appState.windowScale.multiplier }
    
    public var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // Outer Titanium / Aluminum Phone Chassis
                RoundedRectangle(cornerRadius: 50, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(nsColor: .controlBackgroundColor),
                                Color(nsColor: .windowBackgroundColor)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 50, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.3),
                                        Color.black.opacity(0.4)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 3
                            )
                    )
                    .shadow(color: Color.black.opacity(0.4), radius: 30, x: 0, y: 15)
                
                // Inner Screen Border & Display
                RoundedRectangle(cornerRadius: 44, style: .continuous)
                    .fill(Color.black)
                    .padding(6)
                    .overlay(
                        VStack(spacing: 0) {
                            // Top Bar & Camera Cutout
                            topHeaderView
                                .padding(.horizontal, 22)
                                .padding(.top, 12)
                            
                            Spacer()
                            
                            // Center Screen Content
                            centerContentView
                            
                            Spacer()
                            
                            // Bottom Home Bar & Gestures
                            bottomHomeBarView
                                .padding(.bottom, 10)
                        }
                        .padding(4)
                    )
            }
            .frame(width: baseWidth, height: baseHeight)
        }
        .padding(20)
    }
    
    // MARK: - Top Header (Sequoia-style hover controls)
    private var topHeaderView: some View {
        HStack {
            // Left: Status or Traffic Lights on Hover
            if isHoveringTop {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                        .onTapGesture {
                            if appState.isMirroring {
                                appState.toggleMirroring()
                            }
                        }
                    Circle()
                        .fill(Color.yellow)
                        .frame(width: 10, height: 10)
                }
                .transition(.opacity)
            } else {
                if let device = appState.selectedDevice {
                    Text(device.connectionType.rawValue)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                } else {
                    Text("AndOnMac")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            
            Spacer()
            
            // Pixel Camera Punch-Hole
            Circle()
                .fill(Color.black)
                .frame(width: 12, height: 12)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
            
            Spacer()
            
            // Right: Sequoia Action Buttons on Hover
            if isHoveringTop {
                HStack(spacing: 10) {
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
                }
                .transition(.opacity)
            } else {
                if let battery = appState.selectedDevice?.batteryLevel {
                    HStack(spacing: 4) {
                        Text("\(battery)%")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white.opacity(0.8))
                        Image(systemName: appState.selectedDevice?.isCharging == true ? "battery.100.bolt" : "battery.100")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.8))
                    }
                } else {
                    Image(systemName: "wifi")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
        }
        .frame(height: 24)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHoveringTop = hovering
            }
        }
    }
    
    // MARK: - Center Content View (Zero-Friction UX)
    @ViewBuilder
    private var centerContentView: some View {
        if appState.isMirroring {
            // Live Mirroring Screen (Mirror is active in SDL window or controller)
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.2))
                        .frame(width: 76, height: 76)
                    Image(systemName: "tv.and.mediabox")
                        .font(.system(size: 34))
                        .foregroundColor(.green)
                }
                
                VStack(spacing: 4) {
                    Text("Экран активен на Mac")
                        .font(.title3.bold())
                        .foregroundColor(.white)
                    Text("Дисплей телефона выключен для экономии заряда")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                
                // Quick Controls
                HStack(spacing: 14) {
                    Button {
                        appState.triggerBack()
                    } label: {
                        Label("Назад", systemImage: "chevron.backward")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    
                    Button {
                        appState.triggerHome()
                    } label: {
                        Label("Домой", systemImage: "house.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    
                    Button {
                        appState.triggerAppSwitch()
                    } label: {
                        Label("Обзор", systemImage: "square.stack.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
                .padding(.top, 4)
                
                Button(role: .destructive) {
                    appState.toggleMirroring()
                } label: {
                    Label("Завершить", systemImage: "xmark.circle.fill")
                        .font(.subheadline.bold())
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            }
        } else if let unauthDevice = appState.devices.first(where: { $0.state == .unauthorized }) {
            // 1-Click Action: User plugged in cable, just tap "Allow" on phone!
            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.2))
                        .frame(width: 80, height: 80)
                    Image(systemName: "hand.tap.fill")
                        .font(.system(size: 38))
                        .foregroundColor(.orange)
                }
                
                VStack(spacing: 6) {
                    Text("Подтвердите на телефоне")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text("Разблокируйте **\(unauthDevice.displayName)** и нажмите **«Разрешить»** на экране.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.horizontal, 20)
                }
                
                ProgressView()
                    .controlSize(.small)
                Text("Ожидание подтверждения...")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.5))
            }
        } else if let device = appState.selectedDevice {
            // Device Ready!
            VStack(spacing: 20) {
                VStack(spacing: 2) {
                    Text(Date(), style: .time)
                        .font(.system(size: 48, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                    Text(Date(), style: .date)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                }
                .padding(.top, 10)
                
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 80, height: 80)
                    Image(systemName: device.isPixel ? "g.circle.fill" : "smartphone")
                        .font(.system(size: 42))
                        .foregroundColor(.white)
                }
                
                VStack(spacing: 4) {
                    Text(device.displayName)
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(device.connectionType == .wifi ? "Готов к беспроводной работе" : "Подключен по Type-C")
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
                    .frame(minWidth: 160)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
            }
        } else {
            // ZERO-COMPLICATION ONBOARDING SCREEN
            VStack(spacing: 22) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(pulseAnimation ? 0.25 : 0.1))
                        .frame(width: 90, height: 90)
                        .scaleEffect(pulseAnimation ? 1.08 : 0.96)
                        .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: pulseAnimation)
                    
                    Image(systemName: "cable.connector.horizontal")
                        .font(.system(size: 40))
                        .foregroundColor(.accentColor)
                }
                .onAppear {
                    pulseAnimation = true
                }
                
                VStack(spacing: 6) {
                    Text("Подключите ваш телефон")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    
                    Text("Вставьте кабель Type-C на 3 секунды для первой привязки или подключите без проводов по Wi-Fi.")
                        .font(.system(size: 12))
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 24)
                }
                
                Button {
                    appState.showPairingSheet = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "wifi")
                            .font(.system(size: 13, weight: .bold))
                        Text("Подключить по Wi-Fi (Код сопряжения)")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(
                        LinearGradient(
                            colors: [Color.blue, Color.cyan],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .foregroundColor(.white)
                    .cornerRadius(20)
                    .shadow(color: Color.blue.opacity(0.4), radius: 10, x: 0, y: 4)
                }
                .buttonStyle(.plain)
                
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "1.circle.fill")
                            .foregroundColor(.cyan)
                        Text("Или вставьте кабель Type-C в MacBook")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.9))
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "2.circle.fill")
                            .foregroundColor(.cyan)
                        Text("Нажмите «Разрешить» на экране телефона")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.9))
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "3.circle.fill")
                            .foregroundColor(.green)
                        Text("Экран смартфона сразу появится на Mac!")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.green)
                    }
                }
                .padding(14)
                .background(Color.white.opacity(0.05))
                .cornerRadius(14)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                
                Button {
                    Task {
                        await appState.resetUSBAndADB()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Восстановить USB / Сбросить ADB")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.08))
                    .foregroundColor(.white.opacity(0.75))
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .help("Если после переключения в Wi-Fi телефон не виден по кабелю — нажмите сюда и переподключите «Отладку по USB» на телефоне")
            }
        }
    }
    
    // MARK: - Bottom Home Bar
    private var bottomHomeBarView: some View {
        VStack {
            Capsule()
                .fill(Color.white.opacity(isHoveringHome ? 0.9 : 0.5))
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
        .frame(height: 20)
    }
}
