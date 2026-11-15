import Foundation
import Network
import Combine

/// Manages native Android 11+ QR-code Wireless Debugging pairing via `NWListener` + Bonjour `_adb-tls-pairing._tcp`.
@MainActor
public final class QRPairingService: ObservableObject {
    public static let shared = QRPairingService()

    public enum PairingStatus: Equatable, Sendable {
        case idle
        case listening
        case pairing(String)
        case paired(String)
        case failed(String)
    }

    @Published public private(set) var serviceName: String = ""
    @Published public private(set) var pairingPassword: String = ""
    @Published public private(set) var qrPayload: String = ""
    @Published public private(set) var status: PairingStatus = .idle

    private var listener: NWListener?
    private var pollTask: Task<Void, Never>?
    private var isPairingInFlight = false
    public var onPairedSuccessfully: (@Sendable (String) -> Void)?

    private init() {}

    /// Builds the Android 11+ Wireless Debugging QR payload: `WIFI:T:ADB;S:<service_name>;P:<password>;;`.
    public nonisolated static func buildQRPayload(serviceName: String, password: String) -> String {
        "WIFI:T:ADB;S:\(serviceName);P:\(password);;"
    }

    /// Generates a fresh session ID + password, broadcasts `_adb-tls-pairing._tcp` via `NWListener`,
    /// and watches for the Android device to complete QR pairing.
    public func startSession() {
        stopSession()

        let randomId = String(format: "%08X", UInt32.random(in: 0x10000000...0xFFFFFFFF))
        let name = "ADB_WIFI_\(randomId)"
        let pwd = Self.generatePassword(length: 8)

        self.serviceName = name
        self.pairingPassword = pwd
        self.qrPayload = Self.buildQRPayload(serviceName: name, password: pwd)
        self.status = .listening
        self.isPairingInFlight = false

        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let nwListener = try NWListener(using: params)
            nwListener.service = NWListener.Service(name: name, type: "_adb-tls-pairing._tcp")

            nwListener.stateUpdateHandler = { [weak self] newState in
                Task { @MainActor in
                    guard let self = self else { return }
                    switch newState {
                    case .ready:
                        if case .idle = self.status {
                            self.status = .listening
                        }
                    case .failed(let error):
                        self.status = .failed(error.localizedDescription)
                    default:
                        break
                    }
                }
            }

            nwListener.newConnectionHandler = { [weak self] connection in
                let endpoint = connection.endpoint
                connection.cancel()
                Task { @MainActor in
                    self?.handleIncomingPairingHint(from: endpoint)
                }
            }

            nwListener.start(queue: DispatchQueue(label: "com.andonmac.qrpairing", qos: .userInitiated))
            self.listener = nwListener
        } catch {
            self.status = .failed(error.localizedDescription)
        }

        // Poll `adb mdns services` and `DiscoveryService` for the device's pairing announcement
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard let self = self, !Task.isCancelled else { break }
                await self.checkDiscoveredPairingServices()
            }
        }
    }

    public func stopSession() {
        pollTask?.cancel()
        pollTask = nil
        listener?.cancel()
        listener = nil
        isPairingInFlight = false
        status = .idle
    }

    private func handleIncomingPairingHint(from endpoint: NWEndpoint) {
        if case .hostPort(let host, let port) = endpoint {
            let hostStr = Self.cleanHostString("\(host)")
            let portInt = Int(port.rawValue)
            if !hostStr.isEmpty && portInt > 0 {
                Task {
                    await attemptPairAndConnect(host: hostStr, pairingPort: portInt)
                }
                return
            }
        }
        Task {
            await checkDiscoveredPairingServices()
        }
    }

    private func checkDiscoveredPairingServices() async {
        guard !isPairingInFlight else { return }
        if let host = DiscoveryService.shared.detectedPairingHost,
           let port = DiscoveryService.shared.detectedPairingPort,
           let detectedName = DiscoveryService.shared.detectedDeviceName,
           detectedName == serviceName || detectedName.hasPrefix("ADB_WIFI_") {
            await attemptPairAndConnect(host: host, pairingPort: port)
        }
    }

    private func attemptPairAndConnect(host: String, pairingPort: Int) async {
        guard !isPairingInFlight, !pairingPassword.isEmpty else { return }
        isPairingInFlight = true
        status = .pairing("\(host):\(pairingPort)")

        do {
            let pairOutput = try await ADBService.shared.pairDevice(host: host, port: pairingPort, code: pairingPassword)
            if pairOutput.lowercased().contains("successfully paired") || pairOutput.lowercased().contains("paired") {
                await DiscoveryService.shared.pollAdbMdns()
                let connectPort = DiscoveryService.shared.getConnectPort(for: host) ?? 5555
                _ = try? await ADBService.shared.connectPairedDevice(host: host, port: connectPort)
                status = .paired("\(host):\(connectPort)")
                DiscoveryService.shared.resetPairingState()
                onPairedSuccessfully?("\(host):\(connectPort)")
                stopListenerOnly()
            } else {
                isPairingInFlight = false
                status = .failed(pairOutput.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        } catch {
            isPairingInFlight = false
            status = .failed(error.localizedDescription)
        }
    }

    private func stopListenerOnly() {
        pollTask?.cancel()
        pollTask = nil
        listener?.cancel()
        listener = nil
    }

    private nonisolated static func generatePassword(length: Int) -> String {
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<length).map { _ in chars.randomElement() ?? "A" })
    }

    private nonisolated static func cleanHostString(_ raw: String) -> String {
        let stripped = raw.split(separator: "%").first.map(String.init) ?? raw
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
