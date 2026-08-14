# Polling is a battery bug: notification-driven energy policy

> Draft — not published, not reviewed, not final. Status: draft. Target: — (long-form).
> Session: 2026-08-14, Apple Silicon, Xcode 16.4 pinned (CI).

## The bug we found

Qwave's energy governor maps system conditions (thermal state, Low Power
Mode, window occlusion, memory pressure) to a policy: hibernation timeout,
background-media suspension, warm WebContent process count. The policy is
pure and well-tested. The problem was *when* it ran.

The app sampled `ProcessInfo.processInfo.thermalState` and
`isLowPowerModeEnabled` **once per 30-second tick** — a coalesced
`DispatchSourceTimer` with 10 s leeway. Occlusion was read the same way.
The chain of latencies:

- user enables Low Power Mode (or the system crosses a thermal tier, or the
  last window is covered)
- … up to 30 s until the next tick
- … plus up to 10 s leeway
- = **up to 40 seconds** before the governor shortens the hibernation
  timeout by 3×, suspends background media, and drops the warm process.

For a battery-focused browser this is exactly backwards: the *most*
important policy transitions are the ones the user triggers deliberately,
and they were the slowest to apply.

## The fix: the OS already tells you

`ProcessInfo` posts notifications for exactly these events. So does the
window server for occlusion. Three observers, one throttled wrapper, and
the existing tick becomes event-driven:

```swift
private func startEnergyObservers() {
    func observe(_ name: Notification.Name) {
        energyObservers.append(
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.energyTickFromNotification()
                }
            }
        )
    }
    observe(ProcessInfo.thermalStateDidChangeNotification)
    observe(NSNotification.Name.NSProcessInfoPowerStateDidChange)
    observe(NSWindow.didChangeOcclusionStateNotification)
}

private func energyTickFromNotification() async {
    guard environment != nil else { return }
    let now = Date()
    guard now.timeIntervalSince(lastNotificationEnergyTick) >= energyNotificationMinInterval
    else { return }
    lastNotificationEnergyTick = now
    await energyTick()
}
```

Design decisions that matter:

1. **Throttle the wrapper, not the tick.** The 30 s timer is the steady
   cadence and is never throttled; the notification path coalesces to one
   tick per 5 s. Window-stacking fires occlusion notifications in a storm;
   without the gate each one would run a full policy sweep.
2. **Reuse the existing tick.** `energyTick()` already computes conditions,
   derives policy, and applies it per window. The observers just change
   *when* it runs — zero policy-logic duplication.
3. **Guard the async bootstrap.** The environment is built in a launch
   `Task`; the first notifications can arrive before it exists. The wrapper
   checks before touching it — the same hazard the original timer had, but
   reachable in milliseconds now.

## The API gotcha that saved us a wrong commit

The Swift name for the low-power notification is *not*
`ProcessInfo.powerStateDidChangeNotification` (it doesn't exist), and not
the ObjC constant either. The compiler's rename diagnostic gave it:

```swift
// 'NSProcessInfoPowerStateDidChangeNotification' has been renamed to:
NSNotification.Name.NSProcessInfoPowerStateDidChange
```

While `thermalStateDidChange` lives on `ProcessInfo`, the power one lives
on `NSNotification.Name`. One SDK, two conventions. This is exactly the
kind of thing a `swiftc -typecheck` pass catches before CI does — the whole
app target typechecks in seconds against the built modules.

## The audit (what we looked for, what we found)

The energy pass also scanned for O(n²) and polling patterns across the
package. Findings worth keeping on record:

- **Only two periodic timers exist** in the app: the 30 s energy tick
  (coalesced, leeway — fixed here) and the VPN rekey timer (tunnel
  crypto, deliberately untouched).
- **Shields `applyLists`** already has an object-identity fast path that
  skips remove-all + re-add when the identical list objects are attached;
  the signposted rebuild event is the redundant-rebuild signal.
- **Chrome refresh** is KVO-coalesced to one per runloop turn and touches
  only title/button states.
- **Tab hibernation scan** is O(tabs) per tick with a single media-playback
  IPC per non-selected tab (the selected tab's probe was already removed).
- **MemoryNibble tag dedup** looked quadratic in a grep and turned out to
  be Set-backed — a reminder that pattern-matching for complexity is only a
  lead, never a finding.
- **`MarkdownCompiler.escapeLoose`** has a pathological worst case (many
  unmatched `<` characters) that is quadratic in the length of the input.
  Realistic documents never hit it, and fixing it while preserving the
  byte-identical output contract from the allocation work was judged not
  worth the risk — it is documented here instead.

## Rules extracted

1. **Polling a state the OS already broadcasts is a bug, not a design.** If
   `NotificationCenter` has a name for it, listen; keep timers for cadence,
   not discovery.
2. **Throttle the entry point, keep the cadence timer authoritative.** The
   steady timer guarantees progress; the notification path just accelerates
   it.
3. **The launch guard is not optional.** Any observer installed during
   `didFinishLaunching` can fire before the app's own async bootstrap
   completes. `guard environment != nil` is the difference between a
   notification and a crash.

## Verified / not verified

- Verified: whole-target typecheck under Swift 6 strict concurrency,
  swift-format strict, policy logic untouched (the pure governor had zero
  diffs).
- Not verified locally: end-to-end timing of a Low Power Mode toggle
  (needs a real machine + Energy tab / `powermetrics` while toggling);
  CI cannot drive system power state.
