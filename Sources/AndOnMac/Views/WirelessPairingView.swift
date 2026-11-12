import SwiftUI

public enum PairingTab: String, CaseIterable, Identifiable {
    case qrCode = "QR-код"
    case autoDiscovery = "Автопоиск в сети"
    case manual = "Ввод IP вручную"
    
    public var id: String { rawValue }
}

public struct WirelessPairingView: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    
    @State private var selectedTab: PairingTab = .qrCode
    
    // QR Code State
    @State private var qrServiceName: String = "AndOnMac-\(Int.random(in: 1000...9999))"
    @State private var qrPassword: String = String(Int.random(in: 100000...999999))
    
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
    
    private var qrPayload: String {
        "WIFI:T:ADB;S:\(qrServiceName);P:\(qrPassword);;"
    }
    
    public var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: "wifi.badge.plus")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Беспроводное сопряжение")
                        .font(.headline)
                    Text("Подключение телефона без кабелей по Wi-Fi")
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
            case .qrCode:
                qrCodeTab
            case .autoDiscovery:
                autoDiscoveryTab
            case .manual:
                manualTab
            }
            
            if let result = resultMessage {
                Text(result)
                    .font(.caption.bold())
                    .foregroundColor(result.contains("успешно") || result.contains("success") ? .green : .red)
                    .padding(.top, 4)
            }
            
            Spacer()
            
            // Bottom Bar
            HStack {
                Button("Отмена") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                if selectedTab == .manual {
                    Button {
                        submitManualPairing()
                    } label: {
                        if isProcessing {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Сопрячь")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(ipAddress.isEmpty || portString.isEmpty || pairingCode.isEmpty || isProcessing)
                } else if selectedTab == .autoDiscovery {
                    Button {
                        submitAutoPairing()
                    } label: {
                        if isProcessing {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Подключить выбранное")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedService == nil || autoPairingCode.isEmpty || isProcessing)
                }
            }
        }
        .padding(24)
        .frame(width: 520, height: 500)
        .onAppear {
            scanForDevices()
        }
    }
    
    // MARK: - Tab 1: QR Code
    private var qrCodeTab: some View {
        VStack(spacing: 14) {
            QRCodeView(payload: qrPayload, size: 180)
            
            VStack(spacing: 6) {
                Text("Как подключить через QR:")
                    .font(.subheadline.bold())
                Text("1. Откройте на телефоне: **Настройки → Для разработчиков → Беспроводная отладка**.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("2. Нажмите **«Подключить с помощью QR-кода»** и наведите камеру на экран Mac.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("3. Готово! Телефон сразу спарится и запомнит этот Mac навсегда.")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
        }
    }
    
    // MARK: - Tab 2: Auto Discovery (No IP typing)
    private var autoDiscoveryTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Устройства в локальной Wi-Fi сети:")
                    .font(.subheadline.bold())
                Spacer()
                Button {
                    scanForDevices()
                } label: {
                    Label("Обновить", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
            
            if discoveredServices.isEmpty {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Поиск Android-устройств в сети...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Убедитесь, что на телефоне открыт экран «Беспроводная отладка».")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
                .background(Color.secondary.opacity(0.06))
                .cornerRadius(10)
            } else {
                List(discoveredServices, selection: $selectedService) { service in
                    HStack {
                        Image(systemName: "smartphone")
                            .foregroundColor(.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(service.name)
                                .font(.subheadline.bold())
                            Text("\(service.host):\(service.port)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(service.type == .pairing ? "Готов к коду" : "Готов к подключению")
                            .font(.caption2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.green.opacity(0.15))
                            .foregroundColor(.green)
                            .cornerRadius(6)
                    }
                    .tag(service)
                }
                .frame(height: 120)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text("Введите 6-значный код сопряжения с экрана телефона:")
                    .font(.caption.bold())
                TextField("Например, 849201", text: $autoPairingCode)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
    
    // MARK: - Tab 3: Manual Input
    private var manualTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ручной ввод адреса и порта")
                .font(.subheadline.bold())
            
            HStack(spacing: 10) {
                TextField("IP-адрес телефона", text: $ipAddress)
                    .textFieldStyle(.roundedBorder)
                TextField("Порт", text: $portString)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }
            
            TextField("6-значный код", text: $pairingCode)
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
                }
            }
        }
    }
    
    private func submitAutoPairing() {
        guard let service = selectedService else { return }
        isProcessing = true
        resultMessage = nil
        
        Task {
            let success = await appState.pairDevice(host: service.host, port: service.port, code: autoPairingCode)
            isProcessing = false
            if success {
                resultMessage = "Устройство успешно подключено!"
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                dismiss()
            } else {
                resultMessage = appState.statusMessage
            }
        }
    }
    
    private func submitManualPairing() {
        guard let port = Int(portString) else {
            resultMessage = "Некорректный порт"
            return
        }
        isProcessing = true
        resultMessage = nil
        
        Task {
            let success = await appState.pairDevice(host: ipAddress, port: port, code: pairingCode)
            isProcessing = false
            if success {
                resultMessage = "Успешно сопряжено!"
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                dismiss()
            } else {
                resultMessage = appState.statusMessage
            }
        }
    }
}
