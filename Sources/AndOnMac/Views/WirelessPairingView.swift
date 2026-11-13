import SwiftUI

public enum PairingTab: String, CaseIterable, Identifiable {
    case wifiPin = "Wi-Fi"
    case usbSetup = "Кабель USB"
    case savedDevices = "Сохранённые"
    
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
    
    private func closePairing() {
        discovery.stopBrowsing()
        withAnimation(.easeInOut(duration: 0.25)) {
            appState.showPairingSheet = false
        }
        dismiss()
    }
    
    public var body: some View {
        ZStack {
            // Dark Background
            Color(red: 0.05, green: 0.06, blue: 0.08)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Top In-Phone Header Bar
                HStack(alignment: .center) {
                    Button {
                        closePairing()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .bold))
                            Text("Назад")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundColor(.cyan)
                    }
                    .buttonStyle(.plain)
                    
                    Spacer()
                    
                    Text("Подключение")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    Button {
                        appState.refreshDevices()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help("Обновить список устройств")
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)
                
                // Live Device Status Alert (if connected via USB or pending authorization)
                if appState.devices.contains(where: { $0.state == .unauthorized }) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.system(size: 14))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Подтвердите на телефоне")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white)
                            Text("Разблокируйте экран и нажмите «Разрешить»")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.8))
                        }
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.18))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.orange.opacity(0.4), lineWidth: 1)
                    )
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                } else if let readyDevice = appState.devices.first(where: { $0.state == .ready && $0.connectionType == .usb }) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 14))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Подключен по USB: \(readyDevice.displayName)")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white)
                            Text("Устройство готово к работе")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.7))
                        }
                        Spacer()
                        Button {
                            closePairing()
                            appState.toggleMirroring()
                        } label: {
                            Text("Открыть")
                                .font(.system(size: 11, weight: .bold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.green)
                                .foregroundColor(.black)
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.15))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.green.opacity(0.3), lineWidth: 1)
                    )
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                }
                
                // Segmented Pill Switcher
                HStack(spacing: 4) {
                    ForEach(PairingTab.allCases) { tab in
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                selectedTab = tab
                            }
                        } label: {
                            HStack(spacing: 4) {
                                switch tab {
                                case .wifiPin:
                                    Image(systemName: "wifi")
                                        .font(.system(size: 10))
                                case .usbSetup:
                                    Image(systemName: "cable.connector")
                                        .font(.system(size: 10))
                                case .savedDevices:
                                    Image(systemName: "clock.arrow.circlepath")
                                        .font(.system(size: 10))
                                }
                                Text(tab.rawValue)
                                    .font(.system(size: 11, weight: selectedTab == tab ? .bold : .medium))
                            }
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity)
                            .background(
                                selectedTab == tab
                                    ? Color.white.opacity(0.18)
                                    : Color.white.opacity(0.04)
                            )
                            .foregroundColor(selectedTab == tab ? .white : .white.opacity(0.6))
                            .cornerRadius(16)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(
                                        selectedTab == tab ? Color.white.opacity(0.25) : Color.clear,
                                        lineWidth: 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(Color.white.opacity(0.04))
                .cornerRadius(18)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                
                // Scrollable Tab Content
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 14) {
                        switch selectedTab {
                        case .wifiPin:
                            wifiPinTab
                        case .usbSetup:
                            usbSetupTab
                        case .savedDevices:
                            savedDevicesTab
                        }
                        
                        // Status Feedback Toast
                        if let msg = resultMessage {
                            HStack(spacing: 6) {
                                Image(systemName: isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundColor(isSuccess ? Color.green : Color.orange)
                                    .font(.system(size: 11))
                                Text(msg)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(isSuccess ? Color.green.opacity(0.18) : Color.orange.opacity(0.18))
                            .cornerRadius(10)
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 20)
                }
            }
        }
        .onAppear {
            discovery.startBrowsing()
            prefillSubnet()
            appState.refreshDevices()
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
        VStack(spacing: 12) {
            if let host = discovery.detectedPairingHost, let port = discovery.detectedPairingPort, !showManualInputs {
                // Auto-detected card
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                            .overlay(Circle().stroke(Color.green.opacity(0.5), lineWidth: 3))
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Обнаружен телефон в Wi-Fi")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                            Text("\(discovery.detectedDeviceName ?? "Android") • \(host):\(port)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.cyan)
                        }
                        
                        Spacer()
                        
                        Button {
                            showManualInputs = true
                        } label: {
                            Text("Изменить")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.white.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
                .background(Color.green.opacity(0.12))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.green.opacity(0.3), lineWidth: 1)
                )
            } else {
                // Instruction banner
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.cyan)
                            .font(.system(size: 11))
                        Text("Где открыть на телефоне:")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                    }
                    Text("Настройки → Для разработчиков → Беспроводная отладка → **«Подключить с помощью кода сопряжения»**.")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.75))
                        .lineSpacing(2)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.04))
                .cornerRadius(10)
                
                // Manual IP & Port Inputs
                VStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("IP-АДРЕС И ПОРТ СОПРЯЖЕНИЯ")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white.opacity(0.5))
                        
                        TextField("например: 192.168.1.45:41893", text: $addressAndPort)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .focused($focusedField, equals: .addressPort)
                            .padding(8)
                            .background(Color.white.opacity(0.07))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(focusedField == .addressPort ? Color.cyan.opacity(0.8) : Color.white.opacity(0.12), lineWidth: 1)
                            )
                    }
                    
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("ПОРТ ПОДКЛЮЧЕНИЯ")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white.opacity(0.5))
                            Spacer()
                            Text("если отличается")
                                .font(.system(size: 8))
                                .foregroundColor(.white.opacity(0.35))
                        }
                        
                        TextField("например: 38291", text: $connectPortText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .focused($focusedField, equals: .connectPort)
                            .padding(8)
                            .background(Color.white.opacity(0.07))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(focusedField == .connectPort ? Color.cyan.opacity(0.8) : Color.white.opacity(0.12), lineWidth: 1)
                            )
                    }
                }
            }
            
            // 6-digit PIN Field
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("6-ЗНАЧНЫЙ КОД СОПРЯЖЕНИЯ")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(0.5))
                    Spacer()
                    if !pinCode.isEmpty {
                        Text("\(pinCode.count)/6")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(pinCode.count == 6 ? .green : .cyan)
                    }
                }
                
                HStack(spacing: 8) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 13))
                        .foregroundColor(focusedField == .pinCode ? .cyan : .white.opacity(0.45))
                    
                    TextField("123456", text: $pinCode)
                        .textFieldStyle(.plain)
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
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
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.08))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            focusedField == .pinCode || pinCode.count == 6
                                ? Color.cyan.opacity(0.85)
                                : Color.white.opacity(0.14),
                            lineWidth: focusedField == .pinCode ? 1.5 : 1
                        )
                )
            }
            
            Button {
                submitPairing()
            } label: {
                HStack(spacing: 6) {
                    if isProcessing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "bolt.fill")
                        Text("Подключить по коду")
                            .font(.system(size: 12, weight: .bold))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    LinearGradient(
                        colors: [Color.blue, Color.cyan],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .disabled(currentPairingHostAndPort.isEmpty || pinCode.count < 6 || isProcessing)
            .opacity(currentPairingHostAndPort.isEmpty || pinCode.count < 6 ? 0.45 : 1.0)
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
        VStack(spacing: 12) {
            let hasUSBReady = appState.devices.contains { $0.connectionType == .usb && $0.state == .ready }
            let hasUSBUnauth = appState.devices.contains { $0.connectionType == .usb && $0.state == .unauthorized }
            
            ZStack {
                Circle()
                    .fill(hasUSBReady ? Color.green.opacity(0.15) : (hasUSBUnauth ? Color.orange.opacity(0.15) : Color.blue.opacity(0.15)))
                    .frame(width: 52, height: 52)
                Image(systemName: hasUSBReady ? "checkmark.circle.fill" : (hasUSBUnauth ? "exclamationmark.triangle.fill" : "cable.connector.horizontal"))
                    .font(.system(size: 26))
                    .foregroundColor(hasUSBReady ? Color.green : (hasUSBUnauth ? Color.orange : Color.cyan))
            }
            .padding(.top, 4)
            
            VStack(spacing: 3) {
                Text(hasUSBReady ? "Устройство готово!" : (hasUSBUnauth ? "Требуется подтверждение" : "Кабель Type-C"))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                Text(hasUSBReady ? "Подключено по проводу: можно открыть экран или перевести в Wi-Fi." : (hasUSBUnauth ? "Нажмите «Разрешить отладку» на экране телефона." : "Вставьте кабель на 3 секунды для автоматической настройки."))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                stepRow(num: "1", title: "Вставьте кабель Type-C от телефона в Mac", active: true)
                stepRow(num: "2", title: "Нажмите «Разрешить» на экране телефона", active: hasUSBUnauth || hasUSBReady)
                stepRow(num: "3", title: "Нажмите кнопку ниже для перевода на Wi-Fi", active: hasUSBReady)
            }
            .padding(10)
            .background(Color.white.opacity(0.04))
            .cornerRadius(10)
            
            if hasUSBReady {
                VStack(spacing: 8) {
                    Button {
                        closePairing()
                        appState.toggleMirroring()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                            Text("Открыть экран (USB)")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                    
                    Button {
                        Task {
                            isProcessing = true
                            let (success, message) = await appState.switchSelectedToWireless()
                            isProcessing = false
                            isSuccess = success
                            resultMessage = success ? "✅ \(message)" : message
                            if success {
                                try? await Task.sleep(nanoseconds: 1_200_000_000)
                                closePairing()
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "wifi")
                            Text("Перевести на Wi-Fi режим")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.green.opacity(0.85))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                VStack(spacing: 6) {
                    Button {
                        Task {
                            isProcessing = true
                            await appState.resetUSBAndADB()
                            isProcessing = false
                            isSuccess = true
                            resultMessage = "ADB перезапущен. Переподключите кабель."
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("Восстановить USB / Сбросить ADB")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.1))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
    
    private func stepRow(num: String, title: String, active: Bool) -> some View {
        HStack(spacing: 8) {
            Text(num)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(active ? .cyan : .white.opacity(0.4))
                .frame(width: 18, height: 18)
                .background(active ? Color.cyan.opacity(0.2) : Color.white.opacity(0.08))
                .clipShape(Circle())
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(active ? .white : .white.opacity(0.5))
        }
    }
    
    // MARK: - Tab 3: Saved Devices
    private var savedDevicesTab: some View {
        VStack(spacing: 10) {
            if appState.knownDevices.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 28))
                        .foregroundColor(.white.opacity(0.3))
                        .padding(.top, 20)
                    Text("Нет сохранённых устройств")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    Text("Подключите телефон по Wi-Fi или кабелю, и он сохранится здесь.")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
            } else {
                VStack(spacing: 6) {
                    ForEach(appState.knownDevices) { known in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(known.name)
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.white)
                                Text("\(known.ipAddress):\(known.port)")
                                    .font(.system(size: 10, design: .monospaced))
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
                                        closePairing()
                                    } else {
                                        isSuccess = false
                                        resultMessage = "Не удалось подключиться к \(known.ipAddress)"
                                    }
                                }
                            } label: {
                                Text("Подключить")
                                    .font(.system(size: 10, weight: .bold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.blue)
                                    .foregroundColor(.white)
                                    .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                            
                            Button {
                                appState.removeKnownDevice(id: known.id)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.4))
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 4)
                        }
                        .padding(10)
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(10)
                    }
                }
            }
        }
    }
    
    // MARK: - Actions
    private func prefillSubnet() {
        let macIP = ADBService.shared.getMacLocalIP()
        if macIP != "127.0.0.1" && addressAndPort.isEmpty {
            let parts = macIP.components(separatedBy: ".")
            if parts.count == 4 {
                self.addressAndPort = "\(parts[0]).\(parts[1]).\(parts[2])."
            }
        }
    }
    
    private func submitPairing() {
        let targetHostAndPort = currentPairingHostAndPort
        guard isValidHostAndPort(targetHostAndPort) else {
            resultMessage = "Укажите корректный IP и порт (например, 192.168.1.55:41893)"
            isSuccess = false
            return
        }
        guard pinCode.count == 6 else {
            resultMessage = "Код сопряжения должен содержать ровно 6 цифр"
            isSuccess = false
            return
        }
        
        let parts = targetHostAndPort.components(separatedBy: ":")
        let host = parts[0]
        guard let pairingPort = Int(parts[1]) else { return }
        
        var userConnectPort: Int? = nil
        let trimmedConn = connectPortText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedConn.isEmpty, let p = Int(trimmedConn), (1...65535).contains(p) {
            userConnectPort = p
        }
        
        isProcessing = true
        resultMessage = "Сопряжение с \(host):\(pairingPort)..."
        
        Task {
            do {
                let (success, message) = try await ADBService.shared.pairAndConnect(
                    host: host,
                    pairingPort: pairingPort,
                    code: pinCode,
                    userConnectPort: userConnectPort
                )
                
                await MainActor.run {
                    self.isProcessing = false
                    self.isSuccess = success
                    self.resultMessage = message
                    
                    if success {
                        discovery.resetPairingState()
                        appState.refreshDevices()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            closePairing()
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.isProcessing = false
                    self.isSuccess = false
                    self.resultMessage = "Ошибка сопряжения: \(error.localizedDescription)"
                }
            }
        }
    }
}
