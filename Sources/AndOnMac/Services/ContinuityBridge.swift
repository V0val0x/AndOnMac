import Foundation
import AppKit

/// Background Apple Continuity Bridge syncing Mac text and images/screenshots to Android even when mirroring is closed.
public final class ContinuityBridge: @unchecked Sendable {
    public static let shared = ContinuityBridge()

    private var timer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private var lastSyncedText: String = ""
    private var activeSerialProvider: (@MainActor @Sendable () -> String?)?
    private var isEnabled: Bool = false

    public var onSyncEvent: (@Sendable (String) -> Void)?

    private init() {}

    /// Starts background pasteboard monitoring on the main run loop.
    public func start(serialProvider: @escaping @MainActor @Sendable () -> String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.activeSerialProvider = serialProvider
            self.isEnabled = true
            self.lastChangeCount = NSPasteboard.general.changeCount
            self.timer?.invalidate()
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.pollPasteboard()
                }
            }
        }
    }

    /// Stops background pasteboard monitoring.
    public func stop() {
        DispatchQueue.main.async { [weak self] in
            self?.isEnabled = false
            self?.timer?.invalidate()
            self?.timer = nil
        }
    }

    /// Converts raw pasteboard image data (PNG or TIFF) into PNG `Data`.
    public static func encodePasteboardImageAsPNG(pngData: Data?, tiffData: Data?) -> Data? {
        if let pngData, !pngData.isEmpty {
            return pngData
        }
        if let tiffData,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let converted = bitmap.representation(using: .png, properties: [:]) {
            return converted
        }
        return nil
    }

    @MainActor
    private func pollPasteboard() {
        guard isEnabled else { return }
        let pb = NSPasteboard.general
        let currentCount = pb.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        guard let serial = activeSerialProvider?(), ADBService.validateSerial(serial) else { return }

        // 1. Check for image / screenshot in clipboard first (skip if file URLs are handled by drag-and-drop)
        let pngData = pb.data(forType: .png)
        let tiffData = pb.data(forType: .tiff)
        if let imageBytes = Self.encodePasteboardImageAsPNG(pngData: pngData, tiffData: tiffData),
           pb.string(forType: .string) == nil {
            syncImageToAndroid(imageBytes, serial: serial)
            return
        }

        // 2. Sync plain text when mirroring is closed (ScrcpyClient handles live mirroring sync)
        if let text = pb.string(forType: .string), !text.isEmpty, text != lastSyncedText {
            lastSyncedText = text
            if !ScrcpyClient.shared.isConnected {
                syncTextViaADB(text, serial: serial)
            }
        }
    }

    private func syncTextViaADB(_ text: String, serial: String) {
        let trimmed = String(text.prefix(4000))
        Task.detached { [weak self] in
            _ = try? await ADBService.shared.execute(
                arguments: ["-s", serial, "shell", "cmd", "clipboard", "set", trimmed],
                timeoutSeconds: 3.0
            )
            DispatchQueue.main.async {
                self?.onSyncEvent?("Clipboard text synced to Android")
            }
        }
    }

    private func syncImageToAndroid(_ pngData: Data, serial: String) {
        let filename = "clipboard_\(Int(Date().timeIntervalSince1970)).png"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try pngData.write(to: tempURL, options: .atomic)
        } catch {
            return
        }

        Task.detached { [weak self] in
            defer { try? FileManager.default.removeItem(at: tempURL) }
            let result = await PhotoTransferService.shared.pushFiles(urls: [tempURL], serial: serial)
            if result.success {
                DispatchQueue.main.async {
                    self?.onSyncEvent?("Clipboard image sent to Android Gallery")
                }
            }
        }
    }
}
