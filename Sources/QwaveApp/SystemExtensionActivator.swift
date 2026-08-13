import Foundation
@preconcurrency import SystemExtensions
import QwaveSupport

/// Submits the OSSystemExtensionRequest that installs the packet-tunnel
/// system extension. Only succeeds in a signed build running from
/// /Applications (see docs/SIGNING.md); in an unsigned dev build the request
/// fails and the status callback says so — the browser is unaffected.
@MainActor
final class SystemExtensionActivator: NSObject, @MainActor OSSystemExtensionRequestDelegate {
    /// Shared instance so the delegate outlives SwiftUI view churn while a
    /// request is in flight.
    static let shared = SystemExtensionActivator()

    static let extensionIdentifier = "is.8b.qwave.tunnel"

    private var onStatus: ((String) -> Void)?

    func activate(onStatus: @escaping (String) -> Void) {
        self.onStatus = onStatus
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    // MARK: - OSSystemExtensionRequestDelegate

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        onStatus?("Approve the extension in System Settings → Privacy & Security.")
        QwaveLog.vpn.info("System extension awaiting user approval")
    }

    func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        switch result {
        case .completed:
            onStatus?("VPN extension installed. You can connect now.")
        case .willCompleteAfterReboot:
            onStatus?("VPN extension will finish installing after a reboot.")
        @unknown default:
            onStatus?("VPN extension: unknown result.")
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        onStatus?("Extension install failed: \(error.localizedDescription) — see docs/SIGNING.md.")
        QwaveLog.vpn.error("System extension activation failed: \(error.localizedDescription, privacy: .public)")
    }
}
