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
                let contentLength = Self.extractContentLength(from: headerText)
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

        if let expectedToken = bearerToken, !expectedToken.isEmpty {
            guard Self.validateBearerToken(headers: headers, expectedToken: expectedToken) else {
                sendHTTPResponse(connection: connection, status: "401 Unauthorized", contentType: "application/json", body: Data("{\"error\":\"Unauthorized\"}".utf8))
                return
            }
        }

        if method == "OPTIONS" {
            sendHTTPResponse(connection: connection, status: "204 No Content", contentType: "text/plain", body: Data())
            return
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

            let handshake = "HTTP/1.1 200 OK\r\n" +
                "Content-Type: text/event-stream\r\n" +
                "Cache-Control: no-cache\r\n" +
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
                    self.sendHTTPResponse(connection: connection, status: "202 Accepted", contentType: "application/json", body: Data("{\"ok\":true}".utf8))
                } else if let respData = responseData {
                    self.sendHTTPResponse(connection: connection, status: "200 OK", contentType: "application/json", body: respData)
                } else {
                    self.sendHTTPResponse(connection: connection, status: "202 Accepted", contentType: "application/json", body: Data())
                }
            }
            return
        }

        let health = "{\"server\":\"AndOnMac MCP\",\"protocol\":\"\(MCPServerCore.protocolVersion)\",\"status\":\"running\"}"
        sendHTTPResponse(connection: connection, status: "200 OK", contentType: "application/json", body: Data(health.utf8))
    }

    private func getSSEConnection(for sessionId: String) -> NWConnection? {
        lock.lock(); defer { lock.unlock() }
        return sseConnections[sessionId]
    }

    private func sendHTTPResponse(connection: NWConnection, status: String, contentType: String, body: Data) {
        let header = "HTTP/1.1 \(status)\r\n" +
            "Content-Type: \(contentType)\r\n" +
            "Content-Length: \(body.count)\r\n" +
            "X-Content-Type-Options: nosniff\r\n" +
            "Connection: close\r\n\r\n"
        var full = Data(header.utf8)
        full.append(body)
        connection.send(content: full, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Validates `Host` (must be loopback `127.0.0.1` / `localhost` / `[::1]` if present) and `Origin`
    /// (must be absent or exact loopback host) to block browser CSRF and DNS-rebinding attacks.
    public static func validateOriginAndHost(headers: String) -> Bool {
        for line in headers.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let val = parts[1].trimmingCharacters(in: .whitespaces).lowercased()

            if key == "host" {
                guard let parsedHost = URL(string: "http://\(val)")?.host?.lowercased(),
                      parsedHost == "127.0.0.1" || parsedHost == "localhost" || parsedHost == "::1" || parsedHost == "[::1]" else {
                    return false
                }
            } else if key == "origin" {
                guard let url = URL(string: val),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https",
                      let originHost = url.host?.lowercased(),
                      originHost == "127.0.0.1" || originHost == "localhost" || originHost == "::1" || originHost == "[::1]" else {
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

    private static func extractContentLength(from headers: String) -> Int {
        for line in headers.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let val = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                return max(0, Int(val) ?? 0)
            }
        }
        return 0
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
