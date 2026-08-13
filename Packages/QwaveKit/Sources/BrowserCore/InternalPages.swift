import Foundation

public struct StartMemoryChip: Equatable, Sendable {
    public var title: String
    public var preview: String

    public init(title: String, preview: String) {
        self.title = title
        self.preview = preview
    }
}

/// HTML for qwave://start, error pages, and the markdown reader.
public enum InternalPages {
    public static let startURL = URL(string: "qwave://start")!

    public static func isStartURL(_ url: URL?) -> Bool {
        url?.scheme == "qwave" && url?.host == "start"
    }

    public static func httpErrorHTML(status: Int, host: String) -> String {
        let title = status == 404 ? "404" : "\(status)"
        let subtitle = status == 404 ? "Reality Not Found" : "Signal Distorted"
        return waveDocument(
            title: title,
            overlay: """
                <div class="overlay">
                  <h1>\(MarkdownCompiler.escape(title))</h1>
                  <p class="lead">\(subtitle)</p>
                  <p class="host">\(MarkdownCompiler.escape(host.isEmpty ? "this page" : host))</p>
                  <a class="escape-btn" href="qwave://start">Initialize Escape Sequence</a>
                </div>
                """,
            extraHead: "",
            extraScripts: "",
            markdownSource: nil
        )
    }

    public static func connectionLostHTML(host: String, message: String) -> String {
        waveDocument(
            title: "Lost",
            overlay: """
                <div class="overlay">
                  <h1>404</h1>
                  <p class="lead">Lost in the Math</p>
                  <p class="host">\(MarkdownCompiler.escape(host.isEmpty ? message : host))</p>
                  <a class="escape-btn" href="qwave://start">Initialize Escape Sequence</a>
                </div>
                """,
            extraHead: "",
            extraScripts: "",
            markdownSource: nil
        )
    }

    public static func startHTML(memories: [StartMemoryChip], providerLabel: String) -> String {
        let chips: String
        if memories.isEmpty {
            chips = "<p class=\"empty\">No Cognitive waves yet. Browse, then Remember.</p>"
        } else {
            chips = memories.map { chip in
                """
                <button class="chip" data-ask="\(MarkdownCompiler.escape(chip.title))">
                  <strong>\(MarkdownCompiler.escape(chip.title))</strong>
                  <span>\(MarkdownCompiler.escape(chip.preview))</span>
                </button>
                """
            }.joined()
        }
        return waveDocument(
            title: "qwave",
            overlay: """
                <div class="overlay interactive">
                  <h1>qwave</h1>
                  <p class="lead">Memory Wave</p>
                  <form id="start-form" autocomplete="off">
                    <input id="start-q" type="text" placeholder="Ask, search, or enter a path…" autofocus>
                    <button class="escape-btn" type="submit">Initialize</button>
                  </form>
                  <div class="chips">\(chips)</div>
                  <p class="foot">\(MarkdownCompiler.escape(providerLabel)) · stored memories stay on this Mac</p>
                </div>
                """,
            extraHead: startExtraCSS,
            extraScripts: startScript,
            markdownSource: nil
        )
    }

    public static func markdownHTML(title: String, bodyHTML: String, source: String, allowRemember: Bool) -> String {
        let toolbar =
            allowRemember
            ? """
            <div class="md-toolbar">
              <button class="escape-btn" data-remember="page">Remember page</button>
              <button class="escape-btn" data-remember="selection">Remember selection</button>
            </div>
            """
            : ""
        return waveDocument(
            title: title,
            overlay: """
                <div class="md-shell">
                  \(toolbar)
                  <article class="md-body" data-qwave-markdown="1">
                    \(bodyHTML)
                  </article>
                </div>
                """,
            extraHead: markdownHead,
            extraScripts: markdownScript,
            markdownSource: source
        )
    }

    // MARK: - Shell

    private static func waveDocument(
        title: String,
        overlay: String,
        extraHead: String,
        extraScripts: String,
        markdownSource: String?
    ) -> String {
        let sourceBlock: String
        if let markdownSource {
            sourceBlock = """
                <script type="text/markdown" id="qwave-source">\(MarkdownCompiler.escape(markdownSource))</script>
                """
        } else {
            sourceBlock = ""
        }
        return """
            <!DOCTYPE html>
            <html lang="en">
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width, initial-scale=1">
              <title>\(MarkdownCompiler.escape(title))</title>
              <style>\(WaveScene.overlayCSS)\(extraHead)</style>
              <link rel="stylesheet" href="qwave://runtime/katex.min.css">
            </head>
            <body>
              \(overlay)
              <canvas id="glCanvas"></canvas>
              <script id="fragShader" type="x-shader/x-fragment">\(WaveScene.fragmentShader)</script>
              \(sourceBlock)
              <script>\(WaveScene.canvasScript)</script>
              <script src="qwave://runtime/katex.min.js"></script>
              <script src="qwave://runtime/mermaid.min.js"></script>
              <script>\(enhanceScript)</script>
              <script>\(extraScripts)</script>
            </body>
            </html>
            """
    }

    private static let enhanceScript = """
        (function () {
          function enhance() {
            if (window.katex) {
              document.querySelectorAll('.math-display').forEach(function (el) {
                try { katex.render(el.textContent, el, {displayMode: true, throwOnError: false}); } catch (e) {}
              });
              document.querySelectorAll('.math-inline').forEach(function (el) {
                try { katex.render(el.textContent, el, {displayMode: false, throwOnError: false}); } catch (e) {}
              });
            }
            if (window.mermaid) {
              try {
                mermaid.initialize({ startOnLoad: false, theme: 'dark', securityLevel: 'strict' });
                mermaid.run({ querySelector: '.mermaid' });
              } catch (e) {}
            }
          }
          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', enhance);
          } else {
            enhance();
          }
        })();
        """

    private static let startExtraCSS = """
        h1 { font-size: clamp(4rem, 14vw, 8rem); }
        #start-form { display: flex; gap: 12px; justify-content: center; flex-wrap: wrap; margin-bottom: 28px; }
        #start-q {
            min-width: min(420px, 80vw); padding: 14px 18px; font: inherit; font-size: 1.05rem;
            color: #fff; background: rgba(0,0,0,0.35); border: 1px solid rgba(255,255,255,0.45);
            backdrop-filter: blur(5px); letter-spacing: 1px;
        }
        #start-q:focus { outline: 1px solid #fff; }
        .chips { display: flex; flex-wrap: wrap; gap: 10px; justify-content: center; margin: 12px 0 24px; }
        .chip {
            pointer-events: auto; max-width: 280px; text-align: left; padding: 10px 14px;
            border: 1px solid rgba(255,255,255,0.35); background: rgba(0,0,0,0.25); color: #fff;
            font: inherit; cursor: pointer;
        }
        .chip strong { display: block; letter-spacing: 1px; }
        .chip span { display: block; opacity: 0.75; font-size: 0.85rem; margin-top: 4px; }
        .foot, .empty, .host { font-size: 0.85rem; letter-spacing: 2px; text-transform: uppercase; opacity: 0.8; }
        """

    private static let startScript = """
        (function () {
          function send(payload) {
            try { window.webkit.messageHandlers.qwave.postMessage(payload); } catch (e) {}
          }
          const form = document.getElementById('start-form');
          const field = document.getElementById('start-q');
          if (form && field) {
            form.addEventListener('submit', function (e) {
              e.preventDefault();
              const q = field.value.trim();
              if (q) send({ type: 'submit', query: q });
            });
          }
          document.querySelectorAll('.chip').forEach(function (el) {
            el.addEventListener('click', function () {
              send({ type: 'submit', query: el.getAttribute('data-ask') || el.innerText });
            });
          });
        })();
        """

    private static let markdownHead = """
        html, body { overflow: auto; }
        .md-shell {
            position: relative; z-index: 10; max-width: 820px; margin: 6vh auto 12vh;
            padding: 28px 32px 48px; color: #e8f7f7;
            background: rgba(4, 10, 16, 0.72); backdrop-filter: blur(10px);
            border: 1px solid rgba(255,255,255,0.12); mix-blend-mode: normal;
            pointer-events: auto; font-family: ui-sans-serif, system-ui, sans-serif;
        }
        .md-toolbar { display: flex; gap: 10px; margin-bottom: 20px; flex-wrap: wrap; }
        .md-toolbar .escape-btn { font-size: 0.85rem; padding: 8px 16px; letter-spacing: 2px; }
        .md-body { line-height: 1.55; font-size: 1.05rem; }
        .md-body h1, .md-body h2, .md-body h3 { letter-spacing: 0; font-family: inherit; }
        .md-body h1 { font-size: 2.2rem; }
        .md-body a { color: #9ef0f0; }
        .md-body pre, .md-body code {
            font-family: ui-monospace, 'Courier New', monospace;
            background: rgba(0,0,0,0.35);
        }
        .md-body pre { padding: 14px; overflow: auto; }
        .md-body code { padding: 0.1em 0.3em; }
        .md-body table { border-collapse: collapse; width: 100%; margin: 1em 0; }
        .md-body th, .md-body td { border: 1px solid rgba(255,255,255,0.2); padding: 6px 10px; }
        .md-body .mermaid { background: rgba(0,0,0,0.2); padding: 12px; }
        .md-body .math-display { margin: 1em 0; overflow-x: auto; }
        """

    private static let markdownScript = """
        (function () {
          function send(payload) {
            try { window.webkit.messageHandlers.qwave.postMessage(payload); } catch (e) {}
          }
          document.querySelectorAll('[data-remember]').forEach(function (el) {
            el.addEventListener('click', function () {
              const scope = el.getAttribute('data-remember') || 'page';
              let text = '';
              if (scope === 'selection') {
                text = window.getSelection() ? window.getSelection().toString() : '';
              }
              if (!text) {
                const src = document.getElementById('qwave-source');
                text = src ? src.textContent : (document.querySelector('.md-body') || document.body).innerText;
              }
              send({ type: 'remember', scope: scope, text: text });
            });
          });
        })();
        """
}
