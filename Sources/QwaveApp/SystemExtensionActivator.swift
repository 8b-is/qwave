import Foundation
@preconcurrency import SystemExtensions
import QwaveSupport

/// Submits the OSSystemExtensionRequest that installs the packet-tunnel
/// system extension. Only succeeds in a signed build running from
/// /Applications (see docs/SIGNING.md); in an unsigned dev build the request
/// fails and the status callback says so — the browser is unaffected.
@MainActor
final class SystemExtensionActivator: NSObject, OSSystemExtensionRequestDelegate {
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

    // The protocol requirements are nonisolated, so the callbacks are declared
    // `nonisolated` and hop onto the main actor explicitly. `activate` submits
    // the request with `queue: .main`, so the callbacks always land on the main
    // queue and `assumeIsolated` is sound.

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        MainActor.assumeIsolated {
            onStatus?("Approve the extension in System Settings → Privacy & Security.")
            QwaveLog.vpn.info("System extension awaiting user approval")
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        MainActor.assumeIsolated {
            switch result {
            case .completed:
                onStatus?("VPN extension installed. You can connect now.")
            case .willCompleteAfterReboot:
                onStatus?("VPN extension will finish installing after a reboot.")
            @unknown default:
                onStatus?("VPN extension: unknown result.")
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            onStatus?("Extension install failed: \(error.localizedDescription) — see docs/SIGNING.md.")
            QwaveLog.vpn.error("System extension activation failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
