import SwiftUI
import AppKit

public struct PhoneMirrorFrameView: View {
    @ObservedObject var appState: AppState
    @State private var isHoveringTop: Bool = false
    @State private var isHoveringHome: Bool = false
    @State private var isDropTargeted: Bool = false
    @State private var dragOffset: CGFloat = 0
    
    public init(appState: AppState) {
        self.appState = appState
    }
    
    private var baseWidth: CGFloat { 330 * appState.windowScale.multiplier }
    private var baseHeight: CGFloat { 680 * appState.windowScale.multiplier }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Main Smartphone Body
            ZStack {
                // Outer Titanium / Aluminum Chassis
                RoundedRectangle(cornerRadius: 48, style: .continuous)
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
                        RoundedRectangle(cornerRadius: 48, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.25),
                                        Color.black.opacity(0.3)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 2.5
                            )
                    )
                    .shadow(color: Color.black.opacity(0.35), radius: 25, x: 0, y: 12)
                
                // Inner Screen Border & Display
                RoundedRectangle(cornerRadius: 42, style: .continuous)
                    .fill(Color.black)
                    .padding(5)
                    .overlay(
                        VStack(spacing: 0) {
                            // Top Bar & Camera Cutout
                            topHeaderView
                                .padding(.horizontal, 20)
                                .padding(.top, 10)
                            
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
                
                // Drag & Drop visual overlay
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 42, style: .continuous)
                        .fill(Color.accentColor.opacity(0.3))
                        .padding(5)
                        .overlay(
                            VStack(spacing: 12) {
                                Image(systemName: "arrow.down.doc.fill")
                                    .font(.system(size: 44))
                                    .foregroundColor(.white)
                                Text("Отпустите для передачи на телефон")
                                    .font(.headline)
                                    .foregroundColor(.white)
                            }
                        )
                }
            }
            .frame(width: baseWidth, height: baseHeight)
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleFileDrop(providers: providers)
                return true
            }
        }
        .padding()
    }
    
    // MARK: - Top Header (Sequoia-style hover controls)
    private var topHeaderView: some View {
        HStack {
            // Left: Status / Traffic Lights on Hover
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
                // Normal Status: Wi-Fi or Time
                if let device = appState.selectedDevice {
                    Text(device.connectionType.rawValue)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                } else {
                    Text("AndOnMac")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            
            Spacer()
            
            // Center: Pixel Camera Punch-Hole or Dynamic Island
            if appState.frameStyle == .pixel {
                Circle()
                    .fill(Color.black)
                    .frame(width: 13, height: 13)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
            } else {
                Capsule()
                    .fill(Color.black)
                    .frame(width: 70, height: 18)
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
            }
            
            Spacer()
            
            // Right: Sequoia Action Buttons on Hover (App Switcher, Home, Notifications)
            if isHoveringTop {
                HStack(spacing: 8) {
                    // App Switcher button (two rectangles)
                    Button {
                        appState.triggerAppSwitch()
                    } label: {
                        Image(systemName: "square.on.square")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    .help("Недавние приложения (Cmd+2)")
                    
                    // Home Screen button
                    Button {
                        appState.triggerHome()
                    } label: {
                        Image(systemName: "circle")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    .help("Домой (Cmd+1)")
                    
                    // Notification Center button
                    Button {
                        appState.triggerNotifications()
                    } label: {
                        Image(systemName: "bell")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    .help("Шторка уведомлений (Cmd+3)")
                }
                .transition(.opacity)
            } else {
                // Battery status
                HStack(spacing: 4) {
                    if let level = appState.selectedDevice?.batteryLevel {
                        Text("\(level)%")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white.opacity(0.8))
                        Image(systemName: appState.selectedDevice?.isCharging == true ? "battery.100.bolt" : "battery.100")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.8))
                    } else {
                        Image(systemName: "wifi")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.7))
                    }
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
    
    // MARK: - Center Content View
    @ViewBuilder
    private var centerContentView: some View {
        if appState.isMirroring {
            // Live Mirroring Info / Floating Controller
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.2))
                        .frame(width: 72, height: 72)
                    Image(systemName: "tv.and.mediabox")
                        .font(.system(size: 32))
                        .foregroundColor(.green)
                }
                
                VStack(spacing: 4) {
                    Text("Экран транслируется")
                        .font(.title3.bold())
                        .foregroundColor(.white)
                    Text("Телефон в режиме экономии энергии")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                }
                
                // Quick Controls Bar
                HStack(spacing: 16) {
                    Button {
                        appState.triggerBack()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "chevron.backward")
                            Text("Назад")
                                .font(.caption2)
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    
                    Button {
                        appState.triggerHome()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "house.fill")
                            Text("Домой")
                                .font(.caption2)
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    
                    Button {
                        appState.triggerAppSwitch()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "square.stack.fill")
                            Text("Обзор")
                                .font(.caption2)
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
                .padding(.top, 4)
                
                Button(role: .destructive) {
                    appState.toggleMirroring()
                } label: {
                    Label("Завершить сессию", systemImage: "xmark.circle.fill")
                        .font(.subheadline.bold())
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 12)
            }
        } else if let device = appState.selectedDevice {
            // Lock Screen / Standby View (1-in-1 with Apple Lock Screen)
            VStack(spacing: 18) {
                // Clock
                VStack(spacing: 2) {
                    Text(Date(), style: .time)
                        .font(.system(size: 46, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                    Text(Date(), style: .date)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                }
                .padding(.top, 20)
                
                // Device Icon
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 80, height: 80)
                    Image(systemName: device.isPixel ? "g.circle.fill" : "smartphone")
                        .font(.system(size: 44))
                        .foregroundColor(.white)
                }
                
                VStack(spacing: 4) {
                    Text(device.displayName)
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(device.connectionType == .wifi ? "Беспроводное подключение" : "Подключено по кабелю")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                }
                
                // Main Start Button (Sequoia style)
                Button {
                    appState.toggleMirroring()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Text("Начать зеркалирование")
                    }
                    .font(.headline)
                    .frame(minWidth: 180)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.accentColor)
                
                // Quick Action Apps
                HStack(spacing: 16) {
                    quickAppButton(icon: "message.fill", color: .green, name: "Сообщения", pkg: "com.google.android.apps.messaging")
                    quickAppButton(icon: "safari.fill", color: .blue, name: "Chrome", pkg: "com.android.chrome")
                    quickAppButton(icon: "paperplane.fill", color: .cyan, name: "Telegram", pkg: "org.telegram.messenger")
                    quickAppButton(icon: "gearshape.fill", color: .gray, name: "Настройки", pkg: "com.android.settings")
                }
                .padding(.top, 8)
            }
        } else {
            // No device connected view
            VStack(spacing: 16) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 42))
                    .foregroundColor(.white.opacity(0.5))
                
                Text("Устройство не найдено")
                    .font(.headline)
                    .foregroundColor(.white)
                
                Text("Подключите ваш Pixel кабелем или нажмите «Добавить по Wi-Fi» для беспроводного соединения.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 20)
                
                Button {
                    appState.showPairingSheet = true
                } label: {
                    Label("Добавить по Wi-Fi", systemImage: "wifi.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                
                Button {
                    appState.isDemoMode.toggle()
                } label: {
                    Text(appState.isDemoMode ? "Выйти из Демо" : "Запустить Демо-режим")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    // Quick app launcher icon
    private func quickAppButton(icon: String, color: Color, name: String, pkg: String) -> some View {
        Button {
            guard let device = appState.selectedDevice else { return }
            Task {
                try? await ADBService.shared.launchApp(serial: device.id, packageName: pkg)
                if !appState.isMirroring {
                    appState.toggleMirroring()
                }
            }
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(color)
                        .frame(width: 42, height: 42)
                    Image(systemName: icon)
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                }
                Text(name)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Bottom Home Bar (1-in-1 with iPhone / Android Home Indicator)
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
                                dragOffset = max(value.translation.height, -60)
                            }
                        }
                        .onEnded { value in
                            withAnimation(.spring()) {
                                if value.translation.height < -40 {
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
                .help("Нажмите или смахните вверх для перехода Домой (Cmd+1)")
        }
        .frame(height: 20)
    }
    
    // MARK: - File Drop Handler
    private func handleFileDrop(providers: [NSItemProvider]) {
        guard let device = appState.selectedDevice else { return }
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task {
                    _ = try? await ADBService.shared.pushFile(serial: device.id, localPath: url.path)
                }
            }
        }
    }
}
