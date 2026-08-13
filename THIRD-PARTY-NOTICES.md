# Third-party notices

Qwave itself is MIT-licensed (see [LICENSE](LICENSE)). It ships with, or is
built using, the following third-party material.

## Data shipped inside the app

### EasyList (compiled snapshot)

`easylist-compiled.json` (bundled in the Shields module) is derived from
**EasyList** (<https://easylist.to/>), © The EasyList authors. EasyList is
dual-licensed **GPLv3 / CC BY-SA 3.0**; Qwave elects the
**Creative Commons Attribution-ShareAlike 3.0 Unported** branch
(<https://creativecommons.org/licenses/by-sa/3.0/>).

- The compiled snapshot is itself distributed under **CC BY-SA 3.0** — the
  ShareAlike condition attaches to the *data asset*, which ships alongside
  the app's code as a separable collection member (mere aggregation), not
  as an adaptation of the app or vice versa. Qwave's own code remains MIT.
- Attribution ships in the app bundle beside the data
  (`easylist-compiled-ATTRIBUTION.txt`, including the exact upstream
  version and conversion provenance).
- The converter (AdGuard SafariConverterLib, GPL-3.0) runs strictly at
  build time and is **not** distributed with Qwave in any form — see
  [docs/BLOCKLIST.md](docs/BLOCKLIST.md).

**Status of this determination**: engineering-level, based on the licence
texts and the FSF/CC aggregation positions, recorded 2026-08-13. It is the
common reading for filter-list redistribution (uBlock Origin, Brave and
AdGuard all ship EasyList-derived data inside differently-licensed
software). If Qwave is ever distributed through a store with its own IP
warranty, or commercially, have counsel confirm the aggregation reading —
that is a human legal decision, not an engineering one.

## Frameworks and packages shipped in the app

| Component | License | Shipped as |
|---|---|---|
| [Sparkle](https://github.com/sparkle-project/Sparkle) 2.9.5 | MIT | embedded framework (auto-update) |
| [WebURL](https://github.com/karwa/swift-url) 0.4.2 | Apache-2.0 | statically linked (`URLIdentity`) |
| [swift-log](https://github.com/apple/swift-log) 1.6.x | Apache-2.0 | statically linked (`QwaveSupport`) |
| [WireGuardKit](https://github.com/WireGuard/wireguard-apple) (vendored @ `2fec12a6`) | MIT | tunnel extension |

## Build/test-time only (not distributed)

| Component | License | Role |
|---|---|---|
| [SafariConverterLib](https://github.com/AdguardTeam/SafariConverterLib) v4.3.0 | GPL-3.0 | external build-time list converter |
| [swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing) | MIT | test dependency |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | MIT | project generation |
