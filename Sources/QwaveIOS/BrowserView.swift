// BrowserView.swift — the SwiftUI browser surface.
//
// Omnibox (with on-device + opt-in engine suggestions), tab strip, and the
// WebKit web view, bound to the shared BrowserCore model. Minimum device:
// iPhone 13 (iOS 15). Every control here is SwiftUI; nothing reaches for
// AppKit. The iOS feature set is used deliberately — pull-to-refresh,
// hardware keyboard shortcuts, the share sheet, haptics, and VoiceOver
// labels — and the battery policy reacts to Low Power Mode and thermal
// pressure.

import SwiftUI
import WebKit
import BrowserCore

struct BrowserView: View {
    @ObservedObject var model: BrowserViewModel
    @FocusState private var omniboxFocused: Bool
    @State private var sharing: SharingURL?
    @State private var showingSettings = false

    private let closeHaptics = UIImpactFeedbackGenerator(style: .light)

    @State private var sidebarVisible = true
    @Environment(\.dynamicTypeSize) private var typeSize
    private let waveAccent = Color(red: 0.22, green: 0.67, blue: 0.72)

    var body: some View {
        GeometryReader { geometry in
            let spacious = geometry.size.width >= 700 && !typeSize.isAccessibilitySize
            let showsSidebar = spacious && geometry.size.width >= 1000 && sidebarVisible
            HStack(spacing: 0) {
                if showsSidebar {
                    sidebar.frame(width: 244)
                    Divider()
                }
                VStack(spacing: 0) {
                    toolbar(spacious: spacious, canToggleSidebar: geometry.size.width >= 1000)
                    if !showsSidebar { tabStrip }
                    Divider()
                    if omniboxFocused && !model.suggestions.isEmpty { suggestionsPanel }
                    activePage
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(uiColor: .systemBackground))
            .tint(waveAccent)
        }
        .sheet(item: $sharing) { item in ShareSheet(items: [item.url]) }
        .sheet(isPresented: $showingSettings) { QwaveIOSSettingsView(model: model) }
        .onChange(of: model.energy.tier) { _ in model.applyEnergyTier() }
        .onAppear { closeHaptics.prepare() }
        .alert("Memory Wave", isPresented: Binding(get: { model.memoryNotice != nil },
            set: { if !$0 { model.memoryNotice = nil } })) {
            Button("OK") { model.memoryNotice = nil }
        } message: { Text(model.memoryNotice ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Image(systemName: "waveform").font(.title2).foregroundStyle(waveAccent)
                Text("Qwave").font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(.top, 12)
            Button(action: model.newTab) {
                Label("New tab", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(waveAccent.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("t", modifiers: .command)
            HStack {
                Text("YOUR TABS").font(.caption.weight(.semibold)).tracking(1.5)
                Spacer()
                Text("\(model.tabs.count)").font(.caption.monospacedDigit())
            }.foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.tabs) { tab in
                            tabRow(tab).id(tab.id)
                        }
                    }
                }
                .onChange(of: model.activeTabID) { id in proxy.scrollTo(id) }
            }
            Spacer(minLength: 0)
            Button { showingSettings = true } label: {
                Label("Settings", systemImage: "slider.horizontal.3")
                    .font(.subheadline).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }.buttonStyle(.plain)
            Text("A little more room to explore.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(18)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private func tabRow(_ tab: BrowserTab) -> some View {
        HStack(spacing: 0) {
            Button { model.selectTab(tab.id) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "globe").foregroundStyle(waveAccent)
                    Text(model.displayTitle(for: tab)).font(.subheadline).lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 12).frame(maxWidth: .infinity, minHeight: 52)
                .contentShape(Rectangle())
            }
            .accessibilityAddTraits(tab.id == model.activeTabID ? .isSelected : [])
            Button { model.closeTab(tab.id) } label: {
                Image(systemName: "xmark").font(.caption).frame(width: 44, height: 52)
            }
            .disabled(model.tabs.count == 1)
            .accessibilityLabel("Close tab \(model.displayTitle(for: tab))")
        }
        .buttonStyle(.plain)
        .background(tab.id == model.activeTabID ? waveAccent.opacity(0.16) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 12))
    }

    private var tabStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.tabs) { tab in
                        TabPill(title: model.displayTitle(for: tab),
                                isActive: tab.id == model.activeTabID,
                                canClose: model.tabs.count > 1,
                                onSelect: { model.selectTab(tab.id) },
                                onClose: { model.closeTab(tab.id) })
                            .id(tab.id)
                    }
                    Button(action: model.newTab) {
                        Image(systemName: "plus").frame(width: 44, height: 44)
                    }
                    .keyboardShortcut("t", modifiers: .command)
                    .accessibilityLabel("New tab")
                }.padding(.horizontal, 12).padding(.vertical, 6)
            }
            .onChange(of: model.activeTabID) { id in proxy.scrollTo(id) }
        }
        .buttonStyle(.plain)
        .background(Color(uiColor: .secondarySystemBackground))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
    }

    private func toolbar(spacious: Bool, canToggleSidebar: Bool) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                if spacious {
                    if canToggleSidebar {
                        Button { sidebarVisible.toggle() } label: {
                            Image(systemName: "sidebar.left").frame(width: 44, height: 44)
                        }.accessibilityLabel("Toggle tab sidebar")
                    }
                    navigationControls
                }
                addressField
                if spacious { pageControls }
            }
            if !spacious {
                HStack {
                    navigationControls
                    Spacer(minLength: 0)
                    pageControls
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, spacious ? 18 : 12)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var addressField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search or enter address", text: $model.address)
                .textFieldStyle(.plain)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .keyboardType(.webSearch)
                .submitLabel(.go)
                .focused($omniboxFocused)
                .onSubmit {
                    omniboxFocused = false
                    model.navigate(model.address)
                }
                .onChange(of: model.address) { value in
                    if omniboxFocused { model.updateSuggestions(value) }
                }
                .accessibilityLabel("Search or enter address")
            if model.loading { ProgressView().scaleEffect(0.8) }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 46)
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(
            omniboxFocused ? waveAccent : Color.primary.opacity(0.10), lineWidth: 1))
    }

    private var navigationControls: some View {
        HStack(spacing: 0) {
            Button(action: model.goBack) {
                Image(systemName: "chevron.left").frame(width: 44, height: 44)
            }.disabled(!model.canGoBack).keyboardShortcut("[", modifiers: .command).accessibilityLabel("Back")
            Button(action: model.goForward) {
                Image(systemName: "chevron.right").frame(width: 44, height: 44)
            }.disabled(!model.canGoForward).keyboardShortcut("]", modifiers: .command).accessibilityLabel("Forward")
            Button(action: model.reload) {
                Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
            }.keyboardShortcut("r", modifiers: .command).accessibilityLabel("Reload")
        }
    }

    private var pageControls: some View {
        HStack(spacing: 0) {
            Button {
                if let active = model.tabs.first(where: { $0.id == model.activeTabID }),
                   let url = active.webView?.url ?? active.url ?? active.pendingURL {
                    sharing = SharingURL(url: url)
                }
            } label: { Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44) }
            .accessibilityLabel("Share")
            Button {
                if let active = model.tabs.first(where: { $0.id == model.activeTabID }) {
                    ReadingLanguageControls.show(for: model.webView(for: active))
                }
            } label: { Image(systemName: "character.bubble").frame(width: 44, height: 44) }
            .accessibilityLabel("Translation")
            Menu {
                Button(action: model.rememberCurrentPage) { Label("Remember this page", systemImage: "bookmark") }
                Button { model.navigate(InternalPages.startURL.absoluteString) } label: { Label("Memory Wave home", systemImage: "waveform") }
            } label: { Image(systemName: "waveform").frame(width: 44, height: 44) }
            .accessibilityLabel("Memory Wave")
            Button { showingSettings = true } label: {
                Image(systemName: "gearshape").frame(width: 44, height: 44)
            }.keyboardShortcut(",", modifiers: .command).accessibilityLabel("Settings")
        }
    }

    // MARK: - Suggestions

    private var suggestionsPanel: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.suggestions.enumerated()), id: \.offset) { _, suggestion in
                    Button {
                        omniboxFocused = false
                        model.commitSuggestion(suggestion)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: suggestionIcon(suggestion))
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(suggestion.title)
                                    .lineLimit(1)
                                Text(suggestionSubtitle(suggestion))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: 220)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private func suggestionIcon(_ suggestion: OmniboxSuggestion) -> String {
        switch suggestion.kind {
        case .openTab: return "square.on.square"
        case .action: return "bolt"
        case .search: return "magnifyingglass"
        case .history, .bookmark: return "clock"
        }
    }

    private func suggestionSubtitle(_ suggestion: OmniboxSuggestion) -> String {
        switch suggestion.kind {
        case .openTab: return "Switch to tab"
        case .action: return "Quick action"
        case .search(let provider): return "\(provider) search"
        case .history: return "History"
        case .bookmark: return "Bookmark"
        }
    }

    // MARK: - Page

    @ViewBuilder private var activePage: some View {
        if let active = model.tabs.first(where: { $0.id == model.activeTabID }) {
            VStack(spacing: 0) {
                ReadingLanguageBar(webView: model.webView(for: active))
                QwaveWebView(webView: model.webView(for: active), model: model)
                    .id(active.id)
            }
        }
    }
}

private struct TabPill: View {
    let title: String
    let isActive: Bool
    let canClose: Bool
    var onSelect: () -> Void
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSelect) {
                Text(title).lineLimit(1).font(.subheadline)
                    .frame(minWidth: 80, maxWidth: 180, minHeight: 44)
                    .padding(.leading, 12).contentShape(Rectangle())
            }
            .accessibilityAddTraits(isActive ? .isSelected : [])
            Button(action: onClose) {
                Image(systemName: "xmark").font(.caption).frame(width: 44, height: 44)
            }
            .disabled(!canClose)
            .accessibilityLabel("Close tab \(title)")
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(isActive ? Color.accentColor.opacity(0.16) : Color(uiColor: .tertiarySystemBackground)))
    }
}

/// An identifiable share target so `.sheet(item:)` works with a plain URL.
struct SharingURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// UIActivityViewController in a representable — the native iOS share sheet.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// The WebKit view: one `WKWebView` per tab, kept alive across SwiftUI
/// updates so the page state (scroll, form data) survives tab switches.
/// Pull-to-refresh is the native `UIRefreshControl` on the web view's own
/// scroll view.
struct QwaveWebView: UIViewRepresentable {
    let webView: WKWebView
    @ObservedObject var model: BrowserViewModel

    func makeUIView(context: Context) -> WKWebView {
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "qwave")
        webView.configuration.userContentController.add(context.coordinator, name: "qwave")
        // Native pull-to-refresh on the web view's own scroll view.
        let refresh = UIRefreshControl()
        refresh.addAction(
            UIAction { [weak webView] _ in
                webView?.reload()
            },
            for: .valueChanged
        )
        webView.scrollView.refreshControl = refresh
        context.coordinator.refreshControl = refresh
        // The factory configures a view; the shell owns its first navigation.
        if webView.url == nil,
           let tab = model.tabs.first(where: { $0.id == model.activeTabID }),
           let url = tab.pendingURL {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // The view is stateful by design; navigation is driven by the model.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "qwave")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame,
                  InternalPages.isStartURL(message.frameInfo.request.url),
                  InternalPages.isStartURL(message.webView?.url),
                  let webView = message.webView, isActive(webView),
                  let body = message.body as? [String: Any], body["type"] as? String == "submit",
                  let query = body["query"] as? String, query.count <= 4096 else { return }
            model.submitWaveQuery(query)
        }

        let model: BrowserViewModel
        var refreshControl: UIRefreshControl?

        init(model: BrowserViewModel) {
            self.model = model
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            guard isActive(webView) else { return }
            model.loading = true
            model.canGoBack = webView.canGoBack
            model.canGoForward = webView.canGoForward
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            refreshControl?.endRefreshing()
            guard isActive(webView) else { return }
            model.loading = false
            refreshControl?.endRefreshing()
            model.canGoBack = webView.canGoBack
            model.canGoForward = webView.canGoForward
            if let url = webView.url {
                model.address = url.absoluteString
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if isActive(webView) { model.loading = false }
            refreshControl?.endRefreshing()
            showOfflineArcade(webView, error: error)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            if isActive(webView) { model.loading = false }
            refreshControl?.endRefreshing()
            showOfflineArcade(webView, error: error)
        }

        private func isActive(_ webView: WKWebView) -> Bool {
            model.tabs.first(where: { $0.id == model.activeTabID })?.webView === webView
        }

        private func showOfflineArcade(_ webView: WKWebView, error: Error) {
            let error = error as NSError
            let failed = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
                ?? URL(string: model.address)
            if let arcade = OfflineArcade.pageURL(error: error, failingURL: failed) {
                webView.load(URLRequest(url: arcade))
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let request = ReadingLanguageRequest.adapted(action.request, mainFrame: action.targetFrame?.isMainFrame == true, currentURL: webView.url) {
                decisionHandler(.cancel)
                webView.load(request)
            } else { decisionHandler(.allow) }
        }

        // New windows (target=_blank etc.) open as new tabs.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url, navigationAction.targetFrame == nil {
                model.open(url)
            }
            return nil
        }
    }
}
