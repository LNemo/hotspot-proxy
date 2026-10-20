import Darwin
import Foundation
import Network

private enum SmokeFailure: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let value): return value
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw SmokeFailure.message(message) }
}

private final class DiagnosticsRecorder {
    private let condition = NSCondition()
    private var value = ProxyDiagnostics(state: .stopped, acceptedConnections: 0, events: [])

    func record(_ diagnostics: ProxyDiagnostics) {
        condition.lock()
        value = diagnostics
        condition.broadcast()
        condition.unlock()
    }

    func wait(until predicate: (ProxyDiagnostics) -> Bool, timeout: TimeInterval = 5) throws -> ProxyDiagnostics {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while !predicate(value) {
            guard condition.wait(until: deadline) else {
                throw SmokeFailure.message("Timed out waiting for diagnostics; last state: \(value.state)")
            }
        }
        return value
    }

    func snapshot() -> ProxyDiagnostics {
        condition.lock()
        defer { condition.unlock() }
        return value
    }
}

private final class ResponseBox {
    private let lock = NSLock()
    private var data = Data()
    private var error: String?
    private var finished = false
    let semaphore = DispatchSemaphore(value: 0)

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func hasData() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !data.isEmpty
    }

    func result() -> (Data, String?) {
        lock.lock()
        defer { lock.unlock() }
        return (data, error)
    }

    func fail(_ message: String) {
        lock.lock()
        error = message
        lock.unlock()
        finish()
    }

    func finish() {
        lock.lock()
        let shouldSignal = !finished
        finished = true
        lock.unlock()
        if shouldSignal { semaphore.signal() }
    }
}

private final class StringResultBox {
    private let lock = NSLock()
    private var value: String?
    let semaphore = DispatchSemaphore(value: 0)

    func set(_ result: String) {
        lock.lock()
        value = result
        lock.unlock()
        semaphore.signal()
    }

    func get() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func request(port: UInt16, text: String, timeout: TimeInterval = 5) throws -> Data {
    guard let nwPort = NWEndpoint.Port(rawValue: port) else {
        throw SmokeFailure.message("Invalid test port \(port)")
    }
    let queue = DispatchQueue(label: "proxy.smoke.client.\(port).\(UUID().uuidString)")
    let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
    let response = ResponseBox()
    var sent = false

    var receive: (() -> Void)!
    receive = {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
            if let data, !data.isEmpty { response.append(data) }
            if let error {
                if response.hasData() { response.finish() }
                else { response.fail("Receive failed: \(error)") }
            } else if complete {
                response.finish()
            } else {
                receive()
            }
        }
    }
    connection.stateUpdateHandler = { state in
        switch state {
        case .ready where !sent:
            sent = true
            connection.send(content: Data(text.utf8), completion: .contentProcessed { error in
                if let error { response.fail("Send failed: \(error)") }
            })
            receive()
        case .failed(let error): response.fail("Connect failed: \(error)")
        default: break
        }
    }
    connection.start(queue: queue)
    guard response.semaphore.wait(timeout: .now() + timeout) == .success else {
        connection.cancel()
        throw SmokeFailure.message("Timed out reading response from port \(port)")
    }
    connection.cancel()
    let (data, error) = response.result()
    if let error { throw SmokeFailure.message(error) }
    return data
}

private final class HTTPFixture {
    private let queue = DispatchQueue(label: "proxy.smoke.fixture")
    private let ready = DispatchSemaphore(value: 0)
    private let responseBody = Data("fixture-forwarded-body".utf8)
    private var listener: NWListener?
    private(set) var error: String?

    init(port: UInt16) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.ready.signal()
            case .failed(let error):
                self?.error = String(describing: error)
                self?.ready.signal()
            default: break
            }
        }
        listener?.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener?.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else {
            throw SmokeFailure.message("Fixture listener did not become ready")
        }
        if let error { throw SmokeFailure.message("Fixture listener failed: \(error)") }
    }

    deinit { listener?.cancel() }

    private func serve(_ connection: NWConnection) {
        var requestData = Data()
        var receive: (() -> Void)!
        receive = { [weak self] in
            guard let self else { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                if let data { requestData.append(data) }
                if requestData.range(of: Data("\r\n\r\n".utf8)) != nil {
                    let header = Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(self.responseBody.count)\r\nConnection: close\r\n\r\n".utf8)
                    connection.send(content: header + self.responseBody, contentContext: .finalMessage, isComplete: true,
                                    completion: .contentProcessed { _ in connection.cancel() })
                } else if complete || error != nil {
                    connection.cancel()
                } else {
                    receive()
                }
            }
        }
        connection.start(queue: queue)
        receive()
    }
}

@main
private enum ProxyServerSmoke {
    static func main() {
        do {
            try run()
            print("ProxyServer smoke tests passed")
        } catch {
            fputs("ProxyServer smoke tests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func run() throws {
        let base = UInt16(40_000 + (Int(getpid()) % 5_000) * 2)
        let proxyPort = base
        let fixturePort = base + 1
        let fixture = try HTTPFixture(port: fixturePort)
        defer { withExtendedLifetime(fixture) {} }

        let server = ProxyServer()
        let recorder = DiagnosticsRecorder()
        server.onDiagnostics = { recorder.record($0) }
        server.start(port: proxyPort)
        _ = try recorder.wait { $0.state == .ready }

        let health = try request(port: proxyPort, text: "GET /__hotspot_health HTTP/1.1\r\nHost: local\r\n\r\n")
        let healthText = String(decoding: health, as: UTF8.self)
        try require(healthText.contains("HTTP/1.1 200 OK"), "Health endpoint did not return 200")
        try require(healthText.contains("Hotspot Proxy reachable"), "Health endpoint body was missing")
        let afterHealth = try recorder.wait { $0.acceptedConnections >= 1 && $0.events.contains("Direct health check received") }
        try require(afterHealth.acceptedConnections == 1, "Accepted connection was not counted immediately")

        let probe = LocalProxyProbe()
        let probeResult = StringResultBox()
        probe.start(port: proxyPort) { probeResult.set($0) }
        guard probeResult.semaphore.wait(timeout: .now() + 7) == .success else {
            throw SmokeFailure.message("LocalProxyProbe did not finish")
        }
        try require(probeResult.get()?.hasPrefix("Passed:") == true, "LocalProxyProbe failed: \(probeResult.get() ?? "no result")")
        _ = try recorder.wait { $0.acceptedConnections >= 2 }

        let direct = try request(port: proxyPort, text: "GET /ordinary-direct-path HTTP/1.1\r\nHost: local\r\n\r\n")
        try require(String(decoding: direct, as: UTF8.self).contains("400 Bad Request"), "Non-health origin-form request was not rejected")
        let malformed = try request(port: proxyPort, text: "malformed\r\n\r\n")
        try require(String(decoding: malformed, as: UTF8.self).contains("400 Bad Request"), "Malformed request was not rejected")

        let privateMarker = "private-query-marker"
        let proxied = try request(
            port: proxyPort,
            text: "GET http://127.0.0.1:\(fixturePort)/secret?token=\(privateMarker) HTTP/1.1\r\nHost: 127.0.0.1\r\nProxy-Authorization: secret-value\r\n\r\n"
        )
        try require(String(decoding: proxied, as: UTF8.self).contains("fixture-forwarded-body"), "HTTP proxy did not forward fixture response")
        let afterProxy = try recorder.wait { $0.events.contains("HTTP proxy request received") }
        try require(!afterProxy.events.joined(separator: " ").contains(privateMarker), "Diagnostics leaked a target query")
        try require(!afterProxy.events.joined(separator: " ").contains("secret-value"), "Diagnostics leaked proxy credentials")

        for _ in 0..<8 {
            _ = try request(port: proxyPort, text: "bad\r\n\r\n")
        }
        let bounded = try recorder.wait { $0.acceptedConnections >= 12 }
        try require(bounded.events.count <= 12, "Diagnostics retained more than 12 events")

        server.stop()
        _ = try recorder.wait { $0.state == .stopped }

        server.start(port: proxyPort)
        let restarted = try recorder.wait { $0.state == .ready }
        try require(restarted.acceptedConnections == 0, "Restart did not reset accepted connection count")
        let secondHealth = try request(port: proxyPort, text: "GET /__hotspot_health HTTP/1.1\r\nHost: local\r\n\r\n")
        try require(String(decoding: secondHealth, as: UTF8.self).contains("Hotspot Proxy reachable"), "Health endpoint failed after restart")
        let afterRestart = try recorder.wait { $0.acceptedConnections == 1 }
        try require(afterRestart.state == .ready, "Listener left ready state after restart")

        server.stop()
        _ = try recorder.wait { $0.state == .stopped }
    }
}
