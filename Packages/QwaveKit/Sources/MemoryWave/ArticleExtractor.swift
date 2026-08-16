import Foundation

/// Backend-independent article extract. The WKWebView script is the primary
/// path; `fallbackExtract` is a DOM-less HTML stripper for tests and for
/// when JavaScript is disabled by shields.
public enum ArticleExtractor {
    public static let userScript = """
        (function () {
          // `qwave-source` carries the markdown as a JSON literal. `script` is
          // a raw-text element, so `.textContent` does not decode character
          // references and reading it directly yielded the escaped spelling of
          // the document (issue #138). `JSON.parse` is the exact inverse of
          // `InternalPages.markdownSourceLiteral`.
          const el = document.getElementById('qwave-source');
          let src = '';
          if (el) {
            try { src = JSON.parse(el.textContent); } catch (e) { src = ''; }
          }
          if (src) {
            return JSON.stringify({
              title: (document.title || '').trim(),
              text: src,
              href: location.href
            });
          }
          const sel = window.getSelection && window.getSelection().toString();
          const root = document.querySelector('[data-qwave-markdown]')
            || document.querySelector('article')
            || document.querySelector('main')
            || document.body;
          const title = (document.title || '').trim();
          const text = (sel && sel.trim())
            ? sel
            : (root && (root.innerText || root.textContent) || '')
            .replace(/[ \\t]+/g, ' ')
            .replace(/\\n{3,}/g, '\\n\\n')
            .trim();
          return JSON.stringify({ title: title, text: text, href: location.href });
        })()
        """

    public static func decode(_ value: Any) -> ArticleExtract? {
        let data: Data?
        if let string = value as? String {
            data = Data(string.utf8)
        } else if let already = value as? [String: Any] {
            let title = already["title"] as? String ?? ""
            let text = already["text"] as? String ?? ""
            let href = already["href"] as? String
            guard !text.isEmpty || !title.isEmpty else { return nil }
            return ArticleExtract(title: title, text: text, href: href)
        } else {
            return nil
        }
        guard
            let data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        let title = json["title"] as? String ?? ""
        let text = json["text"] as? String ?? ""
        let href = json["href"] as? String
        guard !text.isEmpty || !title.isEmpty else { return nil }
        return ArticleExtract(title: title, text: text, href: href)
    }

    public static func fallbackExtract(html: String, url: URL? = nil) -> ArticleExtract {
        var stripped = html
        if let titleRange = stripped.range(
            of: #"<title[^>]*>(.*?)</title>"#, options: [.regularExpression, .caseInsensitive])
        {
            let raw = String(stripped[titleRange])
            let title = raw.replacingOccurrences(of: #"</?title[^>]*>"#, with: "", options: .regularExpression)
            stripped = stripped.replacingOccurrences(
                of: #"<script[\s\S]*?</script>"#, with: " ", options: [.regularExpression, .caseInsensitive])
            stripped = stripped.replacingOccurrences(
                of: #"<style[\s\S]*?</style>"#, with: " ", options: [.regularExpression, .caseInsensitive])
            stripped = stripped.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            let text = stripped.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ArticleExtract(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines), text: text, href: url?.absoluteString)
        }
        stripped = stripped.replacingOccurrences(
            of: #"<script[\s\S]*?</script>"#, with: " ", options: [.regularExpression, .caseInsensitive])
        stripped = stripped.replacingOccurrences(
            of: #"<style[\s\S]*?</style>"#, with: " ", options: [.regularExpression, .caseInsensitive])
        stripped = stripped.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        let text = stripped.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ArticleExtract(title: url?.host ?? "", text: text, href: url?.absoluteString)
    }
}
