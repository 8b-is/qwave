import Foundation
import WebURL

/// WHATWG-canonical host identity — the host as WebKit's own URL parser
/// sees it.
///
/// Foundation `URL.host` and WebKit disagree on IDN/confusable hosts
/// (Unicode vs punycode), backslashes in special schemes, `user@evil@good`
/// authorities, percent-encoded hosts, and non-decimal IPv4 literals
/// (`0x7f.0.0.1`). Any policy decision keyed on a Foundation-derived host
/// can therefore shield one identity while WebKit loads another. Every
/// host-keyed decision (shields overrides, HTTPS-first bookkeeping) must
/// derive its key through this type instead.
public enum CanonicalHost {
    /// The WHATWG-canonical host of an absolute URL string, or nil when the
    /// string does not parse as a URL or has no host (about:, file: without
    /// a host, opaque paths).
    public static func host(ofURLString string: String) -> String? {
        guard let url = WebURL(string), let host = url.host else { return nil }
        let serialized = host.serialized
        return serialized.isEmpty ? nil : serialized
    }

    /// The WHATWG-canonical host of a Foundation URL — how WebKit will
    /// interpret the same absolute string when it loads it.
    public static func host(of url: URL) -> String? {
        host(ofURLString: url.absoluteString)
    }
}
