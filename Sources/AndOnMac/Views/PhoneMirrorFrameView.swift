import SwiftUI

public struct PhoneMirrorFrameView: View {
    @ObservedObject var appState: AppState
    
    public init(appState: AppState) {
        self.appState = appState
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Phone Bezel Frame
            ZStack {
                // Device Outer Frame
                RoundedRectangle(cornerRadius: 44, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 44, style: .continuous)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 4)
                    )
                    .shadow(color: .black.opacity(0.25), radius: 20, x: 0, y: 10)
                
                // Screen Area
                VStack(spacing: 0) {
                    // Top Notch / Camera Hole
                    HStack {
                        // Left status
                        if let device = appState.selectedDevice {
                            Text(device.connectionType.rawValue)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary)
                        } else {
                            Text("No Device")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        // Pixel Camera Punch-hole
                        Circle()
                            .fill(Color.black)
                            .frame(width: 14, height: 14)
                            .overlay(
                                Circle()
                                    .stroke(Color.gray.opacity(0.4), lineWidth: 1)
                            )
                        
                        Spacer()
                        
                        // Right status (Battery)
                        HStack(spacing: 4) {
                            if let level = appState.selectedDevice?.batteryLevel {
                                Text("\(level)%")
                                    .font(.system(size: 11, weight: .bold))
                                Image(systemName: appState.selectedDevice?.isCharging == true ? "battery.100.bolt" : "battery.100")
                                    .font(.system(size: 12))
                            } else {
                                Image(systemName: "wifi")
                                    .font(.system(size: 11))
                            }
                        }
                        .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
                    
                    Spacer()
                    
                    // Center Content
                    if appState.isMirroring {
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.2)
                            Text("Зеркалирование активно")
                                .font(.headline)
                            Text("Экран телефона работает в отдельном окне,\nсам телефон заблокирован для экономии батареи.")
                                .font(.caption)
                                .multilineTextAlignment(.center)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 30)
                            
                            Button(role: .destructive) {
                                appState.toggleMirroring()
                            } label: {
                                Label("Остановить сессию", systemImage: "stop.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .padding(.top, 8)
                        }
                    } else if let device = appState.selectedDevice {
                        VStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .fill(Color.accentColor.opacity(0.12))
                                    .frame(width: 80, height: 80)
                                Image(systemName: device.isPixel ? "g.circle.fill" : "iphone.gen3")
                                    .font(.system(size: 40))
                                    .foregroundColor(.accentColor)
                            }
                            
                            VStack(spacing: 4) {
                                Text(device.displayName)
                                    .font(.title3.bold())
                                Text(device.connectionType == .wifi ? "Беспроводное подключение" : "Подключено по USB")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
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
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            
                            if device.connectionType == .usb {
                                Button {
                                    Task {
                                        await appState.switchSelectedToWireless()
                                    }
                                } label: {
                                    Label("Переключить на Wi-Fi", systemImage: "wifi")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 36))
                                .foregroundColor(.secondary)
                            Text("Нет подключенных устройств")
                                .font(.headline)
                            Text("Подключите ваш Pixel или Android по USB\nили настройте Wireless Debugging.")
                                .font(.caption)
                                .multilineTextAlignment(.center)
                                .foregroundColor(.secondary)
                            
                            Button {
                                appState.showPairingSheet = true
                            } label: {
                                Label("Подключить по Wi-Fi", systemImage: "plus")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    
                    Spacer()
                    
                    // Bottom Home Indicator Bar (like iPhone / Android Gestures)
                    Capsule()
                        .fill(Color.primary.opacity(0.25))
                        .frame(width: 120, height: 5)
                        .padding(.bottom, 10)
                }
                .padding(6)
            }
            .frame(width: 320, height: 650)
        }
        .padding()
    }
}
