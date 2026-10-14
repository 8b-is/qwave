# Internal message boundary regression

Run from the repository root on macOS with Xcode and the package dependencies:

```sh
python3 scripts/test-internal-messages.py --output-dir /tmp/qwave-message-results --scratch-path /tmp/qwave-package-build
```

Run separately from other package builds. The runner temporarily installs its
fixture with exclusive creation, uses two SwiftPM workers and a five-minute
timeout, then removes only its own fixture. It serves synthetic Markdown on
loopback and uses nonpersistent offscreen WebKit views. It does not start the
Qwave app, access the user's browser stores, write memories or invoke a model.

The test uses genuine `WKScriptMessage` objects and the production coordinator.
It checks start and timeline actions, page-world and subframe rejection, raw
Markdown scripts, synthetic button clicks, isolated-world capability checks,
fragment navigation, stale view removal, buffered messages after detach, and
tab/document ownership across an async shell handoff. Positive isolated-world
posts are made by the test as privileged native code; they do not prove a
physical click passed the JavaScript `event.isTrusted` gate.

Before release, validate real clicks in the built Mac app: submit from the
start page, all three timeline ranges, and Remember page/selection in local and
remote Markdown, including after a fragment jump and reload. Verify private
reader controls remain absent and switching tabs does not retarget a pending
action. These UI checks require an unlocked Mac and remain distinct from the
automated synthetic results.
