import SwiftUI

public enum PairingTab: String, CaseIterable, Identifiable {
    case wifiPin = "Wi-Fi"
    case usbSetup = "Кабель USB"
    case savedDevices = "История"
    
    public var id: String { rawValue }

    public func title(lang: AppLanguage) -> String {
        switch self {
        case .wifiPin: return "Wi-Fi"
        case .usbSetup: return L10n.tr("Кабель USB", "USB Cable", lang: lang)
        case .savedDevices: return L10n.tr("История", "History", lang: lang)
        }
    }
}

public struct WirelessPairingView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var discovery = DiscoveryService.shared
    @ObservedObject private var routerBypass = RouterlessBypassService.shared
    @ObservedObject private var qrPairing = QRPairingService.shared
    @Environment(\.dismiss) private var dismiss
    
    @State private var selectedTab: PairingTab = .wifiPin
    
    private enum FocusField: Hashable {
        case addressPort, connectPort, pinCode, pairedIP, pairedPort
    }
    @FocusState private var focusedField: FocusField?
    
    // Already Paired Direct Connect
    @State private var pairedIP: String = ""
    @State private var pairedPort: String = ""
    @State private var showFirstTimePairing: Bool = false
    
    // PIN Code State
    @State private var addressAndPort: String = ""
    @State private var connectPortText: String = ""
    @State private var pinCode: String = ""
    @State private var isProcessing: Bool = false
    @State private var showManualInputs: Bool = false
    
    // Status feedback
    @State private var resultMessage: String?
    @State private var isSuccess: Bool = false
    @Namespace private var pairingTabNamespace
    
    public init(appState: AppState) {
        self.appState = appState
    }
    
    private func closePairing() {
        withAnimation(AndMotion.drawerSpring) {
            appState.showPairingSheet = false
        }
        dismiss()
    }
    
    public var body: some View {
        ZStack {
            // Dark Background
            Color(red: 0.05, green: 0.06, blue: 0.08)
                .ignoresSafeArea()
                .makeWindowDraggable()
            
            VStack(spacing: 0) {
                // Top In-Phone Header Bar
                HStack(alignment: .center) {
                    Button {
                        closePairing()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .bold))
                            Text(L10n.tr("Назад", "Back", lang: appState.lang))
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundColor(.cyan)
                    }
                    .buttonStyle(.plain)
                    
                    Spacer()
                    
                    Text(L10n.tr("Подключение", "Connect", lang: appState.lang))
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
                    .help(L10n.tr("Обновить список устройств", "Refresh device list", lang: appState.lang))
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)
                .contentShape(Rectangle())
                .makeWindowDraggable()
                
                // Live Device Status Alert (if connected via USB or pending authorization)
                if appState.devices.contains(where: { $0.state == .unauthorized }) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.system(size: 14))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.tr("Подтвердите на телефоне", "Confirm on your phone", lang: appState.lang))
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white)
                            Text(L10n.tr("Разблокируйте экран и нажмите «Разрешить»", "Unlock your phone and tap Allow", lang: appState.lang))
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
                            Text(L10n.tr("Подключен по USB: \(readyDevice.displayName)", "Connected via USB: \(readyDevice.displayName)", lang: appState.lang))
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white)
                            Text(L10n.tr("Устройство готово к работе", "Device ready", lang: appState.lang))
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.7))
                        }
                        Spacer()
                        Button {
                            closePairing()
                            appState.toggleMirroring()
                        } label: {
                            Text(L10n.tr("Открыть", "Open", lang: appState.lang))
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
                            withAnimation(AndMotion.pillSlide) {
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
                                Text(tab.title(lang: appState.lang))
                                    .font(.system(size: 11, weight: selectedTab == tab ? .bold : .medium))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity)
                            .background(
                                ZStack {
                                    if selectedTab == tab {
                                        RoundedRectangle(cornerRadius: AndRadius.pill, style: .continuous)
                                            .fill(Color.white.opacity(0.18))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: AndRadius.pill, style: .continuous)
                                                    .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.75)
                                            )
                                            .matchedGeometryEffect(id: "pairingTabPill", in: pairingTabNamespace)
                                    } else {
                                        RoundedRectangle(cornerRadius: AndRadius.pill, style: .continuous)
                                            .fill(Color.white.opacity(0.04))
                                    }
                                }
                            )
                            .foregroundColor(selectedTab == tab ? .white : .white.opacity(0.6))
                        }
                        .buttonStyle(AndonTactileScaleButtonStyle(pressedScale: 0.96))
                    }
                }
                .padding(3)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: AndRadius.pill, style: .continuous))
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
        .onChange(of: discovery.detectedPairingHost) { _, newHost in
            if let host = newHost, !host.isEmpty {
                if pairedIP.isEmpty || pairedIP.hasSuffix(".") {
                    pairedIP = host
                }
                if let port = discovery.detectedPairingPort {
                    if addressAndPort.isEmpty || addressAndPort.hasSuffix(".") || addressAndPort.hasSuffix(":") {
                        addressAndPort = "\(host):\(port)"
                    }
                }
            }
        }
        .onChange(of: discovery.detectedConnectHost) { _, newHost in
            if let host = newHost, !host.isEmpty {
                if pairedIP.isEmpty || pairedIP.hasSuffix(".") {
                    pairedIP = host
                }
                if addressAndPort.isEmpty || addressAndPort.hasSuffix(".") {
                    addressAndPort = "\(host):"
                }
            }
        }
        .onChange(of: appState.lastKnownWifiIP) { _, newIP in
            if let host = newIP, !host.isEmpty {
                if pairedIP.isEmpty || pairedIP.hasSuffix(".") {
                    pairedIP = host
                }
                if addressAndPort.isEmpty || addressAndPort.hasSuffix(".") {
                    addressAndPort = "\(host):"
                }
            }
        }
        .onChange(of: discovery.detectedConnectPort) { _, newPort in
            if let port = newPort {
                if pairedPort.isEmpty || pairedPort == "5555" {
                    pairedPort = String(port)
                }
                if connectPortText.isEmpty {
                    connectPortText = String(port)
                }
            }
        }
    }
    
    // MARK: - Current Effective Host & Port
    private var currentPairingHostAndPort: String {
        if let host = discovery.detectedPairingHost, let port = discovery.detectedPairingPort, !showManualInputs {
            return "\(host):\(port)"
        }
        return addressAndPort.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - Tab 1: Wi-Fi PIN Code & Direct Connect
    private var wifiPinTab: some View {
        VStack(spacing: 14) {
            routerIsolationBanner
            autoDetectedBanner
            qrPairingCard
            alreadyPairedCard
            firstTimePairingDisclosure
        }
    }

    @ViewBuilder
    private var routerIsolationBanner: some View {
        if routerBypass.isRouterIsolationDetected {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "wifi.exclamationmark")
                        .foregroundColor(.orange)
                    Text(L10n.tr("Изоляция роутера — переключитесь на прямой канал", "Router Isolation Detected — Switch to Direct Link", lang: appState.lang))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                }
                HStack(spacing: 8) {
                    Button {
                        Task {
                            let (ok, msg) = await routerBypass.connectDirectHotspot()
                            isSuccess = ok
                            resultMessage = ok ? "Direct Hotspot: \(msg)" : msg
                            if ok { appState.refreshDevices() }
                        }
                    } label: {
                        Text(L10n.tr("Режим Hotspot", "Direct Hotspot", lang: appState.lang))
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.orange)
                            .foregroundColor(.black)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)

                    Button {
                        Task {
                            let (ok, msg) = await routerBypass.connectBluetoothPAN()
                            isSuccess = ok
                            resultMessage = ok ? "Bluetooth PAN: \(msg)" : msg
                            if ok { appState.refreshDevices() }
                        }
                    } label: {
                        Text("Bluetooth PAN")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.14))
                            .foregroundColor(.white)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(Color.orange.opacity(0.14))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.orange.opacity(0.35), lineWidth: 1)
            )
        }
    }

    private var qrPairingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(L10n.tr("Быстрое сопряжение по QR-коду", "QR Code Wireless Pairing", lang: appState.lang), systemImage: "qrcode")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button(qrPairing.status == .idle ? L10n.tr("Показать QR", "Show QR", lang: appState.lang) : L10n.tr("Скрыть", "Hide", lang: appState.lang)) {
                    if qrPairing.status == .idle {
                        qrPairing.onPairedSuccessfully = { _ in
                            Task { @MainActor in
                                appState.refreshDevices()
                            }
                        }
                        qrPairing.startSession()
                    } else {
                        qrPairing.stopSession()
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.cyan)
            }
            if qrPairing.status != .idle, !qrPairing.qrPayload.isEmpty {
                HStack(spacing: 10) {
                    QRCodeView(payload: qrPairing.qrPayload, size: 96)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.tr("На телефоне: Отладка по Wi-Fi → Подключить по QR-коду", "On Android: Wireless Debugging → Pair with QR code", lang: appState.lang))
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.75))
                        Text(qrPairing.serviceName)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.cyan)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.05))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
    
    @ViewBuilder
    private var autoDetectedBanner: some View {
        let candidateHost = discovery.detectedPairingHost ?? discovery.detectedConnectHost ?? appState.lastKnownWifiIP
        let detectedPort = discovery.detectedConnectPort ?? discovery.detectedPairingPort
        if let host = candidateHost, !host.isEmpty, !host.hasSuffix("."), let port = detectedPort, !showManualInputs {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(Color.green.opacity(0.5), lineWidth: 3))
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Обнаружен телефон в локальной сети")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                        Text("\(discovery.detectedDeviceName ?? "Android") • \(host):\(port)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.cyan)
                    }
                    
                    Spacer()
                    
                    Button {
                        connectDirect(ip: host, portStr: String(port))
                    } label: {
                        Text("Подключить")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.green)
                            .foregroundColor(.black)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(Color.green.opacity(0.12))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.green.opacity(0.3), lineWidth: 1)
            )
        }
    }
    
    private var isDirectConnectDisabled: Bool {
        pairedIP.isEmpty || pairedPort.isEmpty || isProcessing
    }
    
    private var isPairingDisabled: Bool {
        currentPairingHostAndPort.isEmpty || pinCode.count < 6 || isProcessing
    }
    
    private var alreadyPairedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            alreadyPairedHeader
            alreadyPairedInputs
            alreadyPairedButton
        }
        .padding(12)
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
    
    private var alreadyPairedHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(.cyan)
                    .font(.system(size: 13))
                Text("Устройство уже сопряжено")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
            }
            Text("Если в меню телефона «Беспроводная отладка» уже видно «MacBook Pro», просто введите порт из верхней строки телефона:")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.7))
                .lineSpacing(1.5)
        }
    }
    
    private var alreadyPairedInputs: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("IP-АДРЕС")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white.opacity(0.45))
                TextField("10.36.xxx.xxx", text: $pairedIP)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .focused($focusedField, equals: .pairedIP)
                    .padding(7)
                    .background(Color.white.opacity(0.07))
                    .cornerRadius(8)
            }
            .frame(maxWidth: .infinity)
            
            VStack(alignment: .leading, spacing: 3) {
                Text("ПОРТ")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white.opacity(0.45))
                TextField("38195 или 5555", text: $pairedPort)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .focused($focusedField, equals: .pairedPort)
                    .padding(7)
                    .background(Color.white.opacity(0.07))
                    .cornerRadius(8)
            }
            .frame(width: 100)
        }
    }
    
    private var alreadyPairedButton: some View {
        Button {
            connectDirect(ip: pairedIP, portStr: pairedPort)
        } label: {
            HStack(spacing: 6) {
                if isProcessing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "bolt.fill")
                    Text("Подключить телефон")
                        .font(.system(size: 11, weight: .bold))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .disabled(isDirectConnectDisabled)
        .opacity(isDirectConnectDisabled ? 0.45 : 1.0)
    }
    
    private var firstTimePairingDisclosure: some View {
        DisclosureGroup(
            isExpanded: $showFirstTimePairing,
            content: {
                firstTimePairingContent
            },
            label: {
                HStack(spacing: 6) {
                    Image(systemName: "key")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))
                    Text("Первое сопряжение по 6-значному коду")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.8))
                    Spacer()
                }
            }
        )
        .padding(10)
        .background(Color.white.opacity(0.03))
        .cornerRadius(10)
    }
    
    private var firstTimePairingContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Где открыть на телефоне:")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                Text("Настройки → Для разработчиков → Беспроводная отладка → **«Подключить с помощью кода сопряжения»**.")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.7))
            }
            
            VStack(alignment: .leading, spacing: 3) {
                Text("IP-АДРЕС И ПОРТ СОПРЯЖЕНИЯ")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white.opacity(0.45))
                TextField("например: 10.36.201.171:41893", text: $addressAndPort)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .focused($focusedField, equals: .addressPort)
                    .padding(7)
                    .background(Color.white.opacity(0.07))
                    .cornerRadius(8)
            }
            
            VStack(alignment: .leading, spacing: 3) {
                Text("6-ЗНАЧНЫЙ КОД СОПРЯЖЕНИЯ")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white.opacity(0.45))
                TextField("123456", text: $pinCode)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .focused($focusedField, equals: .pinCode)
                    .padding(7)
                    .background(Color.white.opacity(0.07))
                    .cornerRadius(8)
                    .onChange(of: pinCode) { _, newValue in
                        let filtered = String(newValue.filter { $0.isNumber }.prefix(6))
                        if filtered != newValue {
                            pinCode = filtered
                        }
                    }
            }
            
            VStack(alignment: .leading, spacing: 3) {
                Text("ПОРТ ПОДКЛЮЧЕНИЯ ИЗ ГЛАВНОГО ЭКРАНА (ОПЦИОНАЛЬНО)")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white.opacity(0.45))
                TextField("например: 39787", text: $connectPortText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .focused($focusedField, equals: .connectPort)
                    .padding(7)
                    .background(Color.white.opacity(0.07))
                    .cornerRadius(8)
            }
            
            Button {
                submitPairing()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "key.fill")
                    Text("Выполнить сопряжение")
                        .font(.system(size: 11, weight: .bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.12))
                .foregroundColor(.white)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .disabled(isPairingDisabled)
        }
        .padding(.top, 8)
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
                        let dynamicPort = DiscoveryService.shared.getConnectPort(for: known.ipAddress)
                        let effectivePort = dynamicPort ?? known.port
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(known.name)
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.white)
                                HStack(spacing: 4) {
                                    Text("\(known.ipAddress):\(String(effectivePort))")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.5))
                                    if dynamicPort != nil {
                                        Text("• активен")
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundColor(.green)
                                    }
                                }
                            }
                            
                            Spacer()
                            
                            Button {
                                Task {
                                    isProcessing = true
                                    let portToUse = DiscoveryService.shared.getConnectPort(for: known.ipAddress) ?? known.port
                                    let success = await appState.connectWireless(host: known.ipAddress, port: portToUse)
                                    isProcessing = false
                                    if success {
                                        isSuccess = true
                                        resultMessage = "Подключено к \(known.name)!"
                                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                                        closePairing()
                                    } else {
                                        isSuccess = false
                                        resultMessage = "Не удалось подключиться к \(known.ipAddress):\(portToUse)"
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
        if pairedIP.isEmpty || pairedIP.hasSuffix(".") {
            if let host = discovery.detectedPairingHost ?? discovery.detectedConnectHost, !host.isEmpty {
                pairedIP = host
            } else if let last = appState.lastKnownWifiIP, !last.isEmpty {
                pairedIP = last
            } else if let saved = appState.knownDevices.first?.ipAddress, !saved.isEmpty {
                pairedIP = saved
            } else if pairedIP.isEmpty {
                let netInfo = ADBService.shared.getMacNetworkInfo()
                if netInfo.ip != "127.0.0.1" {
                    pairedIP = netInfo.prefix
                }
            }
        }
        
        if pairedPort.isEmpty || pairedPort == "5555" {
            if let p = discovery.detectedConnectPort {
                pairedPort = String(p)
            } else if let devPort = appState.selectedDevice?.wirelessPort {
                pairedPort = String(devPort)
            } else if let savedPort = appState.knownDevices.first?.port, savedPort != 5555 {
                pairedPort = String(savedPort)
            } else if pairedPort.isEmpty {
                pairedPort = "5555"
            }
        }
        
        if connectPortText.isEmpty {
            if let p = discovery.detectedConnectPort ?? appState.selectedDevice?.wirelessPort {
                connectPortText = String(p)
            }
        }
        
        if addressAndPort.isEmpty || addressAndPort.hasSuffix(".") {
            if let host = discovery.detectedPairingHost, let port = discovery.detectedPairingPort {
                addressAndPort = "\(host):\(port)"
            } else if let host = discovery.detectedConnectHost ?? appState.lastKnownWifiIP, !host.isEmpty {
                addressAndPort = "\(host):"
            } else if addressAndPort.isEmpty {
                let netInfo = ADBService.shared.getMacNetworkInfo()
                if netInfo.ip != "127.0.0.1" {
                    self.addressAndPort = netInfo.prefix
                }
            }
        }
    }
    
    private func connectDirect(ip: String, portStr: String) {
        let cleanIP = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPort = portStr.trimmingCharacters(in: .whitespacesAndNewlines)
        let octets = cleanIP.components(separatedBy: ".")
        guard !cleanIP.isEmpty, octets.count == 4, octets.allSatisfy({ !$0.isEmpty && Int($0) != nil }) else {
            resultMessage = "Введите полный IP-адрес телефона (например, 10.36.201.171)"
            isSuccess = false
            return
        }
        guard let port = Int(cleanPort), (1...65535).contains(port) else {
            resultMessage = "Укажите корректный порт (например, 38195 или 5555)"
            isSuccess = false
            return
        }
        
        isProcessing = true
        resultMessage = "Подключение к \(cleanIP):\(port)..."
        
        Task { @MainActor in
            let (success, message) = await appState.connectPaired(host: cleanIP, port: port)
            isProcessing = false
            isSuccess = success
            resultMessage = message
            if success {
                appState.refreshDevices()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    closePairing()
                }
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
        
        Task { @MainActor in
            do {
                let (success, message) = try await ADBService.shared.pairAndConnect(
                    host: host,
                    pairingPort: pairingPort,
                    code: pinCode,
                    userConnectPort: userConnectPort
                )
                
                isProcessing = false
                isSuccess = success
                resultMessage = message
                
                if success {
                    discovery.resetPairingState()
                    appState.refreshDevices()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        closePairing()
                    }
                } else if message.contains("Сопряжение выполнено") {
                    pairedIP = host
                    discovery.resetPairingState()
                    focusedField = .pairedPort
                }
            } catch {
                isProcessing = false
                isSuccess = false
                resultMessage = "Ошибка сопряжения: \(error.localizedDescription)"
            }
        }
    }
}
