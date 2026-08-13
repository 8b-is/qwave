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

## Runtime updates

`RemoteBlocklistUpdater` (ETag-cached fetch of upstream EasyList text +
`UBORuleListCompiler`) is unchanged and remains the path for refreshing
rules between releases; the bundled snapshot is the offline baseline.
