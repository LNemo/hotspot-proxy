import Foundation
import Network
import os

enum ProxyListenerState: Equatable {
    case stopped
    case starting
    case ready
    case waiting(String)
    case failed(String)
}

struct ProxyDiagnostics {
    var state: ProxyListenerState
    var acceptedConnections: UInt64
    var events: [String]
}

private func diagnosticErrorDescription(_ error: NWError) -> String {
    switch error {
    case .posix(let code): return "POSIX code \(code.rawValue)"
    case .dns(let code): return "DNS code \(code)"
    case .tls(let status): return "TLS code \(status)"
    @unknown default: return "Network error"
    }
}

private func diagnosticErrorDescription(_ error: Error) -> String {
    if let networkError = error as? NWError { return diagnosticErrorDescription(networkError) }
    let value = error as NSError
    return "\(value.domain) code \(value.code)"
}

/// Proxy serving HTTP (incl. CONNECT) and SOCKS5 on the same port.
final class ProxyServer {
    let queue = DispatchQueue(label: "proxy", qos: .userInitiated)
    private var listener: NWListener?
    private var live: [ObjectIdentifier: Session] = [:]
    var onStats: ((Int, UInt64) -> Void)?
    var onState: ((String?) -> Void)?
    var onDiagnostics: ((ProxyDiagnostics) -> Void)?
    private let bytes = OSAllocatedUnfairLock(initialState: UInt64(0))
    private lazy var udp = UdpRelay(queue: queue)
    private var generation: UInt64 = 0
    private var diagnostics = ProxyDiagnostics(state: .stopped, acceptedConnections: 0, events: [])
    /// Each session gets a serial queue targeting this concurrent queue, so connections run in parallel across cores.
    private let work = DispatchQueue(label: "proxy.sessions", qos: .userInitiated, attributes: .concurrent)

    func start(port: UInt16) {
        queue.async { [weak self] in self?.startLocked(port: port) }
    }

    private func startLocked(port: UInt16) {
        generation &+= 1
        let currentGeneration = generation
        tearDownLocked()
        diagnostics = ProxyDiagnostics(state: .starting, acceptedConnections: 0, events: [])
        emitDiagnostics(event: "Starting TCP listener on port \(port)")
        do {
            let params = Tcp.params()
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            l.newConnectionHandler = { [weak self] c in self?.accept(c, generation: currentGeneration) }
            l.stateUpdateHandler = { [weak self] s in
                guard let self, self.generation == currentGeneration, self.listener === l else { return }
                switch s {
                case .ready:
                    self.diagnostics.state = .ready
                    self.emitDiagnostics(event: "TCP listener ready on port \(l.port?.rawValue ?? port)")
                    self.onState?(nil)
                case .waiting(let error):
                    let description = diagnosticErrorDescription(error)
                    self.diagnostics.state = .waiting(description)
                    self.emitDiagnostics(event: "TCP listener waiting: \(description)")
                case .failed(let error):
                    let description = diagnosticErrorDescription(error)
                    self.diagnostics.state = .failed(description)
                    self.emitDiagnostics(event: "TCP listener failed: \(description)")
                    self.onState?("Listener error: \(description)")
                    self.udp.stop()
                case .cancelled:
                    let description = "TCP listener cancelled"
                    self.diagnostics.state = .failed(description)
                    self.emitDiagnostics(event: description)
                    self.onState?("Listener error: \(description)")
                    self.udp.stop()
                default: break
                }
            }
            listener = l
            l.start(queue: queue)
            udp.onBytes = { [weak self] n in
                guard let self, self.generation == currentGeneration else { return }
                self.bytes.withLock { $0 &+= UInt64(n) }
            }
            udp.start(port: port)
        } catch {
            let description = diagnosticErrorDescription(error)
            diagnostics.state = .failed(description)
            emitDiagnostics(event: "Failed to create TCP listener: \(description)")
            onState?("Failed to start: \(description)")
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.generation &+= 1
            self.tearDownLocked()
            self.diagnostics.state = .stopped
            self.emitDiagnostics(event: "Proxy stopped")
            self.report()
        }
    }

    private func tearDownLocked() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        udp.stop()
        live.values.forEach { session in session.queue.async { session.close() } }
        live.removeAll()
    }

    private func accept(_ c: NWConnection, generation connectionGeneration: UInt64) {
        guard generation == connectionGeneration else { c.cancel(); return }
        diagnostics.acceptedConnections &+= 1
        emitDiagnostics(event: "TCP connection accepted")
        let s = Session(client: c, queue: DispatchQueue(label: "proxy.s", target: work))
        let id = ObjectIdentifier(s)
        live[id] = s
        s.onBytes = { [weak self] n in
            self?.queue.async {
                guard let self, self.generation == connectionGeneration else { return }
                self.bytes.withLock { $0 &+= UInt64(n) }
            }
        }
        s.onEvent = { [weak self] event in
            self?.queue.async {
                guard let self, self.generation == connectionGeneration else { return }
                self.emitDiagnostics(event: event)
            }
        }
        s.onClose = { [weak self] in
            self?.queue.async {
                guard let self, self.generation == connectionGeneration else { return }
                self.live[id] = nil
            }
        }
        s.queue.async { s.start() }
    }

    private func emitDiagnostics(event: String? = nil) {
        if let event {
            diagnostics.events.append(event)
            if diagnostics.events.count > 12 {
                diagnostics.events.removeFirst(diagnostics.events.count - 12)
            }
        }
        onDiagnostics?(diagnostics)
    }

    /// Called only while the UI is visible (never wakes the main thread in background).
    private func report() {
        let n = live.count, b = bytes.withLock { $0 }
        onStats?(n, b)
    }
    func pollStats() { queue.async { [weak self] in self?.report() } }
}

enum Tcp {
    static func params() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 10
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 60
        return NWParameters(tls: nil, tcp: tcp)
    }
    static let chunk = 128 * 1024
}

final class Session {
    let client: NWConnection
    var upstream: NWConnection?
    let queue: DispatchQueue
    var buf = Data()
    var closed = false
    private var finished = 0   // directions that hit EOF; session closes at 2
    var onBytes: ((Int) -> Void)?
    var onClose: (() -> Void)?
    var onEvent: ((String) -> Void)?

    init(client: NWConnection, queue: DispatchQueue) { self.client = client; self.queue = queue }

    func start() {
        client.stateUpdateHandler = { [weak self] s in
            if case .failed(let error) = s {
                self?.onEvent?("Client connection failed: \(diagnosticErrorDescription(error))")
                self?.close()
            }
            if case .cancelled = s { self?.close() }
        }
        client.start(queue: queue)
        need(1) { [weak self] in
            guard let self else { return }
            if self.buf.first == 0x05 { self.socksGreeting() } else { self.readHttpHeader() }
        }
    }

    // MARK: buffered reading
    private func need(_ n: Int, _ then: @escaping () -> Void) {
        if buf.count >= n { then(); return }
        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data, !data.isEmpty { self.buf.append(data) }
            if let err {
                self.onEvent?("Client receive failed: \(diagnosticErrorDescription(err))")
                self.close()
                return
            }
            if done && self.buf.count < n {
                self.onEvent?("Client closed during protocol detection")
                self.close()
                return
            }
            self.need(n, then)
        }
    }

    private func take(_ n: Int) -> Data {
        let d = buf.prefix(n); buf.removeFirst(n); return Data(d)
    }

    // MARK: SOCKS5
    private func socksGreeting() {
        onEvent?("SOCKS5 greeting received")
        need(2) { [self] in
            let nm = Int(buf[buf.startIndex + 1])
            need(2 + nm) { [self] in
                _ = take(2 + nm)
                client.send(content: Data([5, 0]), completion: .contentProcessed { _ in })
                socksRequest()
            }
        }
    }

    private func socksRequest() {
        need(5) { [self] in
            let b = Array(buf.prefix(5))
            guard b[0] == 5, b[1] == 1 || b[1] == 3 else { reply(7); close(); return }
            let cmd = b[1]
            let atyp = b[3]
            let addrLen: Int
            switch atyp {
            case 1: addrLen = 4
            case 3: addrLen = 1 + Int(b[4])
            case 4: addrLen = 16
            default: reply(8); close(); return
            }
            need(4 + addrLen + 2) { [self] in
                let r = Array(take(4 + addrLen + 2))
                let a = Array(r[4..<(4 + addrLen)])
                let host: String
                switch atyp {
                case 1: host = a.map(String.init).joined(separator: ".")
                case 3: host = String(decoding: a[1...], as: UTF8.self)
                default: host = stride(from: 0, to: 16, by: 2).map { String(format: "%x", (UInt16(a[$0]) << 8) | UInt16(a[$0 + 1])) }.joined(separator: ":")
                }
                let port = (UInt16(r[4 + addrLen]) << 8) | UInt16(r[5 + addrLen])
                if cmd == 3 { udpAssociate(); return }
                connect(host: host, port: port) { [self] ok in
                    reply(ok ? 0 : 5)
                    if ok { pipe() } else { close() }
                }
            }
        }
    }

    /// UDP ASSOCIATE: reply with the UDP relay on the same IP/port and hold until the TCP control connection closes.
    private func udpAssociate() {
        var resp = Data([5, 0, 0, 1, 0, 0, 0, 0, 0, 0])
        if case .hostPort(let h, let p)? = client.currentPath?.localEndpoint, case .ipv4(let v4) = h {
            resp = Data([5, 0, 0, 1]) + v4.rawValue + Data([UInt8(p.rawValue >> 8), UInt8(p.rawValue & 0xff)])
        }
        client.send(content: resp, completion: .contentProcessed { _ in })
        holdOpen()
    }

    private func holdOpen() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, done, err in
            if done || err != nil { self?.close() } else { self?.holdOpen() }
        }
    }

    private func reply(_ code: UInt8) {
        client.send(content: Data([5, code, 0, 1, 0, 0, 0, 0, 0, 0]), completion: .contentProcessed { _ in })
    }

    // MARK: HTTP
    private func readHttpHeader() {
        if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
            let head = String(decoding: buf[buf.startIndex..<r.lowerBound], as: UTF8.self)
            buf.removeSubrange(buf.startIndex..<r.upperBound)
            handleHttp(head)
            return
        }
        if buf.count > 64 * 1024 { close(); return }
        need(buf.count + 1) { [weak self] in self?.readHttpHeader() }
    }

    private func handleHttp(_ head: String) {
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3 else {
            onEvent?("Malformed HTTP request received")
            sendBadRequest()
            return
        }
        let method = parts[0], target = parts[1], version = parts[2]

        if method.uppercased() == "GET", target == "/__hotspot_health" {
            onEvent?("Direct health check received")
            let body = Data("Hotspot Proxy reachable\n".utf8)
            let header = Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            client.send(content: header + body, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in self?.close() })
            return
        }

        if method.uppercased() == "CONNECT" {
            onEvent?("HTTP CONNECT request received")
            let (h, p) = splitHostPort(target, defaultPort: 443)
            connect(host: h, port: p) { [self] ok in
                if ok {
                    client.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                    pipe()
                } else {
                    client.send(content: Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n".utf8), completion: .contentProcessed { [weak self] _ in self?.close() })
                }
            }
            return
        }

        guard let url = URL(string: target), let host = url.host else {
            onEvent?("Direct HTTP request rejected")
            sendBadRequest()
            return
        }
        onEvent?("HTTP proxy request received")
        let port = UInt16(url.port ?? 80)
        var path = url.path.isEmpty ? "/" : url.path
        if let q = url.query { path += "?" + q }
        lines[0] = "\(method) \(path) \(version)"
        lines = lines.filter {
            let k = $0.lowercased()
            return !(k.hasPrefix("proxy-connection:") || k.hasPrefix("connection:") || k.hasPrefix("keep-alive:") || k.hasPrefix("proxy-authorization:"))
        }
        lines.append("Connection: close")
        let newHead = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        connect(host: host, port: port) { [self] ok in
            guard ok else {
                client.send(content: Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n".utf8), completion: .contentProcessed { [weak self] _ in self?.close() })
                return
            }
            upstream?.send(content: newHead, completion: .contentProcessed { _ in })
            pipe()
        }
    }

    private func sendBadRequest() {
        let response = Data("HTTP/1.1 400 Bad Request\r\nX-Proxy: hotspot\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        client.send(content: response, contentContext: .finalMessage, isComplete: true,
                    completion: .contentProcessed { [weak self] _ in self?.close() })
    }

    private func splitHostPort(_ s: String, defaultPort: UInt16) -> (String, UInt16) {
        if s.hasPrefix("["), let end = s.firstIndex(of: "]") {
            let h = String(s[s.index(after: s.startIndex)..<end])
            let rest = s[s.index(after: end)...]
            return (h, rest.hasPrefix(":") ? UInt16(rest.dropFirst()) ?? defaultPort : defaultPort)
        }
        if let i = s.lastIndex(of: ":"), let p = UInt16(s[s.index(after: i)...]) { return (String(s[..<i]), p) }
        return (s, defaultPort)
    }

    // MARK: upstream + relay
    private func connect(host: String, port: UInt16, _ done: @escaping (Bool) -> Void) {
        guard let p = NWEndpoint.Port(rawValue: port) else {
            onEvent?("Upstream connection failed")
            done(false)
            return
        }
        let up = NWConnection(host: NWEndpoint.Host(host), port: p, using: Tcp.params())
        upstream = up
        var fired = false
        up.stateUpdateHandler = { [weak self] s in
            switch s {
            case .ready: if !fired { fired = true; done(true) }
            case .failed, .waiting:
                if !fired {
                    fired = true
                    self?.onEvent?("Upstream connection failed")
                    done(false)
                } else { self?.close() }
            case .cancelled: self?.close()
            default: break
            }
        }
        up.start(queue: queue)
    }

    private func pipe() {
        guard let up = upstream else { close(); return }
        if !buf.isEmpty { let d = buf; buf = Data(); up.send(content: d, completion: .contentProcessed { _ in }) }
        relay(from: client, to: up)
        relay(from: up, to: client)
    }

    /// On EOF in one direction, forward only a FIN (half-close) and keep relaying the other direction.
    private func relay(from: NWConnection, to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: Tcp.chunk) { [weak self] data, _, done, err in
            guard let self, !self.closed else { return }
            if err != nil { self.close(); return }
            let payload = (data?.isEmpty == false) ? data : nil
            if let payload { self.onBytes?(payload.count) }
            if payload == nil && !done { self.relay(from: from, to: to); return }
            to.send(content: payload, contentContext: done ? .finalMessage : .defaultMessage, isComplete: done,
                    completion: .contentProcessed { [weak self] e in
                guard let self, !self.closed else { return }
                if e != nil { self.close(); return }
                if done {
                    self.finished += 1
                    if self.finished == 2 { self.close() }
                } else {
                    self.relay(from: from, to: to)
                }
            })
        }
    }

    func close() {
        if closed { return }
        closed = true
        client.cancel(); upstream?.cancel()
        onClose?()
    }
}
