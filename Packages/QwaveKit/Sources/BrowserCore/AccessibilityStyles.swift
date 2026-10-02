import Foundation
import Persistence

/// Document-start injections for the appearance and accessibility settings.
///
/// Everything here is a pure string builder — no WebKit imports — so the
/// scripts themselves are unit-testable and the WebViewFactory wiring stays a
/// thin apply-the-current-settings step.
public enum AccessibilityStyles {
    /// The color-scheme hint injected when the user forces `.light` or
    /// `.dark` (`.system` gets nothing: the OS value is already right).
    ///
    /// Honest about its reach: the CSS `color-scheme` property restyles the
    /// UA-rendered surfaces — form controls, scrollbars, default backgrounds —
    /// and is honored by sites that adopt it, but it does NOT flip
    /// `prefers-color-scheme` media queries. WebKit offers no public API for
    /// that, and Qwave will not reach for SPI to fake one.
    public static func colorSchemeScript(for mode: ThemeMode) -> String? {
        switch mode {
        case .system: return nil
        case .light: return schemeInjection("light")
        case .dark: return schemeInjection("dark")
        }
    }

    /// The forced reduced-motion style. Collapses CSS animations and
    /// transitions to their final state and disables smooth scrolling, on
    /// every frame (the document style is injected per WebView, so iframes
    /// need the script to run in them too — `forMainFrameOnly: false`).
    public static let reduceMotionScript: String = """
        (function() {
            const css = '*, *::before, *::after { \
        animation-duration: 0.001s !important; \
        animation-iteration-count: 1 !important; \
        transition-duration: 0.001s !important; \
        scroll-behavior: auto !important; }';
            const style = document.createElement('style');
            style.textContent = css;
            (document.head || document.documentElement).appendChild(style);
        })();
        """

    /// A `<meta name="color-scheme">` plus a `:root` declaration. The meta
    /// tag reaches first paint; the `:root` rule covers engines that read the
    /// CSS property instead.
    private static func schemeInjection(_ scheme: String) -> String {
        """
        (function() {
            const meta = document.createElement('meta');
            meta.name = 'color-scheme';
            meta.content = '\(scheme)';
            (document.head || document.documentElement).appendChild(meta);
            const style = document.createElement('style');
            style.textContent = ':root { color-scheme: \(scheme); }';
            (document.head || document.documentElement).appendChild(style);
        })();
        """
    }
}
