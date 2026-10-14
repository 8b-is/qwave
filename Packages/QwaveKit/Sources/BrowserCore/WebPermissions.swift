import AVFoundation
#if canImport(AppKit)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif
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

/// A snapshot of WebKit's security origin, including scheme and port. Never
/// derive this from the tab URL: a requesting frame can have a different origin.
public struct WebPermissionOrigin: Hashable, Sendable {
    public let scheme: String
    public let host: String
    public let port: Int

    public init(scheme: String, host: String, port: Int) {
        self.scheme = scheme.lowercased()
        self.host = host.lowercased()
        // WKSecurityOrigin uses zero when no port is present. Store the
        // effective HTTP(S) port so an explicit default port matches too.
        if port == 0, self.scheme == "https" {
            self.port = 443
        } else if port == 0, self.scheme == "http" {
            self.port = 80
        } else {
            self.port = port
        }
    }

    @MainActor
    public init(_ origin: WKSecurityOrigin) {
        self.init(scheme: origin.protocol, host: origin.host, port: origin.port)
    }

    var isValid: Bool {
        !scheme.isEmpty && !host.isEmpty && (0...65535).contains(port)
    }

    /// Include the scheme and nonstandard port so the consent prompt identifies
    /// the same boundary as the remembered choice. Bracket IPv6 hosts once.
    var displayName: String {
        let authority = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let isDefaultPort = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        let suffix = port == 0 || isDefaultPort ? "" : ":\(port)"
        return "\(scheme)://\(authority)\(suffix)"
    }
}

/// Identifies a decision inside container isolation. The same origin is answered
/// independently in each container (and in the default, container-less space),
/// so a camera grant in a personal container never leaks into a work one.
public struct WebPermissionKey: Hashable, Sendable {
    public let containerID: UUID?
    public let origin: WebPermissionOrigin
    public let permission: WebPermission

    public init(containerID: UUID?, origin: WebPermissionOrigin, permission: WebPermission) {
        self.containerID = containerID
        self.origin = origin
        self.permission = permission
    }
}

/// Session-scoped memory of camera / microphone / location choices, keyed per
/// (container, origin, capability). Deliberately not persisted: a privacy-first
/// browser forgets grants when it quits, so a site must re-ask next launch.
/// Persistent tabs share a store; each nonpersistent tab has its own store.
/// MainActor isolation keeps decisions and invalidation ordered.
@MainActor
public final class WebPermissionStore {
    public static let shared = WebPermissionStore()

    private var decisions: [WebPermissionKey: WebPermissionDecision] = [:]
    private var generation: UInt64 = 0
    private var containerGenerations: [UUID?: UInt64] = [:]

    struct Revision: Equatable {
        let generation: UInt64
        let containerGeneration: UInt64
    }

    func revision(for containerID: UUID?) -> Revision {
        Revision(generation: generation, containerGeneration: containerGenerations[containerID, default: 0])
    }

    public init() {}

    public func decision(for key: WebPermissionKey) -> WebPermissionDecision? {
        decisions[key]
    }

    public func record(_ decision: WebPermissionDecision, for key: WebPermissionKey) {
        decisions[key] = decision
    }

    /// Forget this container's choices and invalidate its pending requests.
    /// Other containers keep both their choices and their in-flight requests.
    public func reset(containerID: UUID?) {
        decisions = decisions.filter { $0.key.containerID != containerID }
        containerGenerations[containerID, default: 0] &+= 1
    }

    /// Forget every decision and invalidate pending requests for this store.
    public func reset() {
        decisions.removeAll()
        generation &+= 1
        containerGenerations.removeAll()
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
    /// Internal test seam: tests never need real consent sheets or device access.
    struct Environment {
        var prompt: @MainActor @Sendable (WebPermissionOrigin, [WebPermission]) -> Bool
        var captureAccess: @MainActor @Sendable (AVMediaType) async -> Bool

        static var live: Self {
            Self(prompt: promptUser, captureAccess: systemCaptureAccess)
        }
    }

    /// Map a media-capture request to the concrete capabilities it needs.
    public static func permissions(for type: WKMediaCaptureType) -> [WebPermission] {
        switch type {
        case .camera: return [.camera]
        case .microphone: return [.microphone]
        case .cameraAndMicrophone: return [.camera, .microphone]
        @unknown default: return []
        }
    }

    /// Resolve a `getUserMedia` request for the complete origin within `containerID`.
    public static func decideMediaCapture(
        origin: WebPermissionOrigin,
        type: WKMediaCaptureType,
        containerID: UUID?,
        store: WebPermissionStore = .shared,
        completion: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        decideMediaCapture(
            origin: origin, type: type, containerID: containerID, store: store,
            environment: .live, completion: completion)
    }

    static func decideMediaCapture(
        origin: WebPermissionOrigin,
        type: WKMediaCaptureType,
        containerID: UUID?,
        store: WebPermissionStore,
        environment: Environment,
        completion: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        let perms = permissions(for: type)
        guard !perms.isEmpty, origin.isValid else { completion(.deny); return }

        let keys = perms.map {
            WebPermissionKey(containerID: containerID, origin: origin, permission: $0)
        }
        // A single prior "deny" for any requested capability is decisive.
        if keys.contains(where: { store.decision(for: $0) == .deny }) {
            completion(.deny)
            return
        }
        let revision = store.revision(for: containerID)

        Task { @MainActor in
            guard store.revision(for: containerID) == revision else { completion(.deny); return }
            // Another request may have completed before this task began.
            guard !keys.contains(where: { store.decision(for: $0) == .deny }) else {
                completion(.deny); return
            }
            let undecided = keys.filter { store.decision(for: $0) == nil }
            if !undecided.isEmpty {
                let allow = environment.prompt(origin, undecided.map(\.permission))
                // A modal sheet runs a nested event loop. Deletion or tab
                // teardown during that loop must not resurrect old consent.
                guard store.revision(for: containerID) == revision else { completion(.deny); return }
                for key in undecided { store.record(allow ? .allow : .deny, for: key) }
                guard allow else { completion(.deny); return }
            }
            // Web-level consent granted; now clear the OS-level (TCC) gate.
            var granted = true
            if perms.contains(.camera) {
                granted = await environment.captureAccess(.video) && granted
                guard store.revision(for: containerID) == revision else { completion(.deny); return }
            }
            if perms.contains(.microphone) {
                granted = await environment.captureAccess(.audio) && granted
                guard store.revision(for: containerID) == revision else { completion(.deny); return }
            }
            completion(granted ? .grant : .deny)
        }
    }

    /// Resolve a Geolocation API request for the complete origin within `containerID`.
    public static func decideGeolocation(
        origin: WebPermissionOrigin,
        containerID: UUID?,
        store: WebPermissionStore = .shared,
        completion: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        decideGeolocation(
            origin: origin, containerID: containerID, store: store,
            environment: .live, completion: completion)
    }

    static func decideGeolocation(
        origin: WebPermissionOrigin,
        containerID: UUID?,
        store: WebPermissionStore,
        environment: Environment,
        completion: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        guard origin.isValid else { completion(.deny); return }
        let key = WebPermissionKey(containerID: containerID, origin: origin, permission: .location)
        if let decided = store.decision(for: key) {
            completion(decided == .allow ? .grant : .deny)
            return
        }
        let revision = store.revision(for: containerID)
        Task { @MainActor in
            guard store.revision(for: containerID) == revision else { completion(.deny); return }
            if let decided = store.decision(for: key) {
                completion(decided == .allow ? .grant : .deny)
                return
            }
            let allow = environment.prompt(origin, [.location])
            guard store.revision(for: containerID) == revision else { completion(.deny); return }
            store.record(allow ? .allow : .deny, for: key)
            completion(allow ? .grant : .deny)
        }
    }

    /// A modal per-origin allow/deny sheet. Returns `true` on Allow.
    private static func promptUser(origin: WebPermissionOrigin, permissions: [WebPermission]) -> Bool {
        #if os(macOS)
            let alert = NSAlert()
            alert.messageText = "“\(origin.displayName)” wants to use your \(joined(permissions))"
            alert.informativeText =
                "Qwave only shares this while you are on this site, and forgets the choice when you quit."
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Don’t Allow")
            return alert.runModal() == .alertFirstButtonReturn
        #else
            // The iOS UI layer (Phase 1) presents this sheet from a view
            // controller; until then, fail closed (deny).
            return false
        #endif
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
