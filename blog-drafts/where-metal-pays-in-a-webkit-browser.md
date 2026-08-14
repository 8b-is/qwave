# Where Metal pays in a WebKit browser (and where it doesn't)

> Draft — not published, not reviewed, not final. Status: draft. Target: — (long-form).
> Session: 2026-08-14, Apple Silicon, Xcode 16.4 pinned (CI).

## The temptation

Every macOS app gets the same prompt at some point: "we should use Metal."
For a WebKit browser the answer is more interesting than a yes or no, because
the browser's rendering is *already* GPU-accelerated — it just lives in a
different process than your code.

Qwave's most visible piece of graphics is the domain-warped FBM wave behind
the start page, error pages, and the markdown reader. It is a WebGL fragment
shader, shipped as a string constant in `WaveScene.swift`:

```swift
public enum WaveScene {
    public static let fragmentShader = """
        // "Lost in the Math" — 5-octave fbm, domain-warped
        float fbm ( in vec2 _st) {
            float v = 0.0;
            float a = 0.5;
            vec2 shift = vec2(100.0);
            mat2 rot = mat2(cos(0.5), sin(0.5),
                            -sin(0.5), cos(0.50));
            for (int i = 0; i < NUM_OCTAVES; ++i) {
                v += a * noise(_st);
                _st = rot * _st * 2.0 + shift;
                a *= 0.5;
            }
            return v;
        }
        // ...
        """
```

It runs in a `<canvas>` inside the WebContent process. WebKit compiles that
shader and executes it in its GPU process, which on Apple Silicon is Metal
underneath. "Porting" this to an `MTKView` in the app process would not move
it from CPU to GPU — it was already on the GPU. It would move pixels across a
process boundary, add a compositing layer the window server must blend, and
make the animation depend on the app staying alive. Strictly worse.

## The actual lever: demand control

What Qwave *does* control is how much GPU work its shader asks for, per tab,
per frame:

- The shader runs full-window in every WebContent process that has a wave
  page open — multiple tabs, multiple processes, same shader.
- The render loop was `requestAnimationFrame(render)` with no throttle: on a
  ProMotion display that is up to 120 full-window FBM evaluations per second,
  per tab.
- `prefers-reduced-motion` already existed and rendered a single static
  frame — good, but the default path had no other governor.

The fix is three lines of policy in `WaveScene.canvasScript`:

```js
// GPU demand control: 30 fps is imperceptible for this slow FBM drift
// but halves GPU work on 60 Hz displays and quarters it on ProMotion.
const FPS_CAP_MS = 1000 / 30;
let lastRender = -1000;
let rafId = 0;

function frame(time) {
    if (time - lastRender >= FPS_CAP_MS) {
        lastRender = time;
        render(time);
    }
    rafId = requestAnimationFrame(frame);
}

function onVisibility() {
    if (document.hidden) {
        cancelAnimationFrame(rafId);
    } else if (!reduce) {
        rafId = requestAnimationFrame(frame);
    }
}
document.addEventListener("visibilitychange", onVisibility);
```

The motion is a slow drift; nobody can tell 30 from 120 fps on it. The
reduced-motion branch still renders exactly one static frame. An occluded
window now stops burning GPU entirely.

## The rules we extracted

1. **Find out who owns the pixels first.** In a WebKit app, canvas/WebGL
   pixels belong to the WebContent + GPU processes. App-side Metal is only
   for pixels *your* code draws (custom views, image processing).
2. **When you can't move work, shrink it.** The shader stays where it is;
   the demand it makes is your API: resolution, frame rate, visibility,
   animation policy.
3. **Energy is the metric, not framerate.** A background wave at 120 fps
   that nobody looks at is not "smooth", it's heat. `prefers-reduced-motion`
   is both an accessibility feature and a power budget.

## Where app-side Metal *would* pay

Audited the rest of the chrome while we were here:

- `MemoryWavePanel` — plain SwiftUI text UI; nothing to accelerate.
- `FaviconLoader` — `NSImage(data:)` decode + cache, displayed at tab-bar
  size by the system compositor; no CPU scaling path worth touching.
- Tab snapshots / hibernation — WebKit `takeSnapshot`, already GPU.

Conclusion for this codebase: the app's own drawing is thin enough that the
first Metal port would be speculative. If a future feature draws custom
waveforms or filters pixels, the right starting point is `MTKView` + one
fragment shader, measured against the energy and frame-cost baseline this
session established — not a rewrite of the wave.

## Verified / not verified

- Verified: shader remains valid Swift string content; page markup tests
  (start page, error page, markdown page) are untouched by the JS policy
  change.
- Not verified locally: GPU energy delta — needs a dev machine with Energy
  tab / `powermetrics` while animating several tabs, before and after. CI
  cannot measure GPU energy; report it as a dev-machine measurement, not a
  gate.
