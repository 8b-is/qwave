#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import WebKit

/// State captured when a background tab is torn down to save memory/energy.
public struct HibernationRecord {
    public var url: URL?
    public var title: String
    /// Opaque WebKit interaction state (back/forward list, scroll, form data).
    public var interactionState: Data?
    /// Last visual state, shown as a placeholder until restore completes.
    public var snapshot: PlatformImage?

    public init(url: URL?, title: String, interactionState: Data?, snapshot: PlatformImage?) {
        self.url = url
        self.title = title
        self.interactionState = interactionState
        self.snapshot = snapshot
    }
}

/// One browser tab. The web view is owned by the lifecycle state so that a
/// hibernated tab provably holds no WKWebView (and none of its processes).
@MainActor
public final class Tab: Identifiable {
    public enum Lifecycle {
        /// Created but never loaded (new-tab page).
        case fresh
        /// Live web view attached.
        case active(WKWebView)
        /// Torn down; record holds what's needed to restore.
        case hibernated(HibernationRecord)
    }

    public let id: UUID
    /// nil = the default container. Otherwise a `ContainerProfile` id.
    public let containerID: UUID?
    /// Ephemeral tabs use a non-persistent data store and never touch history.
    public let isEphemeral: Bool

    public private(set) var lifecycle: Lifecycle = .fresh
    public internal(set) var url: URL?
    public internal(set) var title: String = ""
    public internal(set) var isLoading = false
    public internal(set) var estimatedProgress: Double = 0
    public var isPinned = false
    /// Site favicon, fetched by the app layer (per-container cache; the
    /// fetch itself carries no cookies — see FaviconLoader).
    public var favicon: PlatformImage?
    public private(set) var lastActivated = Date()

    /// The URL to load once a web view exists (set when a tab is created for
    /// a target URL before its web view is built; cleared by the app layer
    /// after the first load).
    public var pendingURL: URL?

    /// Opaque WebKit `interactionState` (back/forward list, scroll, form data)
    /// to restore once a web view exists — set when a tab is rebuilt from a
    /// persisted session or reopened from the closed-tab ring, and cleared by
    /// the app layer after it is applied.
    public var pendingInteractionState: Data?

    public init(id: UUID = UUID(), containerID: UUID? = nil, isEphemeral: Bool = false, pendingURL: URL? = nil) {
        self.id = id
        self.containerID = containerID
        self.isEphemeral = isEphemeral
        self.pendingURL = pendingURL
    }

    public var webView: WKWebView? {
        if case .active(let webView) = lifecycle { return webView }
        return nil
    }

    public var isHibernated: Bool {
        if case .hibernated = lifecycle { return true }
        return false
    }

    public var hibernationRecord: HibernationRecord? {
        if case .hibernated(let record) = lifecycle { return record }
        return nil
    }

    /// Display title with sensible fallbacks.
    public var displayTitle: String {
        if !title.isEmpty { return title }
        if let host = url?.host { return host }
        return "New Tab"
    }

    public func noteActivated(at date: Date = Date()) {
        lastActivated = date
    }

    // MARK: - Lifecycle transitions (internal to BrowserCore)

    public func attach(webView: WKWebView) {
        lifecycle = .active(webView)
    }

    public func hibernate(with record: HibernationRecord) {
        lifecycle = .hibernated(record)
    }

    public func markFresh() {
        lifecycle = .fresh
    }
}
