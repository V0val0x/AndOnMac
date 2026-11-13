import SwiftUI

public enum PairingTab: String, CaseIterable, Identifiable {
    case wifiPin = "По воздуху (Wi-Fi)"
    case usbSetup = "Кабель за 3 сек"
    case savedDevices = "Сохранённые устройства"
    
    public var id: String { rawValue }
}

public struct WirelessPairingView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var discovery = DiscoveryService.shared
    @Environment(\.dismiss) private var dismiss
    
    @State private var selectedTab: PairingTab = .wifiPin
    
    private enum FocusField: Hashable {
        case addressPort, connectPort, pinCode
    }
    @FocusState private var focusedField: FocusField?
    
    // PIN Code State
    @State private var addressAndPort: String = ""
    @State private var connectPortText: String = ""
    @State private var pinCode: String = ""
    @State private var isProcessing: Bool = false
    @State private var showManualInputs: Bool = false
    
    // Status feedback
    @State private var resultMessage: String?
    @State private var isSuccess: Bool = false
    
    public init(appState: AppState) {
        self.appState = appState
    }
    
    public var body: some View {
        ZStack {
            // Apple / Spotify Deep Obsidian Background
            Color(red: 0.05, green: 0.06, blue: 0.08)
                .ignoresSafeArea()
            
            VStack(spacing: 20) {
                // Header Bar
                HStack(alignment: .center) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [Color.blue.opacity(0.85), Color.cyan.opacity(0.85)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 36, height: 36)
                            Image(systemName: "wifi")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.white)
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Подключение Android")
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                            Text("Беспроводное сопряжение и быстрая настройка")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.6))
                        }
                    }
                    
                    Spacer()
                    
                    Button {
                        discovery.stopBrowsing()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.white.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                }
                
                // Spotify-Grade Segmented Pill Switcher
                HStack(spacing: 6) {
                    ForEach(PairingTab.allCases) { tab in
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                selectedTab = tab
                            }
                        } label: {
                            HStack(spacing: 6) {
                                switch tab {
                                case .wifiPin:
                                    Image(systemName: "bolt.horizontal.fill")
                                        .font(.system(size: 11))
                                case .usbSetup:
                                    Image(systemName: "cable.connector")
                                        .font(.system(size: 11))
                                case .savedDevices:
                                    Image(systemName: "clock.arrow.circlepath")
                                        .font(.system(size: 11))
                                }
                                Text(tab.rawValue)
                                    .font(.system(size: 12, weight: selectedTab == tab ? .bold : .medium))
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 14)
                            .frame(maxWidth: .infinity)
                            .background(
                                selectedTab == tab
                                    ? Color.white.opacity(0.18)
                                    : Color.white.opacity(0.04)
                            )
                            .foregroundColor(selectedTab == tab ? .white : .white.opacity(0.6))
                            .cornerRadius(20)
                            .overlay(
                                RoundedRectangle(cornerRadius: 20)
                                    .stroke(
                                        selectedTab == tab ? Color.white.opacity(0.2) : Color.clear,
                                        lineWidth: 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .background(Color.white.opacity(0.04))
                .cornerRadius(24)
                
                // Tab Content Card
                VStack {
                    switch selectedTab {
                    case .wifiPin:
                        wifiPinTab
                    case .usbSetup:
                        usbSetupTab
                    case .savedDevices:
                        savedDevicesTab
                    }
                }
                .frame(maxHeight: .infinity)
                
                // Status Feedback Banner
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
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
                
                // Footer
                HStack {
                    Button("Закрыть") {
                        discovery.stopBrowsing()
                        dismiss()
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.white.opacity(0.5))
                    .font(.system(size: 13, weight: .medium))
                    
                    Spacer()
                    
                    if selectedTab == .wifiPin {
                        Button {
                            submitPairing()
                        } label: {
                            HStack(spacing: 6) {
                                if isProcessing {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "link")
                                    Text("Сопряжение")
                                        .font(.system(size: 13, weight: .bold))
                                }
                            }
                            .padding(.horizontal, 20)
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
                        .disabled(currentPairingHostAndPort.isEmpty || pinCode.count < 6 || isProcessing)
                        .opacity(currentPairingHostAndPort.isEmpty || pinCode.count < 6 ? 0.45 : 1.0)
                    }
                }
            }
            .padding(24)
        }
        .frame(width: 530, height: 560)
        .onAppear {
            discovery.startBrowsing()
            prefillSubnet()
        }
        .onDisappear {
            discovery.stopBrowsing()
        }
    }
    
    // MARK: - Current Effective Host & Port
    private var currentPairingHostAndPort: String {
        if let host = discovery.detectedPairingHost, let port = discovery.detectedPairingPort, !showManualInputs {
            return "\(host):\(port)"
        }
        return addressAndPort.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - Tab 1: Wi-Fi PIN Code
    private var wifiPinTab: some View {
        VStack(spacing: 16) {
            // Live Bonjour Detection Card or Step Guide
            if let host = discovery.detectedPairingHost, let port = discovery.detectedPairingPort, !showManualInputs {
                // Auto-detected card
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 10, height: 10)
                            .overlay(
                                Circle()
                                    .stroke(Color.green.opacity(0.5), lineWidth: 4)
                            )
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Обнаружен телефон в сети Wi-Fi!")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                            Text("\(discovery.detectedDeviceName ?? "Android Device") • \(host):\(port)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.cyan)
                        }
                        
                        Spacer()
                        
                        Button {
                            showManualInputs = true
                        } label: {
                            Text("Изменить")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(14)
                    .background(Color.green.opacity(0.12))
                    .cornerRadius(14)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.green.opacity(0.3), lineWidth: 1)
                    )
                }
            } else {
                // Instruction banner
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.cyan)
                        Text("Где открыть на телефоне:")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                    }
                    Text("**Настройки → Для разработчиков → Беспроводная отладка** и нажмите **«Подключить с помощью кода сопряжения»**.")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.75))
                        .lineSpacing(2)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.04))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                
                // Manual IP & Port Inputs
                VStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("IP-АДРЕС И ПОРТ СОПРЯЖЕНИЯ (ИЗ ВСПЛЫВАЮЩЕГО ОКНА)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white.opacity(0.5))
                        
                        TextField("например: 192.168.1.45:41893", text: $addressAndPort)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .focused($focusedField, equals: .addressPort)
                            .padding(10)
                            .background(Color.white.opacity(0.07))
                            .cornerRadius(10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(focusedField == .addressPort ? Color.cyan.opacity(0.8) : Color.white.opacity(0.12), lineWidth: 1)
                            )
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("ПОРТ ПОДКЛЮЧЕНИЯ (ИЗ ГЛАВНОГО ЭКРАНА ОТЛАДКИ)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white.opacity(0.5))
                            Spacer()
                            Text("необязательно")
                                .font(.system(size: 9))
                                .foregroundColor(.white.opacity(0.35))
                        }
                        
                        TextField("например: 38291 (если отличается)", text: $connectPortText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .focused($focusedField, equals: .connectPort)
                            .padding(10)
                            .background(Color.white.opacity(0.07))
                            .cornerRadius(10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(focusedField == .connectPort ? Color.cyan.opacity(0.8) : Color.white.opacity(0.12), lineWidth: 1)
                            )
                    }
                }
            }
            
            // Selectable Native 6-digit PIN Field
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("6-ЗНАЧНЫЙ КОД СОПРЯЖЕНИЯ ПО WI-FI")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.5))
                    Spacer()
                    if !pinCode.isEmpty {
                        Text("\(pinCode.count)/6")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(pinCode.count == 6 ? .green : .cyan)
                    }
                }
                
                HStack(spacing: 10) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 15))
                        .foregroundColor(focusedField == .pinCode ? .cyan : .white.opacity(0.45))
                    
                    TextField("Например: 123456", text: $pinCode)
                        .textFieldStyle(.plain)
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .focused($focusedField, equals: .pinCode)
                        .onChange(of: pinCode) { _, newValue in
                            let filtered = String(newValue.filter { $0.isNumber }.prefix(6))
                            if filtered != newValue {
                                pinCode = filtered
                            }
                            if filtered.count == 6 && isValidHostAndPort(currentPairingHostAndPort) && !isProcessing {
                                submitPairing()
                            }
                        }
                        .onSubmit {
                            if pinCode.count == 6 && isValidHostAndPort(currentPairingHostAndPort) && !isProcessing {
                                submitPairing()
                            }
                        }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.08))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            focusedField == .pinCode || pinCode.count == 6
                                ? Color.cyan.opacity(0.85)
                                : Color.white.opacity(0.14),
                            lineWidth: focusedField == .pinCode ? 1.8 : 1
                        )
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    focusedField = .pinCode
                }
            }
            
            Spacer()
        }
    }
    
    private func isValidHostAndPort(_ str: String) -> Bool {
        let parts = str.components(separatedBy: ":")
        guard parts.count == 2, let port = Int(parts[1]), (1...65535).contains(port) else {
            return false
        }
        let octets = parts[0].components(separatedBy: ".")
        return octets.count == 4 && octets.allSatisfy { !$0.isEmpty && Int($0) != nil }
    }
    
    // MARK: - Tab 2: USB 3-Second Setup
    private var usbSetupTab: some View {
        VStack(spacing: 16) {
            let hasUSBDevice = appState.devices.contains { $0.connectionType == .usb }
            
            ZStack {
                Circle()
                    .fill(hasUSBDevice ? Color.green.opacity(0.15) : Color.blue.opacity(0.15))
                    .frame(width: 64, height: 64)
                Image(systemName: hasUSBDevice ? "checkmark.circle.fill" : "cable.connector.horizontal")
                    .font(.system(size: 30))
                    .foregroundColor(hasUSBDevice ? Color.green : Color.cyan)
            }
            .padding(.top, 8)
            
            VStack(spacing: 4) {
                Text(hasUSBDevice ? "Устройство подключено по кабелю!" : "Подключение кабелем за 3 секунды")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                Text("Самый надежный способ: один раз вставил — и работает по воздуху навсегда.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
            
            VStack(alignment: .leading, spacing: 12) {
                stepRow(num: "1", title: "Вставьте кабель Type-C от телефона в Mac", active: true)
                stepRow(num: "2", title: "Нажмите «Разрешить» на экране телефона", active: true)
                stepRow(num: "3", title: "Отключите кабель: теперь телефон привязан по Wi-Fi", active: false)
            }
            .padding(14)
            .background(Color.white.opacity(0.04))
            .cornerRadius(14)
            
            if hasUSBDevice {
                Button {
                    Task {
                        isProcessing = true
                        let (success, message) = await appState.switchSelectedToWireless()
                        isProcessing = false
                        isSuccess = success
                        resultMessage = success ? "✅ \(message)" : message
                        if success {
                            try? await Task.sleep(nanoseconds: 1_200_000_000)
                            dismiss()
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill")
                        Text("Переключить в Wi-Fi режим прямо сейчас")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Color.green.opacity(0.85))
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
            } else {
                VStack(spacing: 8) {
                    Button {
                        Task {
                            isProcessing = true
                            await appState.resetUSBAndADB()
                            isProcessing = false
                            isSuccess = true
                            resultMessage = "ADB перезапущен. Переподключите кабель или переключите «Отладку по USB»."
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                            Text("Восстановить USB / Сбросить ADB")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.1))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                    
                    Text("Если после переключения в Wi-Fi телефон перестал определяться по кабелю: нажмите «Восстановить USB / Сбросить ADB» и на телефоне выключите/включите тумблер «Отладка по USB».")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                }
            }
            
            Spacer()
        }
    }
    
    private func stepRow(num: String, title: String, active: Bool) -> some View {
        HStack(spacing: 10) {
            Text(num)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.cyan)
                .frame(width: 20, height: 20)
                .background(Color.cyan.opacity(0.18))
                .clipShape(Circle())
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.85))
        }
    }
    
    // MARK: - Tab 3: Saved Devices
    private var savedDevicesTab: some View {
        VStack(spacing: 12) {
            if appState.knownDevices.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 32))
                        .foregroundColor(.white.opacity(0.3))
                        .padding(.top, 30)
                    Text("Нет сохранённых устройств")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                    Text("Подключите телефон через вкладку «По воздуху» или «Кабель», и он сохранится здесь для мгновенного доступа.")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(appState.knownDevices) { known in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(known.name)
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundColor(.white)
                                    Text("\(known.ipAddress):\(known.port)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.5))
                                }
                                
                                Spacer()
                                
                                Button {
                                    Task {
                                        isProcessing = true
                                        let success = await appState.connectWireless(host: known.ipAddress, port: known.port)
                                        isProcessing = false
                                        if success {
                                            isSuccess = true
                                            resultMessage = "Подключено к \(known.name)!"
                                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                                            dismiss()
                                        } else {
                                            isSuccess = false
                                            resultMessage = "Не удалось подключиться к \(known.ipAddress):\(known.port)"
                                        }
                                    }
                                } label: {
                                    Text("Подключиться")
                                        .font(.system(size: 11, weight: .bold))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Color.blue)
                                        .foregroundColor(.white)
                                        .cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                                
                                Button {
                                    appState.removeKnownDevice(id: known.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 12))
                                        .foregroundColor(.white.opacity(0.4))
                                }
                                .buttonStyle(.plain)
                                .padding(.leading, 6)
                            }
                            .padding(12)
                            .background(Color.white.opacity(0.04))
                            .cornerRadius(12)
                        }
                    }
                }
            }
            
            Spacer()
        }
    }
    
    // Prefill local subnet for manual fallback
    private func prefillSubnet() {
        let macIP = ADBService.shared.getMacLocalIP()
        let parts = macIP.components(separatedBy: ".")
        if parts.count == 4 {
            addressAndPort = "\(parts[0]).\(parts[1]).\(parts[2])."
        }
    }
    
    // Execute Pairing & Connection
    private func submitPairing() {
        let target = currentPairingHostAndPort
        guard target.contains(":") else {
            resultMessage = "Укажите адрес и порт через двоеточие (например: 192.168.1.45:41893)"
            isSuccess = false
            return
        }
        let parts = target.components(separatedBy: ":")
        guard parts.count == 2, let port = Int(parts[1]), !parts[0].isEmpty else {
            resultMessage = "Некорректный порт"
            isSuccess = false
            return
        }
        
        let host = parts[0]
        let code = pinCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let manualConnectPort = Int(connectPortText.trimmingCharacters(in: .whitespacesAndNewlines))
        
        isProcessing = true
        resultMessage = nil
        
        Task {
            let (success, message) = await appState.pairAndConnect(
                host: host,
                pairingPort: port,
                code: code,
                connectPort: manualConnectPort
            )
            isProcessing = false
            if success {
                isSuccess = true
                resultMessage = "✅ \(message)"
                discovery.resetPairingState()
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                dismiss()
            } else {
                isSuccess = false
                resultMessage = message
            }
        }
    }
}
