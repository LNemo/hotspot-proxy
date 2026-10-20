import Foundation
import Network

/// A bounded, device-local check. It does not prove reachability from an iPad.
final class LocalProxyProbe {
    private let queue = DispatchQueue(label: "proxy.local-check")
    private var connection: NWConnection?
    private var completion: ((String) -> Void)?
    private var response = Data()

    func start(port: UInt16, completion: @escaping (String) -> Void) {
        queue.async { [self] in
            self.completion = completion
            guard let endpointPort = NWEndpoint.Port(rawValue: port), port != 0 else {
                finish("Failed: invalid port"); return
            }
            let client = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
            connection = client
            client.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    let request = Data("GET /__hotspot_health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".utf8)
                    client.send(content: request, completion: .contentProcessed { [weak self] error in
                        if let error { self?.finish("Failed: \(error)") }
                        else { self?.receive() }
                    })
                case .failed(let error): self.finish("Failed: \(error)")
                default: break
                }
            }
            client.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.finish("Timed out: no local response within 5 seconds")
            }
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, doneContext, done, error in
            guard let self, completion != nil else { return }
            if let data { response.append(data) }
            let text = String(decoding: response, as: UTF8.self)
            if text.hasPrefix("HTTP/1.1 200"), text.contains("Hotspot Proxy reachable") {
                finish("Passed: local TCP and HTTP work. iPad reachability is not tested.")
            } else if let error {
                finish("Failed: \(error)")
            } else if done || response.count >= 8192 {
                finish("Failed: unexpected or incomplete HTTP response")
            } else { receive() }
        }
    }

    private func finish(_ result: String) {
        guard let callback = completion else { return }
        completion = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        callback(result)
    }
}
