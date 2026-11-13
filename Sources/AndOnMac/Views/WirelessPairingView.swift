import SwiftUI

public enum PairingTab: String, CaseIterable, Identifiable {
    case pinCode = "Код сопряжения"
    case qrCode = "QR-код"
    case usbSetup = "Кабель за 3 сек"
    
    public var id: String { rawValue }
}

public struct WirelessPairingView: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    
    @State private var selectedTab: PairingTab = .pinCode
    
    // PIN Code State
    @State private var addressAndPort: String = ""
    @State private var pinCode: String = ""
    @State private var isProcessingPIN: Bool = false
    
    // QR Code Credentials
    @State private var qrPassword: String = String(Int.random(in: 100000...999999))
    @State private var pairingStatus: String = "Ожидание сканирования с телефона..."
    
    @State private var resultMessage: String?
    @State private var isSuccess: Bool = false
    
    public init(appState: AppState) {
        self.appState = appState
    }
    
    private var qrPayload: String {
        "WIFI:T:ADB;S:AndOnMac;P:\(qrPassword);;"
    }
    
    public var body: some View {
        ZStack {
            // Apple / Spotify Deep Obsidian Background
            Color(red: 0.05, green: 0.06, blue: 0.08)
                .ignoresSafeArea()
            
            VStack(spacing: 18) {
                // Header Bar
                HStack(alignment: .center) {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(LinearGradient(colors: [Color.blue.opacity(0.8), Color.cyan.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 32, height: 32)
                            Image(systemName: "wifi")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.white)
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Беспроводное подключение")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                            Text("Свяжите ваш Android с Mac по Wi-Fi")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.6))
                        }
                    }
                    
                    Spacer()
                    
                    Button {
                        DiscoveryService.shared.stopQRPairingWatcher()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
                
                // Segmented Tabs (Spotify Pill Style)
                HStack(spacing: 6) {
                    ForEach(PairingTab.allCases) { tab in
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                selectedTab = tab
                                if tab == .qrCode {
                                    startQRWatcher()
                                } else {
                                    DiscoveryService.shared.stopQRPairingWatcher()
                                }
                            }
                        } label: {
                            Text(tab.rawValue)
                                .font(.system(size: 12, weight: selectedTab == tab ? .bold : .medium))
                                .padding(.vertical, 7)
                                .padding(.horizontal, 14)
                                .frame(maxWidth: .infinity)
                                .background(
                                    selectedTab == tab
                                        ? Color.white.opacity(0.18)
                                        : Color.white.opacity(0.04)
                                )
                                .foregroundColor(selectedTab == tab ? .white : .white.opacity(0.6))
                                .cornerRadius(20)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .background(Color.white.opacity(0.05))
                .cornerRadius(24)
                
                // Tab Content Card
                VStack {
                    switch selectedTab {
                    case .pinCode:
                        pinCodeView
                    case .qrCode:
                        qrCodeView
                    case .usbSetup:
                        usbSetupView
                    }
                }
                .frame(maxHeight: .infinity)
                
                // Status / Error / Success Message
                if let msg = resultMessage {
                    HStack(spacing: 8) {
                        Image(systemName: isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(isSuccess ? Color.green : Color.orange)
                        Text(msg)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(isSuccess ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                    .cornerRadius(12)
                }
                
                // Footer
                HStack {
                    Button("Отмена") {
                        DiscoveryService.shared.stopQRPairingWatcher()
                        dismiss()
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.white.opacity(0.5))
                    .font(.system(size: 13, weight: .medium))
                    
                    Spacer()
                    
                    if selectedTab == .pinCode {
                        Button {
                            submitPIN()
                        } label: {
                            HStack(spacing: 6) {
                                if isProcessingPIN {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("Подключить телефон")
                                        .font(.system(size: 13, weight: .bold))
                                }
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .background(
                                LinearGradient(
                                    colors: [Color.blue, Color.cyan],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                        .buttonStyle(.plain)
                        .disabled(addressAndPort.isEmpty || pinCode.count < 6 || isProcessingPIN)
                        .opacity(addressAndPort.isEmpty || pinCode.count < 6 ? 0.5 : 1.0)
                    }
                }
            }
            .padding(24)
        }
        .frame(width: 520, height: 530)
        .onAppear {
            prefillSubnet()
        }
        .onDisappear {
            DiscoveryService.shared.stopQRPairingWatcher()
        }
    }
    
    // MARK: - Tab 1: PIN Code View (Recommended, Fastest)
    private var pinCodeView: some View {
        VStack(spacing: 16) {
            // Visual Simulation Card of Android Phone Screen
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(.blue)
                    Text("На телефоне откройте:")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white.opacity(0.9))
                }
                Text("**Настройки → Для разработчиков → Беспроводная отладка** и нажмите **«Подключить с помощью кода сопряжения»**.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.7))
                    .lineSpacing(2)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.04))
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            
            // Address & Port Input
            VStack(alignment: .leading, spacing: 6) {
                Text("IP-АДРЕС И ПОРТ СОПРЯЖЕНИЯ")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.5))
                
                TextField("например: 192.168.1.45:39182", text: $addressAndPort)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .padding(12)
                    .background(Color.white.opacity(0.07))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
            }
            
            // 6-digit Code Input with Digit Boxes
            VStack(alignment: .leading, spacing: 8) {
                Text("6-ЗНАЧНЫЙ КОД СОПРЯЖЕНИЯ")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.5))
                
                HStack(spacing: 8) {
                    ForEach(0..<6, id: \.self) { index in
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.white.opacity(0.07))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(
                                            index < pinCode.count
                                                ? Color.cyan.opacity(0.8)
                                                : Color.white.opacity(0.12),
                                            lineWidth: index < pinCode.count ? 1.5 : 1
                                        )
                                )
                                .frame(height: 48)
                            
                            Text(digitAt(index: index))
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                        }
                    }
                }
                
                // Hidden / overlay text field to capture digits
                TextField("", text: Binding(
                    get: { pinCode },
                    set: { val in
                        let filtered = val.filter { $0.isNumber }
                        pinCode = String(filtered.prefix(6))
                        if pinCode.count == 6 && !addressAndPort.isEmpty {
                            submitPIN()
                        }
                    }
                ))
                .textFieldStyle(.plain)
                .frame(height: 1)
                .opacity(0.01)
            }
            
            Spacer()
        }
    }
    
    private func digitAt(index: Int) -> String {
        let chars = Array(pinCode)
        if index < chars.count {
            return String(chars[index])
        }
        return ""
    }
    
    // MARK: - Tab 2: QR Code View
    private var qrCodeView: some View {
        VStack(spacing: 14) {
            QRCodeView(payload: qrPayload, size: 160)
            
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(pairingStatus)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.cyan)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text("Инструкция:")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                Text("1. Откройте: **Настройки → Для разработчиков → Беспроводная отладка**.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.7))
                Text("2. Нажмите **«Подключить с помощью QR-кода»** и наведите на этот экран.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.04))
            .cornerRadius(12)
        }
    }
    
    // MARK: - Tab 3: USB Setup View
    private var usbSetupView: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 64, height: 64)
                Image(systemName: "cable.connector.horizontal")
                    .font(.system(size: 28))
                    .foregroundColor(.accentColor)
            }
            .padding(.top, 10)
            
            VStack(spacing: 4) {
                Text("Подключение кабелем за 3 секунды")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                Text("Самый надежный способ без ручных настроек")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
            }
            
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Text("1")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.cyan)
                        .frame(width: 20, height: 20)
                        .background(Color.cyan.opacity(0.2))
                        .clipShape(Circle())
                    Text("Вставьте кабель Type-C от телефона в MacBook.")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.8))
                }
                HStack(alignment: .top, spacing: 10) {
                    Text("2")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.cyan)
                        .frame(width: 20, height: 20)
                        .background(Color.cyan.opacity(0.2))
                        .clipShape(Circle())
                    Text("Нажмите «Разрешить» на экране телефона.")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.8))
                }
                HStack(alignment: .top, spacing: 10) {
                    Text("3")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.green)
                        .frame(width: 20, height: 20)
                        .background(Color.green.opacity(0.2))
                        .clipShape(Circle())
                    Text("Готово! Кабель можно отключить — дальше связь работает по воздуху.")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.green)
                }
            }
            .padding(14)
            .background(Color.white.opacity(0.04))
            .cornerRadius(12)
            
            Spacer()
        }
    }
    
    // Prefill local subnet for convenience
    private func prefillSubnet() {
        let macIP = ADBService.shared.getMacLocalIP()
        let parts = macIP.components(separatedBy: ".")
        if parts.count == 4 {
            addressAndPort = "\(parts[0]).\(parts[1]).\(parts[2])."
        }
    }
    
    private func startQRWatcher() {
        DiscoveryService.shared.startQRPairingWatcher(password: qrPassword) { host in
            Task { @MainActor in
                pairingStatus = "Телефон найден (\(host)), сопрягаем..."
            }
        } onPaired: { host in
            Task { @MainActor in
                pairingStatus = "✅ Успешно сопряжено!"
                isSuccess = true
                resultMessage = "Успешно сопряжено с \(host)!"
                appState.refreshDevices()
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                dismiss()
            }
        }
    }
    
    private func submitPIN() {
        let trimmedAddr = addressAndPort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedAddr.contains(":") else {
            resultMessage = "Укажите адрес и порт через двоеточие (например: 192.168.1.45:41893)"
            isSuccess = false
            return
        }
        let parts = trimmedAddr.components(separatedBy: ":")
        guard parts.count == 2, let port = Int(parts[1]), !parts[0].isEmpty else {
            resultMessage = "Некорректный порт"
            isSuccess = false
            return
        }
        
        let host = parts[0]
        let code = pinCode.trimmingCharacters(in: .whitespacesAndNewlines)
        
        isProcessingPIN = true
        resultMessage = nil
        
        Task {
            let success = await appState.pairDevice(host: host, port: port, code: code)
            isProcessingPIN = false
            if success {
                isSuccess = true
                resultMessage = "✅ Успешно сопряжено! Запуск трансляции..."
                // Now connect to device standard port 5555
                _ = try? await ADBService.shared.execute(arguments: ["connect", "\(host):5555"], timeoutSeconds: 5.0)
                appState.refreshDevices()
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                dismiss()
            } else {
                isSuccess = false
                resultMessage = appState.statusMessage
            }
        }
    }
}
