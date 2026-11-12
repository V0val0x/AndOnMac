import SwiftUI
import AppKit

public struct MainWindowView: View {
    @ObservedObject var appState: AppState
    
    public init(appState: AppState) {
        self.appState = appState
    }
    
    public var body: some View {
        ZStack {
            // Background blur / macOS native material
            VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Top subtle header
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "iphone.gen3")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.accentColor)
                        Text("AndOnMac")
                            .font(.system(size: 13, weight: .bold))
                    }
                    
                    Spacer()
                    
                    // Wireless / QR pairing button
                    Button {
                        appState.showPairingSheet = true
                    } label: {
                        Label("QR / Wi-Fi", systemImage: "qrcode")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    // Device status pill
                    if let device = appState.selectedDevice {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(appState.isMirroring ? Color.green : Color.orange)
                                .frame(width: 7, height: 7)
                            Text(device.displayName)
                                .font(.system(size: 12, weight: .medium))
                            if let battery = device.batteryLevel {
                                Text("\(battery)%")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.06))
                        .cornerRadius(12)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 6)
                
                // Main Device View (Phone Frame)
                PhoneMirrorFrameView(appState: appState)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $appState.showPairingSheet) {
            WirelessPairingView(appState: appState)
        }
    }
}

// Native macOS visual effect helper
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
