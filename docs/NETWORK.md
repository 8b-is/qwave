# What Qwave sends

Qwave is a sovereign browser: its thesis is that you can know, and control,
what it sends. This page is the honest answer. It is written for a person,
not an auditor — though the code origins are cited so an auditor can check
every claim.

There are three kinds of outbound connection, and the difference matters:

- **A — Qwave's own.** Code in this app decided to make the request. This is
  the category Qwave is fully responsible for, and the one this page holds
  itself to: every A connection must be justified and either
  user-controllable or documented here as not.
- **B — WebKit fetching a page you asked for.** You navigated somewhere;
  WebKit loads that page and its subresources. Not Qwave's decision, but
  Qwave's Shields and container isolation govern it.
- **C — WebKit's own service traffic.** Things the web engine may do on its
  own, independent of a specific navigation (fraud checks, prefetch,
  connectivity probes). Least visible, and the part a sovereignty claim most
  depends on — so it gets the most honest treatment below.

> Status of this document: the Category A inventory is verified by reading
> every network call site in the codebase (origins cited). Category C is
> verified from WebKit's configuration in this app plus documented WebKit
> behaviour; full on-the-wire confirmation (mitmproxy against a local build)
> is a tracked follow-up, noted per row.

## Category A — Qwave's own egress

| Endpoint | Why | When | Can you turn it off? | Origin |
|---|---|---|---|---|
| `github.com/8b-is/qwave/releases/latest/download/appcast.xml` | Auto-update: check whether a newer signed release exists | "Check for Updates…" (you click it), and — only after you consent on first run — a periodic background check | **Yes.** Never runs before you consent; the automatic check is a setting you control. See [Auto-updates](#auto-updates). | Sparkle, `SUFeedURL` in `project.yml` |
| `api.mullvad.net` | VPN: relay list, account/device registration | Only when you use the VPN (log in, connect, pick a relay) | **Yes** — happens only if you use the built-in Mullvad VPN. No VPN, no request. | `VPNKit/MullvadAPIClient.swift` |
| `raw.githubusercontent.com/.../easylist.txt` | Refresh the ads/trackers blocklist | **At every launch, unconditionally** | **Not currently** — this is a known defect being fixed (see [Known issue](#known-issue-launch-time-blocklist-fetch)). | `Sources/QwaveApp/BrowserEnvironment.swift`, fired from `AppDelegate` |
| `api.x.ai/v1` (default; any HTTPS endpoint you set) | Memory Wave: summarise / ask over your own captured pages | Only when you invoke Remember/Summarize/Ask **and** have turned on a remote AI provider and entered a key | **Yes — off by default.** With no provider configured, nothing is sent. Only page titles/times are ever sent to a remote provider, never page bodies. | `MemoryWave/MemoryProvider.swift`; default in `MemoryWavePreferences.swift` |
| The relay's in-tunnel gateway (`10.64.0.1`, inside the VPN) | Post-quantum key exchange for the VPN tunnel | Only during a quantum-resistant VPN connection | **Yes** — only if you use the VPN with quantum resistance on. This address is reachable only *inside* the tunnel, never on the open internet. | `VPNKit/QuantumTransport.swift` |
| The favicon URL of a site you visit | Show the site's icon in the tab | When you load a page | Tied to browsing. Fetched with a **cookie-free, storage-free** session and cached per container, so a favicon fetch can never carry one container's identity into another. | `Sources/QwaveApp/FaviconLoader.swift` |
| A `.md`/directory URL you navigate to | Render remote markdown in the reader | When you navigate to a markdown document | Tied to that navigation — it fetches exactly the document you asked for. | `BrowserCore/NavigationCoordinator.swift` |

**Reading this table:** the only Category-A egress that is not either
off-by-default, VPN-gated, or a direct consequence of a page you asked for is
the blocklist launch fetch — and that is a defect, called out below, not a
design choice.

## Category B — pages you asked for

When you navigate somewhere, WebKit fetches that page and whatever it embeds
(images, scripts, fonts, XHR/fetch the page makes). Qwave does not add to or
subtract from the set of things the page itself requests, except to **block**:

- **Shields** apply a ~59k-rule EasyList content blocker plus per-site
  JavaScript control, so many third-party trackers a page would otherwise
  load never connect at all.
- **HTTPS-First** rewrites `http://` main-frame loads to `https://`.
- **Containers** keep cookies/storage separate per container, and burner
  (ephemeral) tabs keep nothing.

This is the traffic you initiate by browsing. Qwave's job here is to shield
it, not to add to it.

## Category C — WebKit's own service traffic

These are things the web engine can do on its own. Qwave configures WebKit,
so what is on and off is Qwave's responsibility to disclose even though the
requests originate inside WebKit.

| Behaviour | On? | What it means | Follow-up |
|---|---|---|---|
| **Fraudulent-website warning** (Safe Browsing) | **On** | WebKit checks sites you visit against a fraud/malware database. On Apple platforms this contacts **Apple's** Safe Browsing service (Apple proxies Google/Tencent Safe Browsing so the provider never sees your IP, but Apple's servers receive hashed URL prefixes for hosts you navigate to). It protects against phishing; it is also egress on navigation. | Whether to expose an off switch (WebKit's `isFraudulentWebsiteWarningEnabled` is a per-configuration flag Qwave already sets) is an open product decision. On-the-wire confirmation of exactly what is sent needs a mitmproxy sweep — tracked. |
| **Known-hosts HTTPS upgrade** | On | WebKit upgrades known HSTS hosts to HTTPS using a **built-in list shipped with the engine**. No network request — it is a local lookup. | None — local only. |
| DNS prefetch / speculative connections | Engine default | WebKit may resolve or preconnect to hosts a page hints at (`rel=dns-prefetch`/`preconnect`). Driven by page content, so effectively Category B, but initiated speculatively. | Confirm scope empirically in the same mitmproxy sweep. |

**The honest statement:** the fraudulent-website warning is on, and it is the
one piece of Qwave's network behaviour that talks to a third party (Apple) on
navigation without an explicit per-visit choice. It is a real anti-phishing
protection, not telemetry — but a sovereignty-first browser should let you
decide. That decision, and the empirical confirmation of exactly what
crosses the wire, is the next piece of work after this inventory.

## Auto-updates

Qwave uses Sparkle. `SUEnableAutomaticChecks` is deliberately **not** set, so
Sparkle asks your permission before it ever checks automatically, and
"Check for Updates…" in the app menu is always a manual, explicit action.
Update downloads are EdDSA-signed; a compromised host cannot serve a forged
update. (The consent flow and the "check automatically" setting are being
audited and hardened — see the network-hardening work in progress.)

## Known issue: launch-time blocklist fetch

Today Qwave fetches the upstream EasyList at every launch and, in the current
build, discards the result — network egress that buys you nothing. This is a
bug in a privacy product and is being removed or moved behind an
off-by-default, clearly-labelled setting. Until that lands, this page
discloses it rather than omitting it. See
[docs/BLOCKLIST.md](BLOCKLIST.md).

---

*If the honest answer to any row is "we send this and you cannot turn it
off", this page says so. A disclosed limitation is worth more than an
omitted one.*
