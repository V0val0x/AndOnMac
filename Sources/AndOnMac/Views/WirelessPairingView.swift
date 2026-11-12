import SwiftUI

public enum PairingTab: String, CaseIterable, Identifiable {
    case qrCode = "QR-код (Беспроводной)"
    case pinCode = "Код из 6 цифр"
    case usbSetup = "Кабель за 3 сек"
    
    public var id: String { rawValue }
}

public struct WirelessPairingView: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    
    @State private var selectedTab: PairingTab = .qrCode
    
    // QR Code Credentials
    @State private var qrPassword: String = String(Int.random(in: 100000...999999))
    @State private var isListeningForQR: Bool = false
    @State private var pairingStatus: String = "Ожидание сканирования телефоном..."
    
    // Auto-discovery / PIN Code State
    @State private var discoveredServices: [DiscoveredService] = []
    @State private var selectedService: DiscoveredService?
    @State private var autoPairingCode: String = ""
    @State private var isProcessingPIN: Bool = false
    
    @State private var resultMessage: String?
    
    public init(appState: AppState) {
        self.appState = appState
    }
    
    private var qrPayload: String {
        "WIFI:T:ADB;S:AndOnMac;P:\(qrPassword);;"
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
                    Text("Подключение телефона без проводов по Wi-Fi")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    DiscoveryService.shared.stopQRPairingWatcher()
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
            .onChange(of: selectedTab) { _, newTab in
                if newTab == .qrCode {
                    startWatcher()
                } else {
                    DiscoveryService.shared.stopQRPairingWatcher()
                }
            }
            
            Divider()
            
            // Tab Contents
            switch selectedTab {
            case .qrCode:
                qrCodeTab
            case .pinCode:
                pinCodeTab
            case .usbSetup:
                usbSetupTab
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
                Button("Закрыть") {
                    DiscoveryService.shared.stopQRPairingWatcher()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                if selectedTab == .pinCode {
                    Button {
                        submitPINPairing()
                    } label: {
                        if isProcessingPIN {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Подключить по коду")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(autoPairingCode.isEmpty || isProcessingPIN)
                }
            }
        }
        .padding(24)
        .frame(width: 530, height: 520)
        .onAppear {
            startWatcher()
            scanForServices()
        }
        .onDisappear {
            DiscoveryService.shared.stopQRPairingWatcher()
        }
    }
    
    // MARK: - Tab 1: Official Android Wireless Debugging QR
    private var qrCodeTab: some View {
        VStack(spacing: 12) {
            QRCodeView(payload: qrPayload, size: 180)
            
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(pairingStatus)
                    .font(.caption.bold())
                    .foregroundColor(.accentColor)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text("Как подключить через QR:")
                    .font(.subheadline.bold())
                Text("1. В телефоне откройте: **Настройки → Для разработчиков → Беспроводная отладка**.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("2. Нажмите **«Подключить с помощью QR-кода»**.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("3. Наведите открывшийся сканер на этот QR-код на экране Mac.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Mac автоматически поймает сигнал телефона, подтвердит пароль и запустит зеркало.")
                    .font(.caption.bold())
                    .foregroundColor(.green)
            }
            .padding(12)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(10)
        }
    }
    
    // MARK: - Tab 2: 6-digit PIN code
    private var pinCodeTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Сопряжение по 6-значному коду")
                .font(.subheadline.bold())
            
            Text("В телефоне нажмите: *Беспроводная отладка → «Подключить с помощью кода сопряжения»*.")
                .font(.caption)
                .foregroundColor(.secondary)
            
            if discoveredServices.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Поиск устройств в локальной Wi-Fi сети...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.06))
                .cornerRadius(8)
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
                .frame(height: 90)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text("Введите 6-значный код с экрана телефона:")
                    .font(.caption.bold())
                TextField("Например, 842109", text: $autoPairingCode)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
    
    // MARK: - Tab 3: USB Setup
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
                    Text("Кабель нужен только один раз для первой привязки")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Text("1.")
                        .font(.subheadline.bold())
                        .foregroundColor(.accentColor)
                    Text("Подключите телефон кабелем Type-C к Mac.")
                        .font(.subheadline)
                }
                HStack(alignment: .top, spacing: 8) {
                    Text("2.")
                        .font(.subheadline.bold())
                        .foregroundColor(.accentColor)
                    Text("Нажмите «Разрешить» на экране телефона.")
                        .font(.subheadline)
                }
                HStack(alignment: .top, spacing: 8) {
                    Text("3.")
                        .font(.subheadline.bold())
                        .foregroundColor(.accentColor)
                    Text("Mac автоматически сохранит телефон и переведет его в режим Wi-Fi. Кабель можно отключить.")
                        .font(.subheadline.bold())
                        .foregroundColor(.green)
                }
            }
            .padding(14)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(12)
        }
        .padding(.top, 10)
    }
    
    private func startWatcher() {
        DiscoveryService.shared.startQRPairingWatcher(password: qrPassword) { host in
            Task { @MainActor in
                pairingStatus = "Телефон найден (\(host)), подтверждаем сопряжение..."
            }
        } onPaired: { host in
            Task { @MainActor in
                pairingStatus = "✅ Успешно сопряжено с \(host)!"
                resultMessage = "Успешно сопряжено! Запуск трансляции..."
                appState.refreshDevices()
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                dismiss()
            }
        }
    }
    
    private func scanForServices() {
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
    
    private func submitPINPairing() {
        guard let service = selectedService ?? discoveredServices.first else {
            resultMessage = "Устройство не выбрано"
            return
        }
        
        isProcessingPIN = true
        resultMessage = nil
        
        Task {
            let success = await appState.pairDevice(host: service.host, port: service.port, code: autoPairingCode)
            isProcessingPIN = false
            if success {
                resultMessage = "Успешно сопряжено!"
                appState.refreshDevices()
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                dismiss()
            } else {
                resultMessage = appState.statusMessage
            }
        }
    }
}
