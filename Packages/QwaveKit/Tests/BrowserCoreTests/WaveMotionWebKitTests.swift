import XCTest
import WebKit
@testable import BrowserCore

@MainActor
final class WaveMotionWebKitTests: XCTestCase {
    func testRealWebGLRepaintsStaticScene() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // An offscreen WKWebView is hidden. Control visibility and preference signals
        // explicitly without showing a window or changing the user's OS settings.
        // Shader compilation, WebGL drawing and pixel readback remain native WebKit.
        let instrument = """
            let hidden = true;
            Object.defineProperty(document, 'hidden', { get: () => hidden });
            window.setWaveHidden = value => { hidden = value; document.dispatchEvent(new Event('visibilitychange')); };
            window.waveDraws = 0;
            window.waveErrors = [];
            window.addEventListener('error', event => waveErrors.push(event.message));
            const draw = WebGLRenderingContext.prototype.drawArrays;
            WebGLRenderingContext.prototype.drawArrays = function(...args) {
                window.waveDraws++;
                const result = draw.apply(this, args);
                const pixel = new Uint8Array(4);
                this.readPixels(Math.floor(this.drawingBufferWidth / 2), Math.floor(this.drawingBufferHeight / 2), 1, 1, this.RGBA, this.UNSIGNED_BYTE, pixel);
                window.wavePixel = Array.from(pixel);
                window.waveGLError = this.getError();
                return result;
            };
            const media = new EventTarget();
            media.matches = true;
            const originalMatchMedia = window.matchMedia.bind(window);
            window.matchMedia = query => query === '(prefers-reduced-motion: reduce)' ? media : originalMatchMedia(query);
            window.setWaveMotion = value => { media.matches = value; media.dispatchEvent(new Event('change')); };
            """
        configuration.userContentController.addUserScript(
            WKUserScript(source: instrument, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        let html = """
            <html><head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
            <body><canvas id="glCanvas"></canvas>
            <script id="fragShader" type="x-shader/x-fragment">\(WaveScene.fragmentShader)</script>
            <script>\(WaveScene.canvasScript)</script></body></html>
            """
        view.loadHTMLString(html, baseURL: nil)
        defer { view.stopLoading() }
        var ready = false
        for _ in 0..<50 {
            ready =
                (try? await view.evaluateJavaScript(
                    "document.readyState === 'complete' && typeof window.setWaveMotion === 'function'") as? Bool)
                == true
            if ready { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let diagnostic = try? await view.evaluateJavaScript(
            "JSON.stringify({ready:document.readyState,hidden:document.hidden,visibility:document.visibilityState,draws:window.waveDraws,webgl:!!document.getElementById('glCanvas')?.getContext('webgl'),errors:window.waveErrors})"
        )
        XCTAssertTrue(ready, "Native WebKit fixture must load: \(diagnostic ?? "no diagnostic")")
        guard ready else { return }
        let hiddenDraws = try await view.evaluateJavaScript("window.waveDraws") as? Int
        XCTAssertEqual(hiddenDraws, 0, "Hidden pages must not draw")
        let initial = try await view.evaluateJavaScript("setWaveHidden(false); window.waveDraws") as? Int
        XCTAssertEqual(initial, 1, "Becoming visible must draw the static scene")
        let pixel = try await view.evaluateJavaScript("window.wavePixel") as? [Int]
        XCTAssertEqual(pixel?.count, 4)
        XCTAssertEqual(pixel?.last, 255, "The actual shader must produce opaque pixels")
        XCTAssertTrue(pixel?.prefix(3).contains(where: { $0 > 0 }) == true, "The actual wave must be nonblank")
        let glError = try await view.evaluateJavaScript("window.waveGLError") as? Int
        XCTAssertEqual(glError, 0, "Native WebGL must draw without errors")
        try await Task.sleep(for: .milliseconds(150))
        let settled = try await view.evaluateJavaScript("window.waveDraws") as? Int
        XCTAssertEqual(initial, settled, "Reduced motion must not keep drawing")
        let resized =
            try await view.evaluateJavaScript("window.dispatchEvent(new Event('resize')); window.waveDraws") as? Int
        XCTAssertEqual(resized, (initial ?? 0) + 1)
        let resumedThenStopped =
            try await view.evaluateJavaScript("setWaveMotion(false); setWaveMotion(true); window.waveDraws") as? Int
        XCTAssertEqual(resumedThenStopped, (resized ?? 0) + 1)
        try await Task.sleep(for: .milliseconds(150))
        let final = try await view.evaluateJavaScript("window.waveDraws") as? Int
        XCTAssertEqual(final, resumedThenStopped)
        let resources = try await view.evaluateJavaScript("performance.getEntriesByType('resource').length") as? Int
        XCTAssertEqual(resources, 0)
    }
}
