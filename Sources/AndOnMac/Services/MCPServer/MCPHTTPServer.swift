import Foundation
import Network

/// Embedded local HTTP/SSE MCP server bound strictly to `127.0.0.1` for live agent control.
public final class MCPHTTPServer: @unchecked Sendable {
    public static let shared = MCPHTTPServer()

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.andonmac.mcp.http", qos: .userInitiated)
    private let lock = NSLock()
    private var sseConnections: [String: NWConnection] = [:]
    private var _bearerToken: String?
    public private(set) var activePort: UInt16 = 8765

    /// Optional per-session Bearer token. When non-empty, every HTTP/SSE request must present
    /// `Authorization: Bearer <token>`.
    public var bearerToken: String? {
        get { lock.lock(); defer { lock.unlock() }; return _bearerToken }
        set { lock.lock(); _bearerToken = newValue; lock.unlock() }
    }

    private init() {}

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return listener != nil
    }

    public func start(port: UInt16 = 8765, onStateChanged: (@Sendable (Bool) -> Void)? = nil) {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            onStateChanged?(false)
            return
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)

        do {
            let newListener = try NWListener(using: params)
            newListener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.activePort = port
                    onStateChanged?(true)
                case .failed, .cancelled:
                    self?.lock.lock()
                    self?.listener = nil
                    self?.lock.unlock()
                    onStateChanged?(false)
                default:
                    break
                }
            }
            newListener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            lock.lock()
            listener = newListener
            activePort = port
            lock.unlock()
            newListener.start(queue: queue)
        } catch {
            onStateChanged?(false)
        }
    }

    public func stop() {
        lock.lock()
        let currentListener = listener
        listener = nil
        let conns = Array(sseConnections.values)
        sseConnections.removeAll()
        lock.unlock()

        currentListener?.cancel()
        for conn in conns {
            conn.cancel()
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHTTPRequest(from: connection, accumulated: Data())
    }

    private func receiveHTTPRequest(from connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self] data, _, isComplete, error in
            guard let self = self else {
                connection.cancel()
                return
            }
            var buffer = accumulated
            if let data { buffer.append(data) }

            if let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer.subdata(in: buffer.startIndex..<headerRange.lowerBound)
                let bodyStart = headerRange.upperBound
                let headerText = String(data: headerData, encoding: .utf8) ?? ""
                guard let contentLength = Self.parseContentLength(from: headerText) else {
                    self.sendHTTPResponse(
                        connection: connection,
                        status: "400 Bad Request",
                        contentType: "application/json",
                        body: Data("{\"error\":\"Invalid Content-Length\"}".utf8)
                    )
                    return
                }
                let bodyAvailable = buffer.count - bodyStart

                if bodyAvailable >= contentLength {
                    let bodyData = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
                    self.routeHTTP(connection: connection, headers: headerText, body: bodyData)
                    return
                }
            }

            if error != nil || isComplete || buffer.count > 1_048_576 {
                connection.cancel()
            } else {
                self.receiveHTTPRequest(from: connection, accumulated: buffer)
            }
        }
    }

    private func routeHTTP(connection: NWConnection, headers: String, body: Data) {
        let firstLine = headers.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        let method = parts.first.map(String.init) ?? "GET"
        let path = parts.dropFirst().first.map(String.init) ?? "/"

        guard Self.validateOriginAndHost(headers: headers) else {
            sendHTTPResponse(connection: connection, status: "403 Forbidden", contentType: "application/json", body: Data("{\"error\":\"Forbidden origin or host\"}".utf8))
            return
        }

        let allowedOrigin = Self.validatedLoopbackOrigin(from: headers)

        if method == "OPTIONS" {
            sendHTTPResponse(connection: connection, status: "204 No Content", contentType: "text/plain", body: Data(), allowedOrigin: allowedOrigin)
            return
        }

        if let expectedToken = bearerToken, !expectedToken.isEmpty {
            guard Self.validateBearerToken(headers: headers, expectedToken: expectedToken) else {
                sendHTTPResponse(connection: connection, status: "401 Unauthorized", contentType: "application/json", body: Data("{\"error\":\"Unauthorized\"}".utf8), allowedOrigin: allowedOrigin)
                return
            }
        }

        if method == "GET" && path.hasPrefix("/sse") {
            let sessionId = UUID().uuidString
            lock.lock()
            sseConnections[sessionId] = connection
            lock.unlock()

            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled:
                    self?.lock.lock()
                    self?.sseConnections.removeValue(forKey: sessionId)
                    self?.lock.unlock()
                default:
                    break
                }
            }

            let corsHeaders = Self.corsHeaderBlock(for: allowedOrigin)
            let handshake = "HTTP/1.1 200 OK\r\n" +
                "Content-Type: text/event-stream\r\n" +
                "Cache-Control: no-cache\r\n" +
                "X-Content-Type-Options: nosniff\r\n" +
                corsHeaders +
                "Connection: keep-alive\r\n\r\n" +
                "event: endpoint\ndata: /message?sessionId=\(sessionId)\n\n"
            connection.send(content: Data(handshake.utf8), completion: .contentProcessed { _ in })
            return
        }

        if method == "POST" {
            let sessionId = Self.extractQueryParam("sessionId", from: path)
            Task {
                let responseData = await MCPServerCore.shared.handleRawRequestData(body)
                if let sessionId,
                   let sseConn = self.getSSEConnection(for: sessionId),
                   let respData = responseData,
                   let jsonString = String(data: respData, encoding: .utf8) {
                    let sseEvent = "event: message\ndata: \(jsonString)\n\n"
                    sseConn.send(content: Data(sseEvent.utf8), completion: .contentProcessed { _ in })
                    self.sendHTTPResponse(connection: connection, status: "202 Accepted", contentType: "application/json", body: Data("{\"ok\":true}".utf8), allowedOrigin: allowedOrigin)
                } else if let respData = responseData {
                    self.sendHTTPResponse(connection: connection, status: "200 OK", contentType: "application/json", body: respData, allowedOrigin: allowedOrigin)
                } else {
                    self.sendHTTPResponse(connection: connection, status: "202 Accepted", contentType: "application/json", body: Data(), allowedOrigin: allowedOrigin)
                }
            }
            return
        }

        let health = "{\"server\":\"AndOnMac MCP\",\"protocol\":\"\(MCPServerCore.protocolVersion)\",\"status\":\"running\"}"
        sendHTTPResponse(connection: connection, status: "200 OK", contentType: "application/json", body: Data(health.utf8), allowedOrigin: allowedOrigin)
    }

    private func getSSEConnection(for sessionId: String) -> NWConnection? {
        lock.lock(); defer { lock.unlock() }
        return sseConnections[sessionId]
    }

    /// Broadcasts `notifications/tools/list_changed` to all active SSE sessions for LiveReload.
    public func broadcastToolsListChanged() {
        lock.lock()
        let connections = Array(sseConnections.values)
        lock.unlock()
        guard !connections.isEmpty else { return }

        let payload = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}\n\n"
        let data = Data(payload.utf8)
        for conn in connections {
            conn.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    private func sendHTTPResponse(
        connection: NWConnection,
        status: String,
        contentType: String,
        body: Data,
        allowedOrigin: String? = nil
    ) {
        let corsHeaders = Self.corsHeaderBlock(for: allowedOrigin)
        let header = "HTTP/1.1 \(status)\r\n" +
            "Content-Type: \(contentType)\r\n" +
            "Content-Length: \(body.count)\r\n" +
            "X-Content-Type-Options: nosniff\r\n" +
            corsHeaders +
            "Connection: close\r\n\r\n"
        var full = Data(header.utf8)
        full.append(body)
        connection.send(content: full, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func corsHeaderBlock(for allowedOrigin: String?) -> String {
        guard let origin = allowedOrigin,
              !origin.isEmpty,
              !origin.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            return ""
        }
        return "Access-Control-Allow-Origin: \(origin)\r\n" +
            "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" +
            "Access-Control-Allow-Headers: Content-Type, Authorization\r\n" +
            "Vary: Origin\r\n"
    }

    private static func isValidLoopbackHost(_ raw: String) -> Bool {
        guard !raw.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            return false
        }
        let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty,
              !trimmed.contains(where: { $0.isWhitespace || $0 == "@" || $0 == "/" || $0 == "?" || $0 == "#" || $0 == "\\" }) else {
            return false
        }
        let host: String
        if trimmed.hasPrefix("[") {
            guard let closeIdx = trimmed.firstIndex(of: "]") else { return false }
            let inner = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closeIdx])
            let tail = String(trimmed[trimmed.index(after: closeIdx)...])
            if !tail.isEmpty {
                guard tail.hasPrefix(":") else { return false }
                let portStr = String(tail.dropFirst())
                guard !portStr.isEmpty,
                      portStr.allSatisfy({ $0.isASCII && $0.isNumber }),
                      let port = UInt16(portStr), port > 0 else {
                    return false
                }
            }
            host = inner
        } else if let colonIdx = trimmed.firstIndex(of: ":") {
            let portStr = String(trimmed[trimmed.index(after: colonIdx)...])
            guard !portStr.isEmpty,
                  portStr.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let port = UInt16(portStr), port > 0 else {
                return false
            }
            host = String(trimmed[..<colonIdx])
        } else {
            host = trimmed
        }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    private static func isValidLoopbackOrigin(_ raw: String) -> Bool {
        guard !raw.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            return false
        }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: { $0.isWhitespace || $0 == "@" || $0 == "?" || $0 == "#" || $0 == "\\" }) else {
            return false
        }
        let lower = trimmed.lowercased()
        let rest: String
        if lower.hasPrefix("http://") {
            rest = String(lower.dropFirst("http://".count))
        } else if lower.hasPrefix("https://") {
            rest = String(lower.dropFirst("https://".count))
        } else {
            return false
        }
        // Strict RFC 6454 Origin: scheme://host[:port] only (zero path, query, fragment, or userinfo).
        guard !rest.contains("/") else { return false }
        return isValidLoopbackHost(rest)
    }

    /// Returns the raw `Origin` header value only if present (at most once), single-line, and validated as strict loopback.
    public static func validatedLoopbackOrigin(from headers: String) -> String? {
        guard validateOriginAndHost(headers: headers) else { return nil }
        for line in headers.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            if key == "origin" {
                let raw = parts[1].trimmingCharacters(in: .whitespaces)
                guard isValidLoopbackOrigin(raw) else { return nil }
                return raw
            }
        }
        return nil
    }

    /// Validates `Host` (must be strict loopback `127.0.0.1` / `localhost` / `[::1]` if present, no duplicates)
    /// and `Origin` (must be absent or strict RFC 6454 loopback `scheme://host[:port]`, no duplicates)
    /// to block browser CSRF, header injection, and DNS-rebinding attacks.
    public static func validateOriginAndHost(headers: String) -> Bool {
        var hostCount = 0
        var originCount = 0
        for line in headers.components(separatedBy: "\r\n") {
            if line.contains("\r") || line.contains("\n") || line.contains("\0") {
                return false
            }
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let rawVal = String(parts[1])

            if key == "host" {
                hostCount += 1
                if hostCount > 1 || !isValidLoopbackHost(rawVal) {
                    return false
                }
            } else if key == "origin" {
                originCount += 1
                if originCount > 1 || !isValidLoopbackOrigin(rawVal) {
                    return false
                }
            }
        }
        return true
    }

    /// Constant-time Bearer token check against `Authorization: Bearer <token>`.
    public static func validateBearerToken(headers: String, expectedToken: String) -> Bool {
        for line in headers.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            if key == "authorization" {
                let val = parts[1].trimmingCharacters(in: .whitespaces)
                guard val.lowercased().hasPrefix("bearer ") else { return false }
                let provided = String(val.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
                return constantTimeEquals(provided, expectedToken)
            }
        }
        return false
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count {
            diff |= a[i] ^ b[i]
        }
        return diff == 0
    }

    /// Strictly parses `Content-Length`: returns `0` when absent, `nil` on negative, non-numeric,
    /// conflicting duplicate, or >1 MiB values so malformed requests receive `400 Bad Request`.
    public static func parseContentLength(from headers: String) -> Int? {
        var found: Int?
        for line in headers.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            if key == "content-length" {
                let raw = parts[1].trimmingCharacters(in: .whitespaces)
                guard !raw.isEmpty,
                      raw.allSatisfy({ $0.isASCII && $0.isNumber }),
                      let parsed = Int(raw),
                      parsed >= 0,
                      parsed <= 1_048_576 else {
                    return nil
                }
                if let prev = found, prev != parsed {
                    return nil
                }
                found = parsed
            }
        }
        return found ?? 0
    }

    private static func extractQueryParam(_ key: String, from path: String) -> String? {
        guard let qIndex = path.firstIndex(of: "?") else { return nil }
        let query = path[path.index(after: qIndex)...]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, String(kv[0]) == key {
                return String(kv[1])
            }
        }
        return nil
    }
}
