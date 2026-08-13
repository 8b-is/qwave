import Foundation

public struct StartMemoryChip: Equatable, Sendable {
    public var title: String
    public var preview: String

    public init(title: String, preview: String) {
        self.title = title
        self.preview = preview
    }
}

public struct TimelineItemView: Equatable, Sendable {
    public var title: String
    public var detail: String
    public var href: String?

    public init(title: String, detail: String, href: String?) {
        self.title = title
        self.detail = detail
        self.href = href
    }
}

public struct TimelineDayView: Equatable, Sendable {
    public var heading: String
    public var items: [TimelineItemView]

    public init(heading: String, items: [TimelineItemView]) {
        self.heading = heading
        self.items = items
    }
}

/// HTML for qwave://start, error pages, and the markdown reader.
public enum InternalPages {
    public static let startURL = URL(string: "qwave://start")!

    public static let timelineURL = URL(string: "qwave://timeline")!

    public static func isStartURL(_ url: URL?) -> Bool {
        url?.scheme == "qwave" && url?.host == "start"
    }

    public static func isTimelineURL(_ url: URL?) -> Bool {
        url?.scheme == "qwave" && url?.host == "timeline"
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

    public static func startHTML(
        memories: [StartMemoryChip],
        providerLabel: String,
        rememberEverything: Bool = false
    ) -> String {
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
        let mode = rememberEverything ? "Remember Everything is on" : "Remember is explicit"
        return waveDocument(
            title: "qwave",
            overlay: """
                <div class="overlay interactive">
                  <div class="glass slate start-slate">
                    <h1>qwave</h1>
                    <p class="lead">Memory Wave</p>
                    <form id="start-form" autocomplete="off">
                      <input id="start-q" type="text" placeholder="Ask, search, or enter a path…" autofocus>
                      <button class="escape-btn" type="submit">Initialize</button>
                    </form>
                    <div class="chips">\(chips)</div>
                    <p class="foot">\(MarkdownCompiler.escape(providerLabel)) · \(mode) · this Mac only</p>
                    <a class="escape-btn" href="qwave://timeline">Open timeline</a>
                  </div>
                </div>
                """,
            extraHead: startExtraCSS,
            extraScripts: startScript,
            markdownSource: nil
        )
    }

    public static func timelineHTML(
        days: [TimelineDayView],
        summary: String?,
        rememberEverything: Bool,
        providerLabel: String
    ) -> String {
        let dayBlocks: String
        if days.isEmpty {
            dayBlocks = "<p class=\"empty\">The slate is clear. Browse with Remember Everything, or pin a page.</p>"
        } else {
            dayBlocks = days.map { day in
                let rows = day.items.map { item -> String in
                    let body = """
                        <span class="row-title">\(MarkdownCompiler.escape(item.title))</span>
                        <span class="row-detail">\(MarkdownCompiler.escape(item.detail))</span>
                        """
                    if let href = item.href {
                        return "<a class=\"row\" href=\"\(MarkdownCompiler.escape(href))\">\(body)</a>"
                    }
                    return "<div class=\"row\">\(body)</div>"
                }.joined()
                return "<section class=\"day\"><h2>\(MarkdownCompiler.escape(day.heading))</h2>\(rows)</section>"
            }.joined()
        }
        let summaryBlock: String
        if let summary, !summary.isEmpty {
            summaryBlock = "<div class=\"summary\">\(MarkdownCompiler.escape(summary).replacingOccurrences(of: "\n", with: "<br>"))</div>"
        } else {
            summaryBlock = ""
        }
        let mode = rememberEverything ? "capturing every page locally" : "explicit pins only"
        return waveDocument(
            title: "Timeline",
            overlay: """
                <div class="overlay interactive timeline-overlay">
                  <div class="glass slate">
                    <header class="slate-head">
                      <p class="kicker">Memory Wave</p>
                      <h1>Timeline</h1>
                      <p class="lead small">A liquid slate of your local waves — \(mode).</p>
                      <div class="actions">
                        <button class="escape-btn" data-summarize="today">Summarize today</button>
                        <button class="escape-btn" data-summarize="week">This week</button>
                        <button class="escape-btn" data-summarize="all">Everything</button>
                      </div>
                    </header>
                    \(summaryBlock)
                    <div class="days">\(dayBlocks)</div>
                    <p class="foot">\(MarkdownCompiler.escape(providerLabel)) · summaries never send page bodies off this Mac</p>
                    <a class="escape-btn" href="qwave://start">Back to start</a>
                  </div>
                </div>
                """,
            extraHead: startExtraCSS + timelineCSS,
            extraScripts: startScript + timelineScript,
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
        .glass {
            background: linear-gradient(165deg, rgba(255,255,255,0.28) 0%, rgba(255,255,255,0.07) 38%, rgba(8,22,32,0.32) 100%);
            backdrop-filter: blur(42px) saturate(190%);
            -webkit-backdrop-filter: blur(42px) saturate(190%);
            border: 1px solid rgba(255,255,255,0.32);
            box-shadow: 0 24px 80px rgba(0,0,0,0.38), inset 0 1px 0 rgba(255,255,255,0.5), inset 0 -1px 0 rgba(255,255,255,0.06);
            border-radius: 28px;
        }
        .slate { pointer-events: auto; padding: 36px 40px 32px; margin: 0 auto; }
        .start-slate { max-width: 720px; }
        .overlay.interactive { width: min(880px, 94vw); }
        h1 { font-size: clamp(3.2rem, 11vw, 7rem); }
        #start-form { display: flex; gap: 12px; justify-content: center; flex-wrap: wrap; margin-bottom: 28px; }
        #start-q {
            min-width: min(420px, 80vw); padding: 14px 18px; font: inherit; font-size: 1.05rem;
            color: #fff; background: rgba(255,255,255,0.08); border: 1px solid rgba(255,255,255,0.35);
            backdrop-filter: blur(12px); letter-spacing: 1px; border-radius: 14px;
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

    private static let timelineCSS = """
        html, body { overflow: auto; }
        .timeline-overlay { top: 8vh; transform: translate(-50%, 0); max-height: 86vh; }
        .slate { max-width: 760px; max-height: 86vh; overflow: auto; text-align: left; }
        .slate-head { text-align: center; margin-bottom: 22px; }
        .kicker { letter-spacing: 0.4em; text-transform: uppercase; font-size: 0.75rem; opacity: 0.75; margin: 0 0 6px; }
        .lead.small { font-size: 0.95rem; letter-spacing: 2px; margin: 8px 0 18px; }
        .actions { display: flex; flex-wrap: wrap; gap: 10px; justify-content: center; }
        .actions .escape-btn { font-size: 0.85rem; padding: 10px 18px; }
        .summary {
            margin: 8px 0 22px; padding: 16px 18px; line-height: 1.5; font-family: ui-sans-serif, system-ui, sans-serif;
            background: rgba(255,255,255,0.08); border: 1px solid rgba(255,255,255,0.18); border-radius: 16px;
        }
        .day { margin: 18px 0; }
        .day h2 { font-size: 1.05rem; letter-spacing: 1px; margin: 0 0 10px; font-family: ui-sans-serif, system-ui, sans-serif; }
        .row {
            display: flex; flex-direction: column; gap: 2px; padding: 10px 12px; margin: 0 0 6px;
            color: inherit; text-decoration: none; border-radius: 12px;
            background: rgba(255,255,255,0.06); border: 1px solid rgba(255,255,255,0.12);
            font-family: ui-sans-serif, system-ui, sans-serif; text-transform: none; letter-spacing: 0;
        }
        .row:hover { background: rgba(255,255,255,0.14); }
        .row-title { font-weight: 600; }
        .row-detail { font-size: 0.82rem; opacity: 0.7; }
        """

    private static let timelineScript = """
        (function () {
          function send(payload) {
            try { window.webkit.messageHandlers.qwave.postMessage(payload); } catch (e) {}
          }
          document.querySelectorAll('[data-summarize]').forEach(function (el) {
            el.addEventListener('click', function () {
              send({ type: 'summarize', range: el.getAttribute('data-summarize') || 'today' });
            });
          });
        })();
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
