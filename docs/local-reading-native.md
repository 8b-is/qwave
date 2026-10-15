# Optional native local reading

`SovereignCore.RustLocalReadingSession` extends the existing qwave-core C ABI for
bounded English/Japanese translation and extractive summaries. Both app lanes
use this same shared Swift face. This is an integration boundary under test;
**browser controls and opt-in automatic speech are not connected yet**.

Default public builds have no local model implementation or model files. Their
weak C stubs report unavailable. They never produce placeholder translations or
silently send text to another service. An explicitly linked integration archive
must implement ABI version 1 and retain Qwave's existing sovereign-core exports.
No second C bridge or HTTP server is required.

The caller provisions immutable private assets before loading. Loading and
inference run on one utility worker. A busy request fails promptly; a UI may
keep only the latest pending document request. Native session and generation IDs
are not memory addresses. Starting a generation cancels older work; cancelling
an older task cannot cancel the next document. Release the session when finished.

Translate small plain-text blocks (at most 4096 UTF-8 bytes), retaining originals
and entry identifiers for restoration. Summaries accept 1–32 source sentences,
at most 1024 bytes each, and return verbatim selections. The C header documents
JSON sizes, ownership, errors and the required output buffer capacity. Native
failure or cancellation means keeping original content. Model output is data:
never insert a translation as HTML or execute it as page instructions.

Immediately before presenting results or starting speech, the browser must
recheck its current document, reading-mode state, and task cancellation. A
result already returned across the ABI cannot be recalled on navigation. Speech
is off by default and may start automatically only inside the user's opt-in
reading mode, with visible Stop and cancellation on mode exit/navigation.

Validation distinguishes the standalone package's unavailable behavior from an
explicitly linked implementation. The local pilot has exercised actual CPU
translation through C and Swift, original-sentence retention, stale-generation
rejection and task cancellation. Device memory, broader translation/summary
quality, model setup UI, browser DOM delivery and audio remain separate gates;
this code does not establish an App Store-ready feature.
