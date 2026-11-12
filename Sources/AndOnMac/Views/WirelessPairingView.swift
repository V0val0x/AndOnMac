import SwiftUI

public enum PairingTab: String, CaseIterable, Identifiable {
    case cameraQR = "Камера (QR)"
    case usbSetup = "Кабель за 3 сек"
    case devCode = "Код из настроек"
    
    public var id: String { rawValue }
}

public struct WirelessPairingView: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    
    @State private var selectedTab: PairingTab = .cameraQR
    
    // Auto-discovery state
    @State private var discoveredServices: [DiscoveredService] = []
    @State private var selectedService: DiscoveredService?
    @State private var autoPairingCode: String = ""
    
    // Manual State
    @State private var ipAddress: String = ""
    @State private var portString: String = ""
    @State private var pairingCode: String = ""
    
    @State private var isProcessing: Bool = false
    @State private var resultMessage: String?
    
    public init(appState: AppState) {
        self.appState = appState
    }
    
    private var macLocalIP: String {
        ADBService.shared.getMacLocalIP()
    }
    
    private var qrPayload: String {
        "http://\(macLocalIP):58241"
    }
    
    public var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: "wifi.badge.plus")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Быстрое подключение")
                        .font(.headline)
                    Text("Выберите самый удобный способ")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            
            // Picker
            Picker("", selection: $selectedTab) {
                ForEach(PairingTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            
            Divider()
            
            // Tab Contents
            switch selectedTab {
            case .cameraQR:
                cameraQRTab
            case .usbSetup:
                usbSetupTab
            case .devCode:
                devCodeTab
            }
            
            if let result = resultMessage {
                Text(result)
                    .font(.caption.bold())
                    .foregroundColor(result.contains("успешно") || result.contains("success") || result.contains("Готово") ? .green : .red)
                    .padding(.top, 4)
            }
            
            Spacer()
            
            // Bottom Bar
            HStack {
                Button("Закрыть") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                if selectedTab == .devCode {
                    Button {
                        submitDevCodePairing()
                    } label: {
                        if isProcessing {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Подключить по коду")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(pairingCode.isEmpty || isProcessing)
                }
            }
        }
        .padding(24)
        .frame(width: 520, height: 500)
        .onAppear {
            scanForDevices()
        }
    }
    
    // MARK: - Tab 1: Standard Camera QR Code (No Developer Settings Needed!)
    private var cameraQRTab: some View {
        VStack(spacing: 14) {
            QRCodeView(payload: qrPayload, size: 180)
            
            VStack(spacing: 6) {
                Text("Сканируйте обычной камерой смартфона:")
                    .font(.subheadline.bold())
                Text("1. Откройте **стандартную камеру** на телефоне (не нужно заходить в настройки!).")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("2. Наведите камеру на QR-код и нажмите появившуюся желтую ссылку.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("3. Mac мгновенно определит ваш телефон и включит трансляцию экрана.")
                    .font(.caption.bold())
                    .foregroundColor(.accentColor)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
        }
    }
    
    // MARK: - Tab 2: USB One-Time Setup (Zero-Touch Future)
    private var usbSetupTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 50, height: 50)
                    Image(systemName: "cable.connector")
                        .font(.title2)
                        .foregroundColor(.accentColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Подключение кабелем за 3 секунды")
                        .font(.headline)
                    Text("Кабель нужен всего один раз — дальше работает по воздуху!")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Text("1.")
                        .font(.headline)
                        .foregroundColor(.accentColor)
                    Text("Подключите телефон к Mac комплектным кабелем на пару секунд.")
                        .font(.subheadline)
                }
                HStack(alignment: .top, spacing: 10) {
                    Text("2.")
                        .font(.headline)
                        .foregroundColor(.accentColor)
                    Text("AndOnMac сам активирует беспроводной режим и сохранит ваш телефон.")
                        .font(.subheadline)
                }
                HStack(alignment: .top, spacing: 10) {
                    Text("3.")
                        .font(.headline)
                        .foregroundColor(.accentColor)
                    Text("Отсоедините кабель. Теперь телефон будет подключаться **полностью автоматически** при нахождении в одной Wi-Fi сети.")
                        .font(.subheadline.bold())
                        .foregroundColor(.green)
                }
            }
            .padding(16)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(12)
        }
        .padding(.top, 10)
    }
    
    // MARK: - Tab 3: Developer Settings 6-digit PIN
    private var devCodeTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Беспроводная отладка Android (ADB PIN)")
                .font(.subheadline.bold())
            
            Text("Если вы включили «Беспроводную отладку» в телефоне, выберите телефон из списка и введите 6-значный код (таймаут 6 сек, без зависаний):")
                .font(.caption)
                .foregroundColor(.secondary)
            
            if discoveredServices.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Поиск устройств в Wi-Fi сети...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(10)
            } else {
                List(discoveredServices, selection: $selectedService) { service in
                    HStack {
                        Image(systemName: "smartphone")
                            .foregroundColor(.accentColor)
                        Text(service.name)
                            .font(.subheadline.bold())
                        Spacer()
                        Text("\(service.host):\(service.port)")
                            .font(.caption2.monospaced())
                            .foregroundColor(.secondary)
                    }
                    .tag(service)
                }
                .frame(height: 80)
            }
            
            HStack(spacing: 10) {
                TextField("IP (если не найден)", text: $ipAddress)
                    .textFieldStyle(.roundedBorder)
                TextField("Порт", text: $portString)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }
            
            TextField("6-значный код сопряжения", text: $pairingCode)
                .textFieldStyle(.roundedBorder)
        }
    }
    
    private func scanForDevices() {
        Task {
            let found = await DiscoveryService.shared.discoverServices()
            await MainActor.run {
                self.discoveredServices = found
                if selectedService == nil {
                    self.selectedService = found.first
                    if let first = found.first {
                        self.ipAddress = first.host
                        self.portString = String(first.port)
                    }
                }
            }
        }
    }
    
    private func submitDevCodePairing() {
        let host = selectedService?.host ?? ipAddress
        let port = selectedService?.port ?? Int(portString) ?? 0
        guard !host.isEmpty, port > 0 else {
            resultMessage = "Укажите корректный IP и порт"
            return
        }
        
        isProcessing = true
        resultMessage = nil
        
        Task {
            let success = await appState.pairDevice(host: host, port: port, code: pairingCode)
            isProcessing = false
            if success {
                resultMessage = "Успешно подключено!"
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                dismiss()
            } else {
                resultMessage = appState.statusMessage
            }
        }
    }
}
