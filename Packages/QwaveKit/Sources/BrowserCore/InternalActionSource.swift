import WebKit

/// The originating tab and document survive an async shell handoff without
/// turning a background page's request into an action on the selected tab.
@MainActor
public struct InternalActionSource {
    public private(set) weak var tab: Tab?
    public private(set) weak var webView: WKWebView?
    private weak var coordinator: NavigationCoordinator?
    private let generation: UUID

    init(coordinator: NavigationCoordinator, tab: Tab, webView: WKWebView, generation: UUID) {
        self.coordinator = coordinator
        self.tab = tab
        self.webView = webView
        self.generation = generation
    }

    public func isCurrent(selectedTab: Tab?) -> Bool {
        guard let tab, let webView, selectedTab === tab, tab.webView === webView else { return false }
        return coordinator?.internalActionGeneration == generation
    }
}
