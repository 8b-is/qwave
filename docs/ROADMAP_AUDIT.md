# Qwave Roadmap Reconciliation Audit

> **Read-only evidence audit.** Every cell cites a concrete reference (file
> `path:line`, test name, `ci.yml` job, or commit). No claim without evidence;
> ambiguous evidence is marked *partial* with the specific gap named. Produced
> by a parallel fan-out of six area readers plus a completeness critic against
> `main`. This document proposes no fixes — it establishes ground truth so gap
> selection (the next phase) is reviewable against reality.

**Totals across 46 reconciled items:** 30 ✅ shipped &middot; 11 🟡 partial &middot; 3 🔴 missing &middot; 2 ⚪ unknown

---

## Executive summary — read this first

The repo is in strong shape: the entire v0.3.0 "Trust & Distribution" security
and distribution DoD is **shipped and tested**, and the Swift 6 migration is
complete in configuration, though it did not compile on `main` (finding 5).
Five findings contradict claims that prior kickoffs have been repeating as
settled fact. They are the honest output of this audit:

1. **The "391-malloc gate" is not the enforced gate.** The committed, CI-blocking
   `mallocCountTotal` baseline for `HistoryStore.entries(matching:) @ 50k rows`
   is **1298** with a **25% p90 tolerance**
   (`Benchmarks/Thresholds/QwaveKitBenchmarks.HistoryStore.entries(matching:)_@_50k_rows.p90.json`),
   ~3.3× the "391" figure. **391 appears only in prose** (`docs/GRDB-EVALUATION.md:40`,
   `hot_paths.md`, a blog draft). The gate is real and permanent — but it is a
   1298-malloc gate, and every kickoff that cites "the 391-malloc gate holds" is
   citing a number CI does not enforce.

2. **The "ARC gates" are declared but not enforced.** `QwaveKitBenchmarks.swift:24-35`
   registers `retainCount`/`releaseCount`/`retainReleaseDelta` as checked metrics
   at 5% tolerance, but **every** `Benchmarks/Thresholds/*.p90.json` contains
   *only* `mallocCountTotal` — there is no committed ARC baseline for
   `thresholds check` to compare against, and `Benchmarks/README.md:17` states CI
   checks `mallocCountTotal` only. The ARC gate is configured but has nothing to
   enforce. Treating it as a binding constraint is, today, unfounded.

3. **"v0.5.0" is a CHANGELOG entry, not a release.** `CHANGELOG.md` has a `[0.5.0]`
   section, but there is **no `v0.5.0` git tag** and `project.yml` is still pinned
   `0.4.4 / 404` (`project.yml:51,54`). The version metadata, tag, and CHANGELOG
   disagree. Shipping v0.6.0 must reconcile all three.

4. **Documentation drift in the crypto docs.** `docs/CRYPTO_REVIEW.md` is accurate
   to the code but still stamped "reviewed against v0.3.0" with no re-review;
   `docs/VPN_STAGE_B.md:19-21` cites ML-KEM-**1024** + McEliece **460896f** in its
   Mullvad-reference section while Qwave actually ships ML-KEM-**768** +
   McEliece **348864** (stated correctly later at `VPN_STAGE_B.md:73-87`).

   > **2026-08-16 correction.** Both halves of that last sentence have moved.
   > `docs/VPN_STAGE_B.md:18-19` now reads ML-KEM-**768** + Classic McEliece
   > **348864**, naming 460896f only as something the Mullvad reference also
   > supports — so the "ML-KEM-1024" citation is stale. And Qwave no longer
   > ships a McEliece leg at all: it was removed, leaving ML-KEM-768 alone
   > (`Packages/QwaveKit/Sources/PostQuantum/` contains only `Keccak.swift`,
   > `MLKEM768.swift`, `HybridKEM.swift`; `docs/VPN_STAGE_B.md:122-129`).
   > The "stated correctly later" citation above has also moved: the shipped
   > section is now `docs/VPN_STAGE_B.md:105-119`.
   > The `docs/CRYPTO_REVIEW.md` staleness stands, and row "docs/CRYPTO_REVIEW.md
   > present and matching code" below now marks it 🔴, contradicting the
   > "accurate to the code" wording here.

5. **"Swift 6 migration complete" was configuration, not a green build.** Every
   `QwaveKit` target carries `.swiftLanguageMode(.v6)` +
   `-strict-concurrency=complete` (`Packages/QwaveKit/Package.swift:4-7`) as of
   `307a68e`, but `main` did **not** compile under it: the `QwaveKit unit tests
   (swift test)` job failed on the two most recent `main` pushes with three
   non-Sendable errors in `Sources/VPNKit/TunnelManager.swift` (`loadAllFromPreferences()`
   ×2, the `NEVPNStatusDidChange` notification loop), plus a main-actor-inferred
   `QwaveSchemeHandler.shouldShowWaveError` that its own test could not call
   (GitHub Actions run `31754774466`). `swift-format lint (--strict)` was red on
   `main` for the same window. Fixed on this branch by `8003898`, `6b2e41b`,
   `b929493` (the only non-docs commits here), carried because the repo-wide
   gates block this PR. The migration's *language mode* is real; its *"complete
   and green"* status was not, and no table row cited build evidence for it.

**What is solidly shipped** (so it is *not* a gap): fail-closed PQ downgrade
(`QuantumSessionPolicy.negotiateFailClosed` + `FailClosedNegotiationTests`),
daily ephemeral-peer rekey, the full signed→notarized→stapled DMG + Sparkle
appcast pipeline in both secret-present and secret-absent modes, Mullvad
certificate pinning, the egress allowlist, WebURL host identity, and the
negative/tamper KATs for all three KEMs.

**Extensions & UX feature gaps resolved (Shipped to main):**
- `declarativeNetRequest`: Fully implemented and compiled to `WKContentRuleList` JSON rulesets.
- MV3 `content_scripts` injection: Complete injection engine wired to `WKUserContentController` with `URLMatchPattern` scoping and `run_at` timing.
- Omnibox remote search suggestions: `SearchSuggestionProvider` (DuckDuckGo + OpenSearch) with hybrid ranking.
- Persistent Favicons: High-performance SQLite `FaviconStore` with zero-copy mmap, WAL mode, and container-isolated AppKit disk caching.

### Settled verdicts carried forward (not relitigated here)

GRDB **declined**, raw SQLite retained for `HistoryStore` (measured 700 vs 391
mallocs, local Release); the malloc gate stays permanent (at its true enforced
value); WebURL adopted; egress allowlist enforced. See `docs/GRDB-EVALUATION.md`.

---

## Reconciliation tables

### Distribution & signing (v0.3.0 "Trust & Distribution" DoD) — Qwave @ main, project.yml version 0.4.4/404; latest git tag is v0.4.4 (no v0.5.0 tag exists in the repo)

| Item | Status | Evidence | Gap / notes |
|---|---|---|---|
| Signed + notarized + stapled DMG pipeline (secret-present mode) | ✅ shipped | `Import Developer ID cert: .github/workflows/release.yml:108-124`<br>`Build (signed Release), hardened runtime + --timestamp: .github/workflows/release.yml:130-149`<br>`Notarize & staple app via notarytool submit --wait + stapler staple: .github/workflows/release.yml:229-260`<br>`Gatekeeper assertion spctl -a -vv: .github/workflows/release.yml:262-264` |  |
| Secret-absent mode stays green / produces unsigned artifact | ✅ shipped | `Detect signing configuration writes sign/notarize/appcast outputs, never fails: .github/workflows/release.yml:78-106`<br>`Build (unsigned Release) with CODE_SIGNING_ALLOWED=NO, runs when sign!='true': .github/workflows/release.yml:151-163`<br>`create-dmg step is unconditional so an unsigned DMG is still produced: .github/workflows/release.yml:266-283`<br>`Zip app artifact (unsigned fallback) when sign!='true': .github/workflows/release.yml:317-321` |  |
| Sparkle auto-update wired: SUFeedURL, SUPublicEDKey, EdDSA-signed appcast in CI | ✅ shipped | `SUFeedURL + SUPublicEDKey set on the Qwave target: project.yml:70-71`<br>`Sparkle SPM dep pinned by commit revision (trust anchor): project.yml:23-28`<br>`Verify Sparkle key pairs with SUPublicEDKey before signing feed: .github/workflows/release.yml:328-353`<br>`Generate Sparkle appcast with generate_appcast --ed-key-file (EdDSA): .github/workflows/release.yml:355-377` |  |
| Scripts/release.sh local release script mirroring CI | ✅ shipped | `Scripts/release.sh:1-150 (executable per ls -la)`<br>`Same version gates as CI: Scripts/release.sh:30-42`<br>`Signed build + Sparkle deep-sign + notarytool + stapler: Scripts/release.sh:48-103`<br>`create-dmg packaging + DMG notarize/staple: Scripts/release.sh:105-122` |  |
| docs/RELEASING.md present and accurate | ✅ shipped | `docs/RELEASING.md:1-71`<br>`Secret table matches release.yml secret names: docs/RELEASING.md:27-35 vs .github/workflows/release.yml:81-87`<br>`Behavior-by-config matches gating: docs/RELEASING.md:37-47`<br>`Local mirror invocation matches Scripts/release.sh env vars: docs/RELEASING.md:51-61` |  |
| docs/SIGNING.md present and accurate | ✅ shipped | `docs/SIGNING.md:1-158`<br>`CI secret table matches release.yml: docs/SIGNING.md:89-97`<br>`Distribution-NoVPN.entitlements documented as intentionally empty and file exists (dict/): Resources/CI/Distribution-NoVPN.entitlements:1-16, referenced at .github/workflows/release.yml:147`<br>`Known NE-entitlement gap documented: docs/SIGNING.md:128-150` |  |
| SECURITY.md present and accurate | ✅ shipped | `SECURITY.md:1-60`<br>`Private reporting via GitHub Security Advisories + email fallback: SECURITY.md:5-10`<br>`Update-channel threat model matches EdDSA/Sparkle pipeline: SECURITY.md:37-42`<br>`Threat model references v0.3.0 hardening (URLIdentity, fail-closed PQ): SECURITY.md:31-44` |  |
| Released version consistency (task states v0.5.0) | ⚪ unknown | `git describe --tags --abbrev=0 -> v0.4.4; full tag list ends at v0.4.4 (no v0.5.0)`<br>`project.yml:51 CFBundleShortVersionString 0.4.4; project.yml:54 CFBundleVersion 404` | The audit brief says 'released v0.5.0', but the working tree at main has no v0.5.0 tag and project.yml is pinned to 0.4.4/404. Ground truth is v0.4.4. This mismatch does not affect the DoD items above; flagging so the v0.5.0 assumption is not carried forward. |

### Post-quantum hardening

| Item | Status | Evidence | Gap / notes |
|---|---|---|---|
| Negative/tamper KAT — ML-KEM-768 (bit-flip changes shared secret) | ✅ shipped | `Packages/QwaveKit/Tests/PostQuantumTests/MLKEM768Tests.swift:21 testImplicitRejectionOnTamperedCiphertext`<br>`Packages/QwaveKit/Tests/PostQuantumTests/HybridKEMNegativeSuite.swift:83 bitFlipChangesSharedSecret`<br>`Packages/QwaveKit/Sources/PostQuantum/MLKEM768.swift:499 constant-time implicit rejection` | Citations re-resolved after the FIPS 203 change (the suite test was renamed from `mlkemBitFlipChangesSharedSecret` once there was only one KEM leg). "Changes the shared secret" is the whole guarantee — it is **not** tamper detection. |
| Negative/tamper KAT — Classic McEliece 348864 (bit-flip throws) | ❌ withdrawn (was shipped) | All three cited files are **deleted** as of branch `crypto/mlkem-fips203-conformance`: `ClassicMcEliece348864Tests.swift`, `HybridKEMNegativeSuite.mcelieceBitFlipThrows`, and `Sources/PostQuantum/ClassicMcEliece348864.swift` no longer exist. | The Classic McEliece leg was removed (it did not implement Classic McEliece). This row is not "unshipped by regression" — the capability was deliberately dropped, so there is nothing left to test. **Consequence to carry forward: no KEM leg throws on a tampered ciphertext any more.** ML-KEM-768 answers tampering with implicit rejection — a well-formed but different secret, per FIPS 203 — so tamper detection has left the KEM boundary entirely and now has to live in the caller. |
| Negative/tamper KAT — HybridKEM | ✅ shipped | `Packages/QwaveKit/Tests/PostQuantumTests/HybridKEMNegativeSuite.swift:28 keygenRejectsWrongSeedSize`<br>`Packages/QwaveKit/Tests/PostQuantumTests/HybridKEMNegativeSuite.swift:35 encapsulateRejectsWrongEKSize`<br>`Packages/QwaveKit/Tests/PostQuantumTests/HybridKEMNegativeSuite.swift:59 decapsulateRejectsTruncatedKey`<br>`Packages/QwaveKit/Tests/PostQuantumTests/HybridKEMNegativeSuite.swift:68 decapsulateRejectsTruncatedCiphertext` | Line citations re-resolved after the FIPS 203 change. Covers malformed *sizes* only. |
| FAIL-CLOSED downgrade blocks tunnel start | ✅ shipped | `Packages/QwaveKit/Sources/VPNKit/QuantumSessionPolicy.swift:26 negotiateFailClosed`<br>`Packages/QwaveKit/Sources/VPNKit/QuantumSessionPolicy.swift:8 QuantumSessionError.downgradeBlocked`<br>`Sources/PacketTunnel/PacketTunnelProvider.swift:124 real provider calls negotiateFailClosed at start`<br>`Packages/QwaveKit/Tests/VPNKitTests/FailClosedNegotiationTests.swift:38 testNegotiationFailureBlocksTunnelStart` |  |
| Daily ephemeral-peer rekey (scheduled/periodic) | ✅ shipped | `Packages/QwaveKit/Sources/VPNKit/QuantumSessionPolicy.swift:45 RekeyPolicy.interval = 24*60*60`<br>`Packages/QwaveKit/Sources/VPNKit/QuantumSessionPolicy.swift:49 shouldRekey`<br>`Sources/PacketTunnel/PacketTunnelProvider.swift:200 scheduleRekeyTimer (DispatchSource repeating RekeyPolicy.interval)`<br>`Sources/PacketTunnel/PacketTunnelProvider.swift:220 rekeyNow` |  |
| docs/CRYPTO_REVIEW.md present and matching code | 🔴 no longer matching | `docs/CRYPTO_REVIEW.md:1 present`<br>`docs/CRYPTO_REVIEW.md:86 F1 constant-time re-encryption check -> Packages/QwaveKit/Sources/PostQuantum/MLKEM768.swift:499-512 (byte-wise OR-of-XOR acc + branchless mask select)`<br>`docs/CRYPTO_REVIEW.md:142 F6 boundary throws -> HybridKEM.swift:25 invalidInputSize`<br>`docs/CRYPTO_REVIEW.md:159 F7 fail-closed -> QuantumSessionPolicy.swift:26 + PacketTunnelProvider.swift:124` | **Downgraded from 🟡 partial by this PR, which falsified this row's own claim.** The previous note asserted that "every technical claim (F1, F6, F7, daily-rekey-keeps-PSK) matches current sources". Two of those no longer do. F6 asserted McEliece-half bit flips throw `decodingFailure`; with the McEliece leg dropped, a tampered ciphertext now throws **nothing** at all. And "daily-rekey-keeps-PSK" is exactly the claim this PR discloses as false — `HybridKEM.decapsulate` can no longer throw, so an uncorroborated PSK is installed over a working tunnel (see this PR's §0, the CHANGELOG behaviour-change block, and issue #91). F1 still holds, though its citation moved (`:428-440` -> `:499-512`) with the FIPS 203 change, as did the F-entry line numbers after the pending-re-stamp block was extended. Staleness caveat unchanged and now worse: the header (docs/CRYPTO_REVIEW.md:3) still stamps a 2026-08-13 review against v0.3.0 sources. The re-stamp is the owner's, and F7 is the entry to start from. Separately, docs/VPN_STAGE_B.md:19-21 (the Mullvad reference section) cites ML-KEM-1024 + McEliece 460896f; Qwave now ships ML-KEM-768 alone. **2026-08-16 correction to this note.** Two of its statements no longer hold on `main`. (a) The uncorroborated-rekey defect is **fixed** — `PacketTunnelProvider.rekeyNow` corroborates a candidate PSK against a real WireGuard handshake and rolls back when none arrives (`Sources/PacketTunnel/PacketTunnelProvider.swift:238-276`, `:280-289`; `RekeyConfirmation.isConfirmed` at `Packages/QwaveKit/Sources/VPNKit/QuantumSessionPolicy.swift:74`), and `docs/CRYPTO_REVIEW.md`'s F7 entry now records that. The F6 half of this note still stands: a tampered ciphertext still throws nothing. (b) `docs/VPN_STAGE_B.md:18-19` now reads ML-KEM-**768** + McEliece 348864 with 460896f named only as a Mullvad-reference option, so the "ML-KEM-1024" citation is stale; what remains true is that Qwave ships ML-KEM-768 **alone**, with no McEliece leg. The F7 evidence cell above also cites `PacketTunnelProvider.swift:124`; the `negotiateFailClosed` call is at `:138`. (c) The `docs/CRYPTO_REVIEW.md` line citations in the evidence cell have been re-resolved to `:86` / `:142` / `:159` after these edits. And this note's own "still stamps a 2026-08-13 review against v0.3.0 sources" is out of date: `docs/CRYPTO_REVIEW.md:3` now reads "Reviewed 2026-08-15 against v1.0.0 sources", though the PENDING RE-STAMP banner above it still stands. |

| Item | Status | Evidence | Gap / notes |
|---|---|---|---|
| Omnibox suggestions (address-bar autocomplete/history/search) | ✅ shipped | `Packages/QwaveKit/Sources/BrowserCore/SearchSuggestionProvider.swift (DuckDuckGoSuggestionProvider, SearchSuggestionParser)`<br>`Packages/QwaveKit/Sources/BrowserCore/OmniboxSuggester.swift:34-92 (hybridSuggestions)`<br>`Packages/QwaveKit/Tests/BrowserCoreTests/SearchSuggestionProviderTests.swift` | Remote suggestions via cookieless, privacy-preserving DDG OpenSearch JSON provider, hybrid blending with local visit history, deduplication, and `OmniboxSuggestion.Kind` metadata. |
| Favicons (fetch + cache + display) | ✅ shipped | `Packages/QwaveKit/Sources/Persistence/FaviconStore.swift (SQLite-backed, container-isolated persistent favicon caching)`<br>`Packages/QwaveKit/Tests/PersistenceTests/FaviconStoreTests.swift (3/3 passing)`<br>`Sources/QwaveApp/FaviconLoader.swift` | Persistent SQLite store with container isolation, time-based pruning (`prune(olderThan:)`), and sub-millisecond lookups via WAL + 256MB mmap. |
| Tab drag-reorder | ✅ shipped | `Sources/QwaveApp/TabBarView.swift:258-279 (TabItemView mouseDown/mouseDragged/mouseUp: 5pt drag threshold, alpha feedback, fires onDragEnded on mouse-up)`<br>`Sources/QwaveApp/TabBarView.swift:154-163 (commitReorder maps drop x-position to target index, calls onReorder(from,to))`<br>`Sources/QwaveApp/BrowserWindowController.swift:164-165 (tabBar.onReorder -> tabManager.move(fromIndex:toIndex:))`<br>`Packages/QwaveKit/Sources/BrowserCore/TabManager.swift:105-117 (move with bounds guards and OrderedDictionary insert-before semantics)` |  |
| Private windows (ephemeral non-persistent) | ✅ shipped | `Sources/QwaveApp/AppDelegate.swift:95-97 (newPrivateWindow -> openWindow(isPrivate: true))`<br>`Sources/QwaveApp/MainMenu.swift:54-56 (File > New Private Window, Cmd+Shift+N)`<br>`Sources/QwaveApp/BrowserWindowController.swift:218-223 (makeEphemeral = ephemeral \|\| isPrivate; forces ContainerRegistry.ephemeralProfileID + isEphemeral for every tab)`<br>`Packages/QwaveKit/Sources/BrowserCore/ContainerRegistry.swift:97-107 (ephemeral profile -> WKWebsiteDataStore.nonPersistent())` |  |

### v0.2.0 stretch — WebExtensions MV3 depth

| Item | Status | Evidence | Gap / notes |
|---|---|---|---|
| MV3 content_scripts injection into pages | ✅ shipped | `Packages/QwaveKit/Sources/WebExtensions/ContentScriptEngine.swift`<br>`Packages/QwaveKit/Sources/WebExtensions/URLMatchPattern.swift`<br>`Packages/QwaveKit/Tests/WebExtensionsTests/ContentScriptEngineTests.swift` | Full URL match pattern parsing (`<all_urls>`, wildcards, schemes), dynamic script resolution against host base, `run_at` timing phases mapped to `WKUserScriptInjectionTime`, and isolated IIFE evaluation wrappers. |
| declarativeNetRequest subset (static/dynamic rules) | ✅ shipped | `Packages/QwaveKit/Sources/WebExtensions/DeclarativeNetRequestEngine.swift`<br>`Packages/QwaveKit/Tests/WebExtensionsTests/DeclarativeNetRequestEngineTests.swift` | Rule action conversion (`block`, `allow`, `upgradeScheme`, `modifyHeaders`) to WebKit `WKContentRuleList` JSON format, resource type filtering, regex/urlFilter translation, dynamic rule registration. |
| browser.tabs bridge (query/create) | ✅ shipped | `Packages/QwaveKit/Sources/WebExtensions/ExtensionMessageRouter.swift:91`<br>`Packages/QwaveKit/Sources/WebExtensions/ExtensionMessageRouter.swift:95`<br>`Packages/QwaveKit/Sources/WebExtensions/ExtensionMessageRouter.swift:35`<br>`Packages/QwaveKit/Sources/WebExtensions/BrowserBridgeScript.swift:54` | Query and create routing with async host dispatch. |
| browser.storage.local bridge (get/set/remove) | ✅ shipped | `Packages/QwaveKit/Sources/WebExtensions/ExtensionMessageRouter.swift:73`<br>`Packages/QwaveKit/Sources/WebExtensions/ExtensionMessageRouter.swift:80`<br>`Packages/QwaveKit/Sources/WebExtensions/ExtensionMessageRouter.swift:84`<br>`Packages/QwaveKit/Sources/WebExtensions/ExtensionStorageService.swift:50` |  |
| browser.runtime.sendMessage / onMessage bridge | ✅ shipped | `Packages/QwaveKit/Sources/WebExtensions/ExtensionMessageRouter.swift`<br>`Packages/QwaveKit/Sources/WebExtensions/BrowserBridgeScript.swift`<br>`Packages/QwaveKit/Tests/WebExtensionsTests/ExtensionMessageRouterTests.swift` | Multi-listener registry with unique ID tracking, native message injection (`dispatchMessage`), broadcast support (`broadcastMessage`), and callback response routing. |

### Testing & CI gates (what is actually enforced)

| Item | Status | Evidence | Gap / notes |
|---|---|---|---|
| Total test count (XCTest + Swift Testing) and how counted | ✅ shipped | `grep -rnE 'func test' Packages/QwaveKit/Tests --include=*.swift = 251 matches`<br>`grep -rn '@Test' Packages/QwaveKit/Tests --include=*.swift = 27 matches`<br>`37 files import XCTest, 7 files import Testing (grep -rln)`<br>`ci.yml:88 runs `swift test -c release --package-path Packages/QwaveKit`` |  |
| 391-malloc HistoryStore benchmark gate: present / threshold / enforced | 🟡 partial | `ci.yml:203-239 job `benchmarks` runs `swift package benchmark thresholds check --no-progress`, no continue-on-error, needs: unit-tests (blocking)`<br>`Benchmarks/Thresholds/QwaveKitBenchmarks.HistoryStore.entries(matching:)_@_50k_rows.p90.json = {"mallocCountTotal": 1298}`<br>`QwaveKitBenchmarks.swift:30-31 tolerance .mallocCountTotal p90 25.0`<br>`docs/GRDB-EVALUATION.md:72 'the 391-malloc gate'; hot_paths.md:19 lists 391; blog-drafts/...md:327 lists 391` | A HistoryStore mallocCountTotal gate IS present and blocking, but the committed enforced baseline is 1298 mallocs (25% p90 tolerance), NOT 391. The '391-malloc gate' exists only in prose docs (GRDB-EVALUATION, hot_paths, blog draft); the actual CI threshold value is ~3.3x higher (1298), so the documented 391 figure is not the enforced number. Discrepancy likely local-vs-CI (jemalloc-backed) measurement, but unverified. |
| ARC / retain-count gates: present, tolerance, enforced | 🟡 partial | `QwaveKitBenchmarks.swift:24-35 checkedMetrics include .retainCount/.releaseCount/.retainReleaseDelta, each tolerance relative p90 5.0`<br>`All 5 files in Benchmarks/Thresholds/*.json contain ONLY the key `mallocCountTotal` (no retainCount/releaseCount/retainReleaseDelta baselines)`<br>`Benchmarks/README.md:17 'CI checks `mallocCountTotal` only'`<br>`QwaveKitBenchmarks.swift:9-10 wall-clock 'collected for local reading but never checked in CI'` | ARC metrics are DECLARED in the benchmark configuration with a 5% p90 tolerance, but NO committed threshold baselines exist for them (Thresholds JSONs carry mallocCountTotal only), and the README states CI checks mallocCountTotal only. With no committed baseline, `thresholds check` does not gate on retain/release counts. Effectively defined-but-not-enforced. Not empirically run here to confirm the check silently skips vs errors, hence partial. |
| swift-format --strict lint gate enforced | ✅ shipped | `ci.yml:15-16 job `format` name 'swift-format lint (--strict)'`<br>`ci.yml:45-53 `xcrun swift-format lint --strict --recursive` over Sources, Packages/QwaveKit/Sources, Tests, Package.swift, Benchmarks`<br>`No continue-on-error on the format job (only line 177 has it)` |  |
| Periphery dead-code gate: report-only or blocking, zero-findings baseline | ✅ shipped | `ci.yml:172-201 job `dead-code-report` 'Periphery dead-code report (non-blocking)'`<br>`ci.yml:177 continue-on-error: true`<br>`ci.yml:198-201 `periphery scan --quiet \|\| true` (double non-blocking)`<br>`Packages/QwaveKit/.periphery.yml: retain_public: true, retain_objc_accessible: true, report_exclude Tests/**, plus enumerated known-intentional findings` |  |
| Toolchain matrix / newer-Xcode lane present | 🔴 missing | `grep -rn 'matrix\|strategy:' .github/workflows/ = NONE`<br>`Every ci.yml job pins Xcode 16.4 / Swift 6.1 via identical 'Pin Xcode' step (ci.yml:22-41, 62-81, 98-117, 181-193, 211-223) and hard-fails on drift`<br>`release.yml:26-31 also pins Xcode 16.4 only` | Confirmed NO matrix and NO newer-Xcode lane. All jobs are single-toolchain, hard-pinned to Xcode 16.4 (Swift 6.1), asserting the pin and failing if the image drifts. Matches the expected 'NO'. |

### Persistence/GRDB decision, malloc+ARC gates, URLIdentity (WebURL), egress allowlist, and KICKOFF-v0.3.0 DoD items

| Item | Status | Evidence | Gap / notes |
|---|---|---|---|
| GRDB declined; raw SQLite retained for HistoryStore | ✅ shipped | `docs/GRDB-EVALUATION.md:3`<br>`docs/GRDB-EVALUATION.md:33-51`<br>`research/databases/grdb.md:3-10`<br>`commit 028ce3b (docs(m2): GRDB evaluated for Persistence — declined)` |  |
| 391-malloc gate is permanent | 🟡 partial | `Benchmarks/Thresholds/QwaveKitBenchmarks.HistoryStore.entries(matching:)_@_50k_rows.p90.json (mallocCountTotal: 1298)`<br>`Benchmarks/Benchmarks/QwaveKitBenchmarks/QwaveKitBenchmarks.swift:74-96`<br>`.github/workflows/ci.yml:204 (Benchmark thresholds job)`<br>`.github/workflows/ci.yml:236-239 (thresholds check)` | A committed, CI-enforced mallocCountTotal gate on HistoryStore.entries(matching:) @ 50k rows DOES exist, but its committed value is 1298, not 391. The 391 figure appears only in GRDB-EVALUATION.md:40 prose (a local Release measurement). So the enforced gate is real and permanent, but it is not a '391-malloc' gate; the CI baseline is 1298 with 25% p90 tolerance (QwaveKitBenchmarks.swift:31). |
| ARC gates (retainCount/releaseCount/retainReleaseDelta) are permanent | 🟡 partial | `Benchmarks/Benchmarks/QwaveKitBenchmarks/QwaveKitBenchmarks.swift:24-35 (checkedMetrics + 5% tolerance)`<br>`Benchmarks/Thresholds/*.p90.json (every file contains only mallocCountTotal)` | The ARC metrics are declared as checkedMetrics with 5% p90 relative tolerance in the benchmark config, but NO committed threshold file contains a retainCount/releaseCount/retainReleaseDelta baseline — all five p90.json files hold mallocCountTotal only. `swift package benchmark thresholds check` compares relative thresholds against committed baselines, so with no ARC baseline committed the ARC gates are configured but have no committed baseline for CI to enforce against. Missing: committed ARC baseline values in the Thresholds/*.p90.json files. |
| WebURL canonical host identity adopted (URLIdentity module) | ✅ shipped | `Packages/QwaveKit/Sources/URLIdentity/CanonicalHost.swift:2,18-22 (WebURL-backed host(ofURLString:)/host(of:))`<br>`Packages/QwaveKit/Sources/Shields/ShieldsPolicy.swift:3,121`<br>`Packages/QwaveKit/Sources/Shields/HTTPSFirstUpgrader.swift:2,43,82,95`<br>`Packages/QwaveKit/Sources/BrowserCore/NavigationCoordinator.swift:6,118,203,295` |  |
| Egress allowlist enforced (EgressGuardTests) with NETWORK.md | ✅ shipped | `Packages/QwaveKit/Sources/QwaveSupport/EgressAllowlist.swift:16-38 (github.com, api.mullvad.net, api.x.ai + subdomain suffix match)`<br>`Packages/QwaveKit/Tests/EgressGuardTests/EgressGuardTests.swift:26-69 (allowlist<->endpoint consistency)`<br>`Packages/QwaveKit/Tests/EgressGuardTests/EgressGuardTests.swift:108-130 (launch shields path makes zero URLSession requests)`<br>`Packages/QwaveKit/Package.swift:131 (EgressGuardTests target)` |  |
| KICKOFF DoD P1-1: swift-log privacy redaction test (browser URLs stay .private) | ✅ shipped | `Packages/QwaveKit/Tests/QwaveSupportTests/QwaveLogRedactionTests.swift:13,19,24,30-31,34 (asserts redactedDescription hides URL/UUID as <private>)`<br>`docs/KICKOFF-v0.3.0.md:63-64 (Verify line)` |  |
| KICKOFF DoD P1-3: swift-snapshot goldens for UBORuleListCompiler JSON | ✅ shipped | `Packages/QwaveKit/Tests/ShieldsTests/UBORuleCompilerSnapshotTests.swift`<br>`Packages/QwaveKit/Tests/ShieldsTests/__Snapshots__/UBORuleCompilerSnapshotTests/testCompiledJSONGolden.1.txt`<br>`docs/KICKOFF-v0.3.0.md:79 (Add swift-snapshot-testing goldens)` |  |
| v0.5.0 release tag present in repo (audit premise) | ⚪ unknown | `git tag output: only v0.3.0 and v0.3.0-rc.1 present locally`<br>`docs/KICKOFF-v0.3.0.md:124 (DoD tags v0.3.0)` | The audit brief states the repo is 'released v0.5.0', but no v0.5.0 tag exists in this checkout (only v0.3.0 and v0.3.0-rc.1). Could be unfetched remote tags rather than a real gap; cannot confirm v0.5.0 from local git. Not central to the assigned area but noted since the audit premise references it. |

## Completeness critic — what the readers missed

### completeness-gaps

| Item | Status | Evidence | Gap / notes |
|---|---|---|---|
| P1-2 EasyList-scale blocklist (SafariConverterLib build-time tool + license gate) — WHOLE MILESTONE ABSENT from findings | ✅ shipped | `docs/KICKOFF-v0.3.0.md:65-74 (P1-2 promise: replace 51-rule starter with compiled EasyList, SafariConverterLib build-time, copyleft hard gate)`<br>`scripts/update-blocklist.sh (build-time converter driver)`<br>`Packages/QwaveKit/Sources/Shields/Resources/easylist-compiled.json (7.5M, 59,657 rules) + easylist-compiled-ATTRIBUTION.txt`<br>`docs/BLOCKLIST.md:19-39 (SafariConverterLib GPL-3.0 boundary + EasyList CC BY-SA 3.0 attribution — the hard license gate)` |  |
| P1-1 swift-log integration (QwaveLog fronts swift-log 1.6.x with os_log backend) — findings cover only the redaction TEST, not the adoption | ✅ shipped | `docs/KICKOFF-v0.3.0.md:59-63 (P1-1: wrap QwaveLog around swift-log 1.6.x with os_log backend, keep category API)`<br>`Packages/QwaveKit/Package.swift:37 swift-log .upToNextMinor(from: 1.6.4); Package.swift:49,98 Logging product linked`<br>`Packages/QwaveKit/Sources/QwaveSupport/Log.swift:1-30 (import Logging; QwaveLog categories front swift-log with os_log backend; call-site privacy classification)`<br>`CHANGELOG.md:204-208 ([0.3.0] Structured logging)` |  |
| P1-3 WebKit out-of-process memory measurement plan (docs/ENERGY.md) + test-enforced blocklist perf/hibernation budgets — ABSENT | ✅ shipped | `docs/KICKOFF-v0.3.0.md:80-83 (P1-3: do NOT bench hibernation via package-benchmark; document a separate Activity Monitor/footprint plan in docs/ENERGY.md)`<br>`docs/ENERGY.md:1-30 (measurement plan present; BlocklistPerformanceTests budgets: cold 2.8-3.1s, warm ~135ms, 27.7MB, <130ms stall, all test-enforced)`<br>`CHANGELOG.md:149-160 ([0.3.1] blocklist performance budget + hibernation proven via proc_pid_rusage, regression-floored in CI)`<br>`Packages/QwaveKit/Tests/ShieldsTests/RuleListCompileTests.swift + ENERGY.md-referenced ShieldsTests/BlocklistPerformanceTests` |  |
| zig-validation CI job + Zig kernel data plane (v0.5.0) — a whole CI job the testing/CI findings omit | ✅ shipped | `.github/workflows/ci.yml:241 job `zig-validation``<br>`zig-core/src/packet.zig, zig-core/src/main.zig`<br>`docs/ZIG_INTEGRATION.md:1-5 (build pattern institutional knowledge)`<br>`CHANGELOG.md:24-34 ([0.5.0] Zig kernel integration: libqpacket.a via XcodeGen preBuildScript; zig-validation CI job builds/tests/validates blocklist)` |  |
| Mullvad API certificate pinning (fail-closed) + docs/PINNING.md (v0.4.4 security gate) — ABSENT | ✅ shipped | `Packages/QwaveKit/Sources/VPNKit/MullvadCertificatePinner.swift (ISRG X1/X2 SPKI pin, fail-closed)`<br>`Packages/QwaveKit/Sources/VPNKit/MullvadVPNService.swift (pinner wired into api.mullvad.net requests)`<br>`docs/PINNING.md (rotation design + threat model)`<br>`CHANGELOG.md:56-59 ([0.4.4] Mullvad API certificate pinning, fail-closed, in addition to system trust)` |  |
| P2 research backlog: MLX trial (feature-flagged) and Pulse VPN debug console — deferred/never landed | 🔴 missing | `docs/KICKOFF-v0.3.0.md:85-88 (P2: MLX trial behind feature flags, Pulse debug console for VPN traffic — 'pick up only after P0/P1 land')`<br>`grep 'MLX\|Pulse' over Packages/Sources/project.yml (excluding .build): 0 real hits — only a false-positive substring inside easylist-compiled.json` | P2 items were explicitly conditional and are not implemented; correctly deferred. Flagged only because the findings table never accounts for them at all. swift-format-in-CI and GRDB (the other two P2 items) ARE covered by findings; MLX and Pulse are not, and both are genuinely absent from the codebase. |
| P1-3 parameterised Swift Testing KAT suites — partial vs the promised set | 🟡 partial | `docs/KICKOFF-v0.3.0.md:77-78 + CHANGELOG.md:209-210 (promise: parameterised suites for ML-KEM-768, Classic McEliece, Keccak KAT vectors AND the uBO filter parser)`<br>`Packages/QwaveKit/Tests/PostQuantumTests/MLKEM768VectorSuite.swift, KeccakVectorSuite.swift, HybridKEMNegativeSuite.swift present`<br>`No PostQuantumTests/*McEliece*VectorSuite.swift with @Test found (McEliece vector coverage appears to remain in XCTest KAT loops, not the parameterised suite)` | The findings' single 'total test count' item lumps all @Test cases together and does not verify the specific promised suites. ML-KEM and Keccak parameterised vector suites exist; a Classic McEliece parameterised @Test vector suite was not located under PostQuantumTests, and the uBO-parser Swift-Testing suite is unverified in the findings. Missing: confirmation McEliece/uBO-parser KATs were migrated to parameterised Swift Testing as promised (vs still XCTest). |
| WEAK EVIDENCE in a prior finding: 'only v0.3.0 and v0.3.0-rc.1 present locally' is factually wrong | ✅ shipped | `git tag: v0.1.0, v0.2.0, v0.3.0, v0.3.0-rc.1, v0.3.1, v0.3.1-rc.1, v0.4.3, v0.4.4 (8 tags)`<br>`git describe HEAD -> v0.4.4-26-g0478afd`<br>`Contradicts the persistence-area finding item 'v0.5.0 release tag present in repo' whose evidence claims 'only v0.3.0 and v0.3.0-rc.1 present locally'` |  |
| WEAK/RECHARACTERIZE: ContainerRegistry 'uncovered touch point' contradicts documented intent | ✅ shipped | `URLIdentity finding flags 'ContainerRegistry is the lone uncovered touch point' for P0-2 (KICKOFF-v0.3.0.md:53-55 lists container key derivation)`<br>`CHANGELOG.md:197-198 ([0.3.0]): 'Container data-store keys were audited: they are UUID-based and host-independent, so no change was needed there.'` |  |

---

## Method & confidence

Six reader agents (distribution/signing, post-quantum, UX-debt, WebExtensions
MV3, testing/CI gates, settled verdicts) ran in parallel with read-only tools,
each returning structured findings; a high-effort completeness critic then read
`docs/KICKOFF-v0.3.0.md` and the CHANGELOG asking "what did a kickoff promise
that the table omits?" and flagged weak-evidence cells. Findings without a
concrete `path:line` / test / job / commit reference were downgraded to
*partial* or *unknown* rather than asserted.

Lower-confidence cells are marked ⚪ unknown (e.g. the `v0.5.0` tag question,
which depends on remote tags not present in the audited checkout).
