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

To exercise the trusted-input gate, run the native-input fixture separately:

```sh
python3 scripts/test-internal-messages.py --native-input --output-dir /tmp/qwave-native-input-results --scratch-path /tmp/qwave-package-build
```

This opens a temporary AppKit window containing a nonpersistent WebKit view.
Run it while the desktop is idle: the fixture briefly activates its window,
then closes it and restores the previous application. It delivers AppKit mouse
events directly to the hit-tested native view and asserts both JavaScript
`event.isTrusted` and the production coordinator's action callback. The twelve
cases cover start-page submission, all three timeline ranges, and local/remote
Markdown Remember page/selection, fragment navigation and reload. All document
content and network responses are synthetic; the fixture does not access the
user's Qwave stores, Keychain or model services.

Native automated input is distinct from a person clicking in the built Qwave
app. Before release, also smoke-test the app shell: verify private reader
controls remain absent, switching tabs does not retarget a pending action, and
the start, timeline and Markdown controls work through the complete UI. The
fixtures test the production coordinator and message boundaries, but do not
launch the complete browser or validate its window wiring.
