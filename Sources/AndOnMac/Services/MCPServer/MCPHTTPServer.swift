import Foundation
import Network

/// Embedded local HTTP/SSE MCP server bound strictly to `127.0.0.1` for live agent control.
public final class MCPHTTPServer: @unchecked Sendable {
    public static let shared = MCPHTTPServer()

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.andonmac.mcp.http", qos: .userInitiated)
    private let lock = NSLock()
    private var sseConnections: [String: NWConnection] = [:]
    public private(set) var activePort: UInt16 = 8765

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

        if method == "OPTIONS" {
            sendHTTPResponse(connection: connection, status: "204 No Content", contentType: "text/plain", body: Data())
            return
        }

        if method == "GET" && path.hasPrefix("/sse") {
            let sessionId = UUID().uuidString
            lock.lock()
            sseConnections[sessionId] = connection
            lock.unlock()

            let handshake = "HTTP/1.1 200 OK\r\n" +
                "Content-Type: text/event-stream\r\n" +
                "Cache-Control: no-cache\r\n" +
                "Connection: keep-alive\r\n" +
                "Access-Control-Allow-Origin: *\r\n\r\n" +
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
            "Access-Control-Allow-Origin: *\r\n" +
            "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" +
            "Access-Control-Allow-Headers: Content-Type\r\n" +
            "Connection: close\r\n\r\n"
        var full = Data(header.utf8)
        full.append(body)
        connection.send(content: full, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func extractContentLength(from headers: String) -> Int {
        for line in headers.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let val = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                return Int(val) ?? 0
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
