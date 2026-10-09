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
    private let selectHaptics = UISelectionFeedbackGenerator()

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            omnibox
            Divider()
            if omniboxFocused && !model.suggestions.isEmpty {
                suggestionsPanel
            }
            activePage
        }
        .background(Color(uiColor: .systemBackground))
        .sheet(item: $sharing) { item in
            ShareSheet(items: [item.url])
        }
        .sheet(isPresented: $showingSettings) {
            QwaveIOSSettingsView(model: model)
        }
        .onChange(of: model.energy.tier) { _ in
            model.applyEnergyTier()
        }
        .onAppear {
            closeHaptics.prepare()
        }
    }

    // MARK: - Tab strip

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.tabs) { tab in
                    TabPill(
                        title: model.displayTitle(for: tab),
                        isActive: tab.id == model.activeTabID,
                        onSelect: {
                            selectHaptics.selectionChanged()
                            model.selectTab(tab.id)
                        },
                        onClose: {
                            closeHaptics.impactOccurred()
                            model.closeTab(tab.id)
                        }
                    )
                }
                Button(action: model.newTab) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("t", modifiers: .command)
                .accessibilityLabel("New tab")
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
    }

    // MARK: - Omnibox

    private var omnibox: some View {
        HStack(spacing: 8) {
            Button(action: model.goBack) {
                Image(systemName: "chevron.left")
            }
            .disabled(!model.canGoBack)
            .keyboardShortcut("[", modifiers: .command)
            .accessibilityLabel("Back")

            Button(action: model.goForward) {
                Image(systemName: "chevron.right")
            }
            .disabled(!model.canGoForward)
            .keyboardShortcut("]", modifiers: .command)
            .accessibilityLabel("Forward")

            Button(action: model.reload) {
                Image(systemName: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .accessibilityLabel("Reload")

            TextField("Search or enter address", text: $model.address)
                .textFieldStyle(.roundedBorder)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .keyboardType(.webSearch)
                .focused($omniboxFocused)
                .onSubmit { model.navigate(model.address) }
                .onChange(of: model.address) { newValue in
                    model.updateSuggestions(newValue)
                }
                .accessibilityLabel("Search or enter address")

            if model.loading {
                ProgressView()
            }

            Button {
                if let active = model.tabs.first(where: { $0.id == model.activeTabID }),
                    let url = active.webView?.url ?? active.url ?? active.pendingURL
                {
                    sharing = SharingURL(url: url)
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("Share")

            Button { showingSettings = true } label: {
                Image(systemName: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .buttonStyle(.borderless)
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
            ReadingLanguageBar(webView: model.webView(for: active))
            QwaveWebView(
                webView: model.webView(for: active),
                model: model
            )
        } else {
            Text("No tab").foregroundStyle(.secondary)
        }
    }
}

private struct TabPill: View {
    let title: String
    let isActive: Bool
    var onSelect: () -> Void
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .lineLimit(1)
                .font(.footnote)
                .onTapGesture(perform: onSelect)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Close tab \(title)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isActive ? Color.accentColor.opacity(0.18) : Color(uiColor: .secondarySystemBackground))
        )
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
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // The view is stateful by design; navigation is driven by the model.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let model: BrowserViewModel
        var refreshControl: UIRefreshControl?

        init(model: BrowserViewModel) {
            self.model = model
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            model.loading = true
            model.canGoBack = webView.canGoBack
            model.canGoForward = webView.canGoForward
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            model.loading = false
            refreshControl?.endRefreshing()
            model.canGoBack = webView.canGoBack
            model.canGoForward = webView.canGoForward
            if let url = webView.url {
                model.address = url.absoluteString
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            model.loading = false
            refreshControl?.endRefreshing()
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            model.loading = false
            refreshControl?.endRefreshing()
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
