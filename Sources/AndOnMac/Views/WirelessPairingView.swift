import SwiftUI

public struct WirelessPairingView: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    
    @State private var ipAddress: String = ""
    @State private var portString: String = ""
    @State private var pairingCode: String = ""
    @State private var isProcessing: Bool = false
    @State private var resultMessage: String?
    
    public init(appState: AppState) {
        self.appState = appState
    }
    
    public var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Image(systemName: "wifi.badge.plus")
                    .font(.title)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading) {
                    Text("Беспроводное сопряжение (Wi-Fi)")
                        .font(.headline)
                    Text("Для Google Pixel и устройств на Android 11+")
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
            
            Divider()
            
            // Instructions
            VStack(alignment: .leading, spacing: 8) {
                Text("Как подключить:")
                    .font(.subheadline.bold())
                Text("1. Откройте на телефоне: **Настройки → Для разработчиков → Беспроводная отладка**.")
                    .font(.caption)
                Text("2. Включите переключатель и нажмите **«Подключить с помощью кода сопряжения»**.")
                    .font(.caption)
                Text("3. Введите IP, порт сопряжения и 6-значный код ниже:")
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(8)
            
            // Inputs
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    TextField("IP-адрес (напр. 192.168.1.45)", text: $ipAddress)
                        .textFieldStyle(.roundedBorder)
                    
                    TextField("Порт", text: $portString)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
                
                TextField("6-значный код сопряжения", text: $pairingCode)
                    .textFieldStyle(.roundedBorder)
            }
            
            if let result = resultMessage {
                Text(result)
                    .font(.caption)
                    .foregroundColor(result.contains("успешно") || result.contains("success") ? .green : .red)
            }
            
            Spacer()
            
            // Action Buttons
            HStack {
                Button("Отмена") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button {
                    submitPairing()
                } label: {
                    if isProcessing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Сопрячь и подключить")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(ipAddress.isEmpty || portString.isEmpty || pairingCode.isEmpty || isProcessing)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480, height: 420)
    }
    
    private func submitPairing() {
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
                resultMessage = "Сопряжение прошло успешно!"
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                dismiss()
            } else {
                resultMessage = appState.statusMessage
            }
        }
    }
}
