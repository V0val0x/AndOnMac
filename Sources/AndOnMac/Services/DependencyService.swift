import Foundation
import Combine

public struct DependencyStatus: Sendable {
    public let hasAdb: Bool
    public let hasScrcpy: Bool
    public let adbPath: String?
    public let scrcpyPath: String?
    
    public var isAllReady: Bool {
        return hasAdb && hasScrcpy
    }
}

public final class DependencyService: @unchecked Sendable {
    public static let shared = DependencyService()
    
    private init() {}
    
    public func checkDependencies() -> DependencyStatus {
        let adb = ADBService.shared.adbPath
        let scrcpy = MirrorService.shared.scrcpyPath
        
        let hasAdb = FileManager.default.isExecutableFile(atPath: adb)
        let hasScrcpy = FileManager.default.isExecutableFile(atPath: scrcpy)
        
        return DependencyStatus(
            hasAdb: hasAdb,
            hasScrcpy: hasScrcpy,
            adbPath: hasAdb ? adb : nil,
            scrcpyPath: hasScrcpy ? scrcpy : nil
        )
    }

    private func resolveBrewPath() -> String? {
        let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }
    
    /// Automates the installation of missing dependencies via Homebrew in background (no shell interpolation).
    public func autoInstallDependencies(onOutput: @escaping @Sendable (String) -> Void) async -> Bool {
        guard let brewPath = resolveBrewPath() else {
            onOutput("Homebrew не найден. Установите Homebrew с https://brew.sh и выполните: brew install scrcpy android-platform-tools\n")
            return false
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: brewPath)
                process.arguments = ["install", "scrcpy", "android-platform-tools"]

                var env = ProcessInfo.processInfo.environment
                let existingPath = env["PATH"] ?? ""
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + existingPath
                process.environment = env
                
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                        onOutput(str)
                    }
                }
                
                let trackedId = ProcessLifecycleManager.shared.register(process, tag: "brew")
                let watchdog = DispatchWorkItem {
                    if process.isRunning {
                        ProcessLifecycleManager.shared.terminateProcess(process, gracePeriodMs: 500)
                    }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 300.0, execute: watchdog)
                defer {
                    watchdog.cancel()
                    pipe.fileHandleForReading.readabilityHandler = nil
                    ProcessLifecycleManager.shared.unregister(trackedId)
                }
                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus == 0)
                } catch {
                    onOutput("Ошибка запуска авто-установщика: \(error.localizedDescription)\n")
                    continuation.resume(returning: false)
                }
            }
        }
    }
}
