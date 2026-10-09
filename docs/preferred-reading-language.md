# Preferred reading language

Qwave's Language menu chooses a persistent reading language, initially the system's preferred language rather than the travel region. Ordinary main-frame HTTP(S) GET navigations request it through Accept-Language. Form submissions, bodies, child frames, and same-document fragment jumps are not replayed.

On macOS 15+ and iOS 18+, Apple Translation translates page text on-device. Apple may request a language-model download. There is no cloud translation fallback. If a language is unsupported or translation fails, the original remains available and the user can retry from Language.

The native bar stays hidden while idle. The Translation toolbar button opens language controls on demand; the bar appears during translation and identifies translated content with Show original. That choice is remembered for the current document, including tab switches; reloading starts a new document. Site and source-language exceptions persist across launches. Reset exceptions clears both lists. Translate this page retries when enabled; it does not override an explicit site or language exception.

The bounded scanner handles visible text, page titles, accessible labels, image alternate text and placeholders, including text added later. It operates in an isolated WebKit world and inserts plain text, never HTML. It excludes passwords, form values, editable regions, code, and translate=no regions. Restoration does not overwrite text the page changed after translation.

Limits: main document only; no iframe, shadow-root, image OCR or PDF translation. Short text language detection can be ambiguous. Scans process up to 48 items / 10,000 characters and retain at most 5,000 nodes per document. Older systems request the preferred language but do not translate. Site cookies, explicit locale parameters, and subresource requests may override language negotiation. No promise that every website can be translated.

Validation uses QwaveAppStore.xcodeproj: QwaveTabBarTests (DOM safety, restoration, deferred batches, pause state, request preservation and preference tests), QwaveAppStore Debug, and QwaveIOSAppStore simulator Debug. Real Japanese-to-English translation, dynamic text, and Show original were also checked in the signed Mac development app against a local synthetic page. Physical iPhone translation requires a device check before release.
