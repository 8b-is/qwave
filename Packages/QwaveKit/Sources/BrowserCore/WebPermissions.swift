import AVFoundation
import AppKit
import WebKit

/// A capability a web origin can ask for. Camera and microphone back
/// `getUserMedia`; location backs the Geolocation API. Web Push is deliberately
/// absent — it needs an APNs entitlement Qwave does not ship.
public enum WebPermission: String, Sendable, CaseIterable {
    case camera
    case microphone
    case location

    /// A short noun for prompt copy ("wants to use your camera").
    var noun: String {
        switch self {
        case .camera: return "camera"
        case .microphone: return "microphone"
        case .location: return "location"
        }
    }
}

/// The user's answer for one (container, origin, capability) triple.
public enum WebPermissionDecision: Sendable {
    case allow
    case deny
}

/// Identifies a decision inside container isolation. The same origin is answered
/// independently in each container (and in the default, container-less space),
/// so a camera grant in a personal container never leaks into a work one. Host
/// is compared case-insensitively.
public struct WebPermissionKey: Hashable, Sendable {
    public let containerID: UUID?
    public let originHost: String
    public let permission: WebPermission

    public init(containerID: UUID?, originHost: String, permission: WebPermission) {
        self.containerID = containerID
        self.originHost = originHost.lowercased()
        self.permission = permission
    }
}

/// Session-scoped memory of camera / microphone / location choices, keyed per
/// (container, origin, capability). Deliberately not persisted: a privacy-first
/// browser forgets grants when it quits, so a site must re-ask next launch.
/// MainActor-isolated, so a single shared instance is safe across every tab's
/// coordinator.
@MainActor
public final class WebPermissionStore {
    public static let shared = WebPermissionStore()

    private var decisions: [WebPermissionKey: WebPermissionDecision] = [:]

    public init() {}

    public func decision(for key: WebPermissionKey) -> WebPermissionDecision? {
        decisions[key]
    }

    public func record(_ decision: WebPermissionDecision, for key: WebPermissionKey) {
        decisions[key] = decision
    }

    /// Forget every decision — used when the user clears site data.
    public func reset() {
        decisions.removeAll()
    }
}

/// Turns a WebKit permission request into a decision: consult remembered
/// choices, prompt the user for anything undecided, drive the system (TCC)
/// prompt for camera/microphone on allow, and hand WebKit the final grant/deny.
///
/// The TCC step matters: `AVCaptureDevice.requestAccess` is what surfaces the
/// macOS camera/microphone consent sheet (backed by the `NS*UsageDescription`
/// strings in Info.plist). Without those strings the first `getUserMedia` used
/// to hard-kill the process; granting here now flows through TCC cleanly.
/// Geolocation has no `AVCaptureDevice` analogue — once we return `.grant`,
/// WebKit's own CoreLocation provider raises the location TCC prompt using
/// `NSLocationWhenInUseUsageDescription`.
@MainActor
public enum WebPermissionArbiter {
    /// Map a media-capture request to the concrete capabilities it needs.
    public static func permissions(for type: WKMediaCaptureType) -> [WebPermission] {
        switch type {
        case .camera: return [.camera]
        case .microphone: return [.microphone]
        case .cameraAndMicrophone: return [.camera, .microphone]
        @unknown default: return []
        }
    }

    /// Resolve a `getUserMedia` request for `origin`'s host within `containerID`.
    public static func decideMediaCapture(
        host: String,
        type: WKMediaCaptureType,
        containerID: UUID?,
        store: WebPermissionStore = .shared,
        completion: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        let perms = permissions(for: type)
        guard !perms.isEmpty, !host.isEmpty else { completion(.deny); return }

        let keys = perms.map {
            WebPermissionKey(containerID: containerID, originHost: host, permission: $0)
        }
        // A single prior "deny" for any requested capability is decisive.
        if keys.contains(where: { store.decision(for: $0) == .deny }) {
            completion(.deny)
            return
        }
        let undecided = keys.filter { store.decision(for: $0) == nil }

        Task { @MainActor in
            if !undecided.isEmpty {
                let allow = promptUser(host: host, permissions: undecided.map(\.permission))
                for key in undecided { store.record(allow ? .allow : .deny, for: key) }
                guard allow else { completion(.deny); return }
            }
            // Web-level consent granted; now clear the OS-level (TCC) gate.
            var granted = true
            if perms.contains(.camera) { granted = await systemCaptureAccess(.video) && granted }
            if perms.contains(.microphone) { granted = await systemCaptureAccess(.audio) && granted }
            completion(granted ? .grant : .deny)
        }
    }

    /// Resolve a Geolocation API request for `origin`'s host within `containerID`.
    public static func decideGeolocation(
        host: String,
        containerID: UUID?,
        store: WebPermissionStore = .shared,
        completion: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        guard !host.isEmpty else { completion(.deny); return }
        let key = WebPermissionKey(containerID: containerID, originHost: host, permission: .location)
        if let decided = store.decision(for: key) {
            completion(decided == .allow ? .grant : .deny)
            return
        }
        Task { @MainActor in
            let allow = promptUser(host: host, permissions: [.location])
            store.record(allow ? .allow : .deny, for: key)
            completion(allow ? .grant : .deny)
        }
    }

    /// A modal per-origin allow/deny sheet. Returns `true` on Allow.
    private static func promptUser(host: String, permissions: [WebPermission]) -> Bool {
        let alert = NSAlert()
        alert.messageText = "“\(host)” wants to use your \(joined(permissions))"
        alert.informativeText = "Qwave only shares this while you are on this site, and forgets the choice when you quit."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don’t Allow")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// "camera", "camera and microphone", "camera, microphone, and location".
    private static func joined(_ permissions: [WebPermission]) -> String {
        let nouns = permissions.map(\.noun)
        switch nouns.count {
        case 0: return ""
        case 1: return nouns[0]
        case 2: return "\(nouns[0]) and \(nouns[1])"
        default: return nouns.dropLast().joined(separator: ", ") + ", and " + nouns[nouns.count - 1]
        }
    }

    /// Bring the given capture device to an authorized state, raising the macOS
    /// TCC prompt on first use. Returns whether capture is permitted.
    private static func systemCaptureAccess(_ media: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: media)
        case .denied, .restricted: return false
        @unknown default: return false
        }
    }
}
