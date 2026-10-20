import SwiftUI
import UIKit

struct DiagnosticsView: View {
    @EnvironmentObject var m: ProxyModel
    @State private var copied = false

    var body: some View {
        List {
            Section("Server") {
                LabeledContent("Listener", value: m.listenerStatus)
                LabeledContent("Accepted since start", value: String(m.acceptedConnections))
                Text("This count includes local checks. A successful local check does not prove that the iPad can reach this phone.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button(m.checkingLocal ? "Checking…" : "Test on This iPhone") { m.checkLocalServer() }
                    .disabled(!m.running || m.checkingLocal)
                Text(m.localCheck).font(.footnote).textSelection(.enabled)
            }
            Section("Test from the iPad") {
                Text("Temporarily turn the iPad’s Wi-Fi proxy off. Open the address below in Safari. A reachable server returns “Hotspot Proxy reachable”.")
                if let endpoint = m.endpoint {
                    Text("http://\(endpoint)/__hotspot_health")
                        .font(.footnote.monospaced()).textSelection(.enabled)
                }
                Text("The detected hotspot address is a candidate, not a verified route from the iPad.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Recent Events") {
                if m.diagnosticEvents.isEmpty { Text("No events yet") }
                ForEach(Array(m.diagnosticEvents.enumerated()), id: \.offset) { _, event in
                    Text(event).font(.footnote.monospaced()).textSelection(.enabled)
                }
            }
            Section("Local IPv4 / IPv6 Addresses") {
                ForEach(Array(m.addresses.enumerated()), id: \.offset) { _, address in
                    CopyableRow(title: address.0, value: address.1)
                }
                Text("Addresses belong to different interfaces. Not every address can be reached from the hotspot. IPv6 addresses with a % scope need client-specific handling.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button(copied ? "Copied" : "Copy Diagnostic Report") {
                    UIPasteboard.general.string = m.diagnosticReport
                    copied = true
                }
                Text("The report contains local interface addresses, build and OS versions, and recent server events. Browsing URLs and request contents are not recorded.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Connection Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }
}
