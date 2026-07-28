import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

struct RemoteMonitoringPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var bridge: MonitorBridge

    var body: some View {
        GroupBox("Remote Monitoring") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $model.remoteMonitoringEnabled) {
                    Label("Phone / tablet console", systemImage: "iphone.gen3")
                }
                .toggleStyle(.switch)

                if model.remoteMonitoringEnabled {
                    HStack {
                        Text("Status").foregroundStyle(.secondary)
                        Spacer()
                        Text(bridge.listeningStatus)
                            .foregroundStyle(bridge.listeningStatus.hasPrefix("failed") ? .orange : .primary)
                    }
                    .font(.caption)

                    HStack(alignment: .top, spacing: 14) {
                        if let qr = QRCodeImage.make(for: bridge.urlString) {
                            Image(nsImage: qr)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 92, height: 92)
                                .padding(6)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text(bridge.urlString)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 8) {
                                Text("Pairing code")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(bridge.pairingCode)
                                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                                    .textSelection(.enabled)
                            }
                            Text("\(bridge.connectedClientCount) viewing · \(bridge.pairedClientCount) paired")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button(role: .destructive) {
                                bridge.revokeAllPairings()
                            } label: {
                                Label("Revoke all", systemImage: "lock.rotation")
                            }
                            .controlSize(.small)
                            .disabled(bridge.pairedClientCount == 0)
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Label("Fail-safe primary heartbeat", systemImage: "waveform.path.ecg")
                            .font(.caption.weight(.semibold))
                        Text(bridge.primaryHeartbeatURLString)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                        Text(bridge.primaryHeartbeatStatus)
                            .font(.caption)
                            .foregroundStyle(
                                bridge.primaryHeartbeatStatus.hasPrefix("healthy")
                                    ? .green
                                    : .orange
                            )
                        Text("An external fail-safe controller may poll this token-free URL. Any non-200 response, stale payload, or unreachable app must select backup; return to primary stays manual at the external switch.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("Open the URL on a phone on this Wi-Fi, enter the code to control, and Add to Home Screen for background alerts. macOS may ask to allow incoming connections the first time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

@MainActor
enum QRCodeImage {
    // QR generation (CoreImage) is expensive; the URL is stable, so memoize by string
    // instead of regenerating on every SwiftUI body evaluation (~10x/sec).
    private static var cache: [String: NSImage] = [:]

    static func make(for string: String) -> NSImage? {
        if let hit = cache[string] { return hit }
        let image = render(for: string)
        if let image { cache[string] = image }
        return image
    }

    private static func render(for string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = context.createCGImage(output, from: output.extent) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
