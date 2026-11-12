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
        
        let hasAdb = FileManager.default.isExecutableFile(atPath: adb) || canExecute(command: adb)
        let hasScrcpy = FileManager.default.isExecutableFile(atPath: scrcpy) || canExecute(command: scrcpy)
        
        return DependencyStatus(
            hasAdb: hasAdb,
            hasScrcpy: hasScrcpy,
            adbPath: hasAdb ? adb : nil,
            scrcpyPath: hasScrcpy ? scrcpy : nil
        )
    }
    
    private func canExecute(command: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [command]
        
        var env = ProcessInfo.processInfo.environment
        let existingPath = env["PATH"] ?? ""
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + existingPath
        process.environment = env
        
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
    
    /// Automates the installation of missing dependencies via Homebrew in background
    public func autoInstallDependencies(onOutput: @escaping @Sendable (String) -> Void) async -> Bool {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = [
                    "-c",
                    "export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\"; which brew >/dev/null || (/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"); brew install scrcpy android-platform-tools"
                ]
                
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                        onOutput(str)
                    }
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
