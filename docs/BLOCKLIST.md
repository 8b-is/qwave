# Blocklist pipeline

Qwave ships a compiled EasyList snapshot
(`Packages/QwaveKit/Sources/Shields/Resources/easylist-compiled.json`) as its
built-in ads/trackers rule list, compiled through
`WKContentRuleListStore` at runtime (cached by content hash — see
`RuleListCompiler`). The previous 51-rule starter list was a demonstration;
the snapshot is EasyList-scale (tens of thousands of rules, including
cosmetic `css-display-none` rules WebKit can express natively).

## Regenerating the snapshot

```sh
./scripts/update-blocklist.sh
swift test --package-path Packages/QwaveKit --filter RuleListCompileTests
```

The script clones AdGuard's
[SafariConverterLib](https://github.com/AdguardTeam/SafariConverterLib) at a
pinned tag, builds its `ConverterTool`, downloads the current EasyList, and
converts it to WebKit content-blocker JSON. The committed JSON is the pin:
builds and CI never run the converter.

## License boundary (reviewed 2026-08-13)

- **SafariConverterLib is GPL-3.0** (AdGuard's project — not a WebKit
  component, despite what the original research note assumed). It is used
  strictly as an **external build-time tool**: cloned into a temp directory,
  invoked as a separate process, never linked into or vendored inside Qwave.
  Its output JSON contains no code from the tool, so the GPL does not attach
  to Qwave (per the FSF's position that a program's output is not covered by
  the program's copyright). Do **not** add `ContentBlockerConverter` as an
  SPM dependency of any shipped target, and do **not** ship its
  "advanced blocking" JavaScript output (`--advanced-blocking` stays off).
- **EasyList is dual-licensed GPLv3 / CC BY-SA 3.0.** Qwave elects the
  CC BY-SA 3.0 branch for the compiled snapshot. The snapshot is data, not
  app code (mere aggregation), so the app's own license is unaffected; the
  snapshot itself carries CC BY-SA 3.0 with attribution in
  `easylist-compiled-ATTRIBUTION.txt`, which ships in the bundle beside it.

## Rule update path (determination, 2026-08-13)

**The shipped path is the committed snapshot.** Rules update by running
`scripts/update-blocklist.sh`, committing the regenerated JSON, and
shipping a release — auditable in diff, covered by the compile tests, and
EdDSA-signed on the way to users like any other code. This is deliberate
for a sovereign browser: the effective blocklist is exactly what the
reviewed repository says it is.

**Current runtime egress — disclosed:** `RemoteBlocklistUpdater` performs
one conditional (ETag-cached) fetch of the upstream EasyList mirror at app
launch. Today its result is **discarded** (the fetch exists to warm the
cache for a future wiring; nothing it downloads reaches the active
shields), so the network egress buys the user nothing. Determination:
either of these is acceptable, the status quo is not —

1. **Remove the launch fetch** until runtime updates are actually wired
   (zero egress, snapshot-only), or
2. **Wire it fully**: fetched lists compile through the existing
   `UBORuleListCompiler` pipeline into the active shields, behind a
   settings toggle that is **off by default** and clearly labelled as
   network egress, with the source URL user-visible.

Until one of those lands, users should know: the fetch contacts
`raw.githubusercontent.com` (the EasyList mirror) once per launch, sends
no identifying data beyond what any HTTPS request carries, and stores only
an ETag. This paragraph is that disclosure.
