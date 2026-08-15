# Zero-egress Safe Browsing

Qwave blocks known-malicious hosts entirely, on-device, with **zero egress**.
Unlike Google Safe Browsing or Apple's fraudulent-website warning, Qwave never
sends a host, URL, hash, or hash-prefix to any network service. Every check is
a local `WKContentRuleList` match inside WebKit.

## How it works

1. A malicious-host set ships as an app resource in hosts-file format:
   `Packages/QwaveKit/Sources/Shields/Resources/malicious-hosts.txt`.
2. `HostsRuleListCompiler` compiles it to WebKit content-blocker JSON — one
   `block` rule per host, matching the host and all its subdomains on any
   scheme. The committed output is
   `Packages/QwaveKit/Sources/Shields/Resources/malicious-hosts-compiled.json`.
3. `RuleListCompiler` compiles that JSON to a `WKContentRuleList` at runtime
   (cached by content hash), exactly like the EasyList ads/trackers list.
4. `ShieldsDirector` attaches the Safe Browsing list to every web view. It is
   **always-on**: unlike the ad/HTTPS toggles it is not gated by per-site
   policy, so a site's "shields down" override cannot defeat a malicious-host
   block.

The blocklist and its matching are the same content-blocking pipeline used for
ads and trackers — no new network capability, no per-navigation lookup.

## The shipped list is a sample

`malicious-hosts.txt` uses only RFC 2606 / RFC 6761 reserved domains
(`.example`, `.test`, `.invalid`) so it can never block a real site. Replace it
with a real threat feed for production use (see below).

## Sourcing / updating the full list

Any hosts-format threat feed works, e.g.:

- [URLhaus](https://urlhaus.abuse.ch/) (abuse.ch) — malware host feed
- [Phishing.Database](https://github.com/mitchellkrogza/Phishing.Database)
- StevenBlack's consolidated hosts

Two ways to refresh, both keeping the zero-egress guarantee at browse time:

### Build-time (default, recommended)

Drop a hosts-format feed into
`Packages/QwaveKit/Sources/Shields/Resources/malicious-hosts.txt`, regenerate
the compiled resource with `HostsRuleListCompiler.compileJSON(from:)` (its
output is deterministic — hosts sorted, keys sorted), write it to
`malicious-hosts-compiled.json`, then re-run the tests:

```sh
swift test --package-path Packages/QwaveKit --filter HostsRuleListCompilerTests
```

`HostsRuleListCompilerTests.testBundledCompiledResourceMatchesSource` fails if
`malicious-hosts-compiled.json` is not the faithful compilation of
`malicious-hosts.txt`, so the two can never drift.

### Runtime (opt-in, default OFF)

If a runtime list refresh is ever wired up, it MUST:

- download **only the list file itself** — never a per-navigation lookup;
- be **explicit opt-in** and **default OFF**;
- reuse the existing `RemoteBlocklistUpdater` seam (conditional `ETag`
  request), which downloads a list and compiles it locally.

No runtime updater is enabled for Safe Browsing in this build. The list is
built-in and static; matching is always 100% local.

## Guarantees enforced by tests

- `EgressGuardTests.testShieldsLaunchPathMakesNoNetworkRequest` — the shields
  launch path (which now also compiles the Safe Browsing list) makes no
  network request at all.
- `HostsRuleListCompilerTests` — the compiler is pure/local, the compiled
  resource matches its source, and it compiles through WebKit's real engine.
