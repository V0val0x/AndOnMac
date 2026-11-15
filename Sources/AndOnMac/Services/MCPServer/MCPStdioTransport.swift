import Foundation

/// Headless newline-delimited JSON-RPC 2.0 stdio transport for `--mcp-stdio`.
/// Reads from `stdin`, writes JSON-RPC responses strictly to `stdout`, and logs only to `stderr`.
public enum MCPStdioTransport {
    public static func runBlocking() {
        logError("AndOnMac MCP stdio server started (protocol \(MCPServerCore.protocolVersion))")

        let loadSem = DispatchSemaphore(value: 0)
        Task {
            await ShadowGraphManager.shared.loadPersistedGraphIfNeeded()
            loadSem.signal()
        }
        loadSem.wait()

        let stdinHandle = FileHandle.standardInput
        let stdoutHandle = FileHandle.standardOutput
        var buffer = Data()

        while true {
            let chunk = stdinHandle.availableData
            if chunk.isEmpty {
                break // EOF
            }
            buffer.append(chunk)

            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                buffer.removeSubrange(buffer.startIndex...newlineIndex)

                let trimmed = String(data: lineData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !trimmed.isEmpty, let reqData = trimmed.data(using: .utf8) else { continue }

                let semaphore = DispatchSemaphore(value: 0)
                var responseData: Data?
                Task {
                    responseData = await MCPServerCore.shared.handleRawRequestData(reqData)
                    semaphore.signal()
                }
                semaphore.wait()

                if var resp = responseData {
                    resp.append(0x0A) // newline delimiter
                    stdoutHandle.write(resp)
                }
            }
        }
        let stopSem = DispatchSemaphore(value: 0)
        Task.detached {
            await ShadowGraphManager.shared.stop()
            stopSem.signal()
        }
        _ = stopSem.wait(timeout: .now() + 2.5)
        logError("AndOnMac MCP stdio server exiting on EOF")
    }

    private static func logError(_ message: String) {
        if let data = "[AndOnMac MCP] \(message)\n".data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}
