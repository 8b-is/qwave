// BrowserView.swift — the SwiftUI browser surface.
//
// Omnibox, tab strip, and the WebKit web view, bound to the shared
// BrowserCore model. Minimum device: iPhone 13 (iOS 15). Every control here
// is SwiftUI; nothing reaches for AppKit.

import SwiftUI
import WebKit
import BrowserCore

struct BrowserView: View {
    @ObservedObject var model: BrowserViewModel

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            omnibox
            Divider()
            activePage
        }
        .background(Color(uiColor: .systemBackground))
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.tabs) { tab in
                    TabPill(
                        title: tab.title.isEmpty ? (tab.pendingURL?.host ?? "New Tab") : tab.title,
                        isActive: tab.id == model.activeTabID,
                        onSelect: { model.activeTabID = tab.id },
                        onClose: { model.closeTab(tab.id) }
                    )
                }
                Button(action: model.newTab) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var omnibox: some View {
        HStack(spacing: 8) {
            if let active = model.tabs.first(where: { $0.id == model.activeTabID }) {
                Button {
                    let webView = model.webView(for: active)
                    if webView.canGoBack { webView.goBack() }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!model.canGoBack)

                Button {
                    let webView = model.webView(for: active)
                    if webView.canGoForward { webView.goForward() }
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!model.canGoForward)

                Button {
                    model.webView(for: active).reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }

            TextField("Search or enter address", text: $model.address)
                .textFieldStyle(.roundedBorder)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .keyboardType(.webSearch)
                .onSubmit { model.navigate(model.address) }

            if model.loading {
                ProgressView()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var activePage: some View {
        if let active = model.tabs.first(where: { $0.id == model.activeTabID }) {
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
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isActive ? Color.accentColor.opacity(0.18) : Color(uiColor: .secondarySystemBackground))
        )
    }
}

/// The WebKit view: one `WKWebView` per tab, kept alive across SwiftUI
/// updates so the page state (scroll, form data) survives tab switches.
struct QwaveWebView: UIViewRepresentable {
    let webView: WKWebView
    @ObservedObject var model: BrowserViewModel

    func makeUIView(context: Context) -> WKWebView {
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
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
            model.canGoBack = webView.canGoBack
            model.canGoForward = webView.canGoForward
            if let url = webView.url {
                model.address = url.absoluteString
            }
            // Title updates belong to BrowserCore's NavigationCoordinator; the
            // shell keeps the tab title until the full coordinator wiring lands.
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            model.loading = false
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
