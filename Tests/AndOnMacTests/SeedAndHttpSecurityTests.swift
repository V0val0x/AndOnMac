import XCTest
import Network
@testable import AndOnMac
@testable import AndroidShadowGraphKit

final class SeedAndHttpSecurityTests: XCTestCase {

    func testShadowGraphManagerLoadsSeedGraphWithoutTouchingDiskUntilHydration() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("andonmac-seed-mgr-\(UUID().uuidString)", isDirectory: true)
        let graphURL = tmpDir.appendingPathComponent("shadow_graph.json")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let mgr = ShadowGraphManager(
            bridge: ShadowGraphBridge(),
            graphStorageURL: graphURL,
            seedDefaultGraph: true
        )
        await mgr.loadPersistedGraphIfNeeded()

        let seedCount = await mgr.bridge.graphEngine.seedVertexCount
        let hydratedCount = await mgr.bridge.graphEngine.hydratedVertexCount
        let totalEdges = await mgr.bridge.graphEngine.edgeCount
        XCTAssertEqual(seedCount, 20)
        XCTAssertEqual(hydratedCount, 0)
        XCTAssertEqual(totalEdges, 19)

        // Pure seed graph must NOT touch disk until real device activity mutates topology
        await mgr.flushPersistedGraph()
        XCTAssertFalse(FileManager.default.fileExists(atPath: graphURL.path))
    }

    func testAndroidMCPToolsKeyCodeResolutionAndAliases() {
        XCTAssertEqual(AndroidMCPTools.resolveKeyCode("HOME"), "3")
        XCTAssertEqual(AndroidMCPTools.resolveKeyCode("back"), "4")
        XCTAssertEqual(AndroidMCPTools.resolveKeyCode("RECENTS"), "187")
        XCTAssertEqual(AndroidMCPTools.resolveKeyCode("KEYCODE_APP_SWITCH"), "187")
        XCTAssertEqual(AndroidMCPTools.resolveKeyCode("keycode_enter"), "66")
        XCTAssertEqual(AndroidMCPTools.resolveKeyCode("66"), "66")
        XCTAssertNil(AndroidMCPTools.resolveKeyCode("4;id"))
        XCTAssertNil(AndroidMCPTools.resolveKeyCode("-1"))
        XCTAssertNil(AndroidMCPTools.resolveKeyCode("10000"))
        XCTAssertNil(AndroidMCPTools.resolveKeyCode(""))
    }

    func testMCPHTTPServerContentLengthAndOriginValidation() {
        XCTAssertEqual(MCPHTTPServer.parseContentLength(from: "GET / HTTP/1.1\r\nHost: 127.0.0.1:8765"), 0)
        XCTAssertEqual(MCPHTTPServer.parseContentLength(from: "POST / HTTP/1.1\r\nContent-Length: 42"), 42)
        XCTAssertNil(MCPHTTPServer.parseContentLength(from: "POST / HTTP/1.1\r\nContent-Length: -5"))
        XCTAssertNil(MCPHTTPServer.parseContentLength(from: "POST / HTTP/1.1\r\nContent-Length: abc"))
        XCTAssertNil(MCPHTTPServer.parseContentLength(from: "POST / HTTP/1.1\r\nContent-Length: 10\r\nContent-Length: 20"))
        XCTAssertNil(MCPHTTPServer.parseContentLength(from: "POST / HTTP/1.1\r\nContent-Length: 2000000"))

        XCTAssertEqual(
            MCPHTTPServer.validatedLoopbackOrigin(from: "OPTIONS / HTTP/1.1\r\nHost: 127.0.0.1:8765\r\nOrigin: http://localhost:6274"),
            "http://localhost:6274"
        )
        XCTAssertNil(
            MCPHTTPServer.validatedLoopbackOrigin(from: "OPTIONS / HTTP/1.1\r\nHost: 127.0.0.1:8765\r\nOrigin: https://evil.example")
        )
        XCTAssertNil(
            MCPHTTPServer.validatedLoopbackOrigin(from: "GET / HTTP/1.1\r\nHost: 127.0.0.1:8765")
        )
        // Strict RFC 6454 Origin hardening: reject userinfo, path, control chars, empty Origin, duplicate Host/Origin
        XCTAssertFalse(
            MCPHTTPServer.validateOriginAndHost(headers: "OPTIONS / HTTP/1.1\r\nHost: 127.0.0.1:8765\r\nOrigin: http://evil.com@localhost:6274")
        )
        XCTAssertFalse(
            MCPHTTPServer.validateOriginAndHost(headers: "OPTIONS / HTTP/1.1\r\nHost: 127.0.0.1:8765\r\nOrigin: http://localhost:6274/path")
        )
        XCTAssertFalse(
            MCPHTTPServer.validateOriginAndHost(headers: "OPTIONS / HTTP/1.1\r\nHost: 127.0.0.1:8765\r\nOrigin: http://localhost\nSet-Cookie: a=1")
        )
        XCTAssertFalse(
            MCPHTTPServer.validateOriginAndHost(headers: "OPTIONS / HTTP/1.1\r\nHost: 127.0.0.1:8765\r\nOrigin: https://evil.com\r\nOrigin: http://localhost:6274")
        )
        XCTAssertFalse(
            MCPHTTPServer.validateOriginAndHost(headers: "OPTIONS / HTTP/1.1\r\nHost: 127.0.0.1:8765\r\nHost: evil.com")
        )
        XCTAssertFalse(
            MCPHTTPServer.validateOriginAndHost(headers: "OPTIONS / HTTP/1.1\r\nHost: 127.0.0.1:8765\r\nOrigin: ")
        )
    }

    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func tryFire() -> Bool {
            lock.withLock {
                guard !fired else { return false }
                fired = true
                return true
            }
        }
    }

    func testLiveMCPHTTPServerLoopbackCORSPreflightNegativeContentLengthAndOriginRejection() async throws {
        let port: UInt16 = UInt16.random(in: 38100...39900)
        let server = MCPHTTPServer.shared
        let prevToken = server.bearerToken
        server.bearerToken = "test-secret-token"

        let readyExp = expectation(description: "MCPHTTPServer ready")
        let once = OnceFlag()
        server.start(port: port) { isUp in
            guard isUp else { return }
            if once.tryFire() {
                readyExp.fulfill()
            }
        }
        defer {
            server.stop()
            server.bearerToken = prevToken
        }
        await fulfillment(of: [readyExp], timeout: 3.0)

        // 1. Valid loopback CORS preflight succeeds WITHOUT Authorization header
        let preflightResp = try await sendRawTCP(
            port: port,
            payload: "OPTIONS /message HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nOrigin: http://localhost:6274\r\n\r\n"
        )
        XCTAssertTrue(preflightResp.contains("204 No Content"), "Got: \(preflightResp)")
        XCTAssertTrue(preflightResp.contains("Access-Control-Allow-Origin: http://localhost:6274"), "Got: \(preflightResp)")
        XCTAssertTrue(preflightResp.contains("Vary: Origin"), "Got: \(preflightResp)")

        // 2. Evil Origin gets 403 Forbidden WITHOUT CORS header
        let evilResp = try await sendRawTCP(
            port: port,
            payload: "OPTIONS /message HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nOrigin: https://evil.example\r\n\r\n"
        )
        XCTAssertTrue(evilResp.contains("403 Forbidden"), "Got: \(evilResp)")
        XCTAssertFalse(evilResp.contains("Access-Control-Allow-Origin"), "Got: \(evilResp)")

        // 3. Negative Content-Length gets 400 Bad Request
        let badLenResp = try await sendRawTCP(
            port: port,
            payload: "POST / HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer test-secret-token\r\nContent-Length: -5\r\n\r\n"
        )
        XCTAssertTrue(badLenResp.contains("400 Bad Request"), "Got: \(badLenResp)")
    }

    private func sendRawTCP(port: UInt16, payload: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let conn = NWConnection(
                host: .ipv4(.loopback),
                port: NWEndpoint.Port(rawValue: port)!,
                using: .tcp
            )
            let queue = DispatchQueue(label: "test.mcp.tcp.\(UUID().uuidString)")
            let stateLock = NSLock()
            var finished = false
            var responseData = Data()

            func finish(_ result: Result<String, Error>) {
                stateLock.lock()
                guard !finished else {
                    stateLock.unlock()
                    return
                }
                finished = true
                stateLock.unlock()
                conn.cancel()
                continuation.resume(with: result)
            }

            func readLoop() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                    if let data {
                        responseData.append(data)
                    }
                    if isComplete || error != nil {
                        finish(.success(String(decoding: responseData, as: UTF8.self)))
                    } else {
                        readLoop()
                    }
                }
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: Data(payload.utf8), completion: .contentProcessed { sendErr in
                        if let sendErr {
                            finish(.failure(sendErr))
                            return
                        }
                        readLoop()
                    })
                case .failed(let err):
                    finish(.failure(err))
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
    }
}
