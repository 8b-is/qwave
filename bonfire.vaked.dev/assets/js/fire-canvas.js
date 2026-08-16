/**
 * bonfire — the fire canvas
 * ============================================================================
 * Spec §8: "Center: a canvas fire; chairs as small glow-points around it; each
 * new wave ripples outward, coloured by its VAD. Amplitude = brightness.
 * Frequency = ripple speed. Phase = ripple direction."
 *
 * Everything drawn here is additive (globalCompositeOperation = 'lighter') so
 * overlapping light behaves like light rather than like paint.
 *
 * The canvas is decorative. It carries no information that is not also present
 * as text, it is aria-hidden, and it degrades to a single static frame under
 * `prefers-reduced-motion`.
 * ========================================================================== */

const TAU = Math.PI * 2;
const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');

/** Cheap deterministic value noise — enough for flame flicker, no library. */
function noise1(x) {
  const i = Math.floor(x);
  const f = x - i;
  const a = Math.sin(i * 127.1) * 43758.5453;
  const b = Math.sin((i + 1) * 127.1) * 43758.5453;
  const fa = a - Math.floor(a);
  const fb = b - Math.floor(b);
  const smooth = f * f * (3 - 2 * f);
  return fa + (fb - fa) * smooth;
}

export class FireCanvas {
  /**
   * @param {HTMLCanvasElement} canvas
   * @param {object} [options]
   * @param {number} [options.chairs=0]     number of glow-points around the fire
   * @param {number} [options.intensity=1]  overall brightness multiplier
   * @param {[number, number]} [options.origin=[0.5, 0.72]] fire centre, 0..1
   */
  constructor(canvas, options = {}) {
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d', { alpha: true });
    this.opts = {
      chairs: 0,
      intensity: 1,
      origin: [0.5, 0.72],
      ...options,
    };

    this.sparks = [];
    this.ripples = [];
    this.chairs = [];
    this.time = 0;
    this.running = false;
    this.dpr = 1;
    this.w = 0;
    this.h = 0;

    this._frame = this._frame.bind(this);
    this._resize = this._resize.bind(this);
    this._onVisibility = this._onVisibility.bind(this);

    this.setChairs(this.opts.chairs);
    this._resize();

    this._observer = new ResizeObserver(this._resize);
    this._observer.observe(canvas.parentElement ?? canvas);
    document.addEventListener('visibilitychange', this._onVisibility);
  }

  /* -- lifecycle --------------------------------------------------------- */

  start() {
    if (this.running) return;
    this.running = true;
    if (reduceMotion.matches) {
      // One composed frame, then stop. The fire is still a fire, it just
      // does not move.
      this.time = 3.2;
      for (let i = 0; i < 140; i++) this._stepSparks(1 / 60);
      this._draw();
      this.running = false;
      return;
    }
    this.last = performance.now();
    this.raf = requestAnimationFrame(this._frame);
  }

  stop() {
    this.running = false;
    if (this.raf) cancelAnimationFrame(this.raf);
  }

  destroy() {
    this.stop();
    this._observer?.disconnect();
    document.removeEventListener('visibilitychange', this._onVisibility);
  }

  _onVisibility() {
    if (document.hidden) this.stop();
    else this.start();
  }

  _resize() {
    const rect = (this.canvas.parentElement ?? this.canvas).getBoundingClientRect();
    // Cap DPR at 2 — a fire pit does not need 3× the fill rate.
    this.dpr = Math.min(window.devicePixelRatio || 1, 2);
    this.w = Math.max(rect.width, 1);
    this.h = Math.max(rect.height, 1);
    this.canvas.width = Math.round(this.w * this.dpr);
    this.canvas.height = Math.round(this.h * this.dpr);
    this.canvas.style.width = `${this.w}px`;
    this.canvas.style.height = `${this.h}px`;
    this.ctx.setTransform(this.dpr, 0, 0, this.dpr, 0, 0);
    this._layoutChairs();
    if (!this.running && reduceMotion.matches) this._draw();
  }

  get cx() { return this.w * this.opts.origin[0]; }
  get cy() { return this.h * this.opts.origin[1]; }
  /** The fire's working radius — the scale everything else is drawn against. */
  get scale() { return Math.min(this.w, this.h) * 0.5; }

  /* -- chairs (spec §2, pillar 2) ---------------------------------------- */

  setChairs(count) {
    const n = Math.max(0, Math.min(count | 0, 64));
    this.chairs = Array.from({ length: n }, (_, i) => ({
      // Distribute around the ring with a little irregularity — people do not
      // sit on a perfect circle.
      angle: (i / Math.max(n, 1)) * TAU + noise1(i * 3.7) * 0.22,
      radius: 0.82 + noise1(i * 9.1) * 0.28,
      phase: noise1(i * 5.3) * TAU,
      warmth: 0.55 + noise1(i * 2.2) * 0.45,
    }));
    this._layoutChairs();
  }

  _layoutChairs() {
    const r = this.scale;
    for (const chair of this.chairs) {
      chair.x = this.cx + Math.cos(chair.angle) * r * chair.radius * 0.86;
      chair.y = this.cy + Math.sin(chair.angle) * r * chair.radius * 0.34;
    }
  }

  /* -- ripples (spec §8) -------------------------------------------------- */

  /**
   * Send a wave outward from the fire.
   * @param {object} wave
   * @param {number} wave.amplitude  0..1  → brightness
   * @param {number} wave.frequency  Hz    → ripple speed
   * @param {number} wave.phase_deg  0..360→ ripple direction
   * @param {string} wave.color      css colour from the wave's VAD
   */
  ripple({ amplitude = 0.6, frequency = 2, phase_deg = 90, color = '#ff7a3d' } = {}) {
    this.ripples.push({
      r: this.scale * 0.12,
      amplitude: Math.max(0.05, Math.min(amplitude, 1)),
      // 0.2–8 Hz maps onto a comfortable visible spread rate.
      speed: this.scale * (0.12 + Math.min(frequency, 8) * 0.055),
      direction: (phase_deg * Math.PI) / 180,
      color,
      life: 1,
    });
    if (this.ripples.length > 24) this.ripples.shift();

    // A wave entering the lattice throws sparks.
    const burst = Math.round(6 + amplitude * 18);
    for (let i = 0; i < burst; i++) this._spawnSpark(amplitude, color);
  }

  /* -- sparks ------------------------------------------------------------- */

  _spawnSpark(boost = 0, color = null) {
    const spread = this.scale * 0.13;
    this.sparks.push({
      x: this.cx + (Math.random() - 0.5) * spread,
      y: this.cy + (Math.random() - 0.5) * spread * 0.4,
      vx: (Math.random() - 0.5) * 14,
      vy: -(26 + Math.random() * 54) * (1 + boost * 0.5),
      life: 1,
      decay: 0.24 + Math.random() * 0.42,
      size: 0.7 + Math.random() * 1.9,
      seed: Math.random() * 100,
      color,
    });
    if (this.sparks.length > 260) this.sparks.shift();
  }

  _stepSparks(dt) {
    // Ambient spark production, scaled to the fire's size.
    const want = reduceMotion.matches ? 0 : 2.4;
    if (Math.random() < want * dt * 12) this._spawnSpark();

    for (let i = this.sparks.length - 1; i >= 0; i--) {
      const s = this.sparks[i];
      s.life -= s.decay * dt;
      if (s.life <= 0) { this.sparks.splice(i, 1); continue; }
      // Buoyancy falls off as the ember cools; lateral drift wanders.
      s.vy += 16 * dt;
      s.vx += Math.sin(this.time * 1.7 + s.seed) * 22 * dt;
      s.x += s.vx * dt;
      s.y += s.vy * dt;
    }
  }

  /* -- render ------------------------------------------------------------- */

  _frame(now) {
    if (!this.running) return;
    const dt = Math.min((now - this.last) / 1000, 1 / 20);
    this.last = now;
    this.time += dt;

    this._stepSparks(dt);

    for (let i = this.ripples.length - 1; i >= 0; i--) {
      const rp = this.ripples[i];
      rp.r += rp.speed * dt;
      rp.life -= dt * 0.42;
      if (rp.life <= 0 || rp.r > this.scale * 2.2) this.ripples.splice(i, 1);
    }

    this._draw();
    this.raf = requestAnimationFrame(this._frame);
  }

  _draw() {
    const { ctx } = this;
    ctx.clearRect(0, 0, this.w, this.h);
    ctx.globalCompositeOperation = 'lighter';

    this._drawGroundGlow();
    this._drawChairs();
    this._drawRipples();
    this._drawFlames();
    this._drawSparks();

    ctx.globalCompositeOperation = 'source-over';
  }

  /** The pool of light the fire casts on the ground. */
  _drawGroundGlow() {
    const { ctx } = this;
    const flicker = 0.86 + noise1(this.time * 3.1) * 0.28;
    const r = this.scale * 1.5 * flicker;
    const g = ctx.createRadialGradient(this.cx, this.cy, 0, this.cx, this.cy, r);
    const i = this.opts.intensity;
    g.addColorStop(0, `rgba(255, 156, 84, ${0.20 * i * flicker})`);
    g.addColorStop(0.32, `rgba(255, 108, 48, ${0.11 * i})`);
    g.addColorStop(0.68, `rgba(168, 82, 132, ${0.045 * i})`);
    g.addColorStop(1, 'rgba(0,0,0,0)');
    ctx.fillStyle = g;
    ctx.beginPath();
    ctx.ellipse(this.cx, this.cy, r, r * 0.62, 0, 0, TAU);
    ctx.fill();
  }

  /** The flame body: stacked lobes, each wobbling on its own noise track. */
  _drawFlames() {
    const { ctx } = this;
    const base = this.scale * 0.30;
    const lobes = 5;

    for (let i = 0; i < lobes; i++) {
      const t = i / lobes;
      const wobble = noise1(this.time * (2.2 + i * 0.7) + i * 12.3) - 0.5;
      const lift = noise1(this.time * (1.4 + i * 0.5) + i * 4.1);

      const w = base * (0.92 - t * 0.55) * (0.86 + lift * 0.34);
      const h = base * (1.5 - t * 0.42) * (0.82 + lift * 0.46);
      const x = this.cx + wobble * base * (0.30 + t * 0.5);
      const y = this.cy - h * (0.30 + t * 0.42);

      const g = ctx.createRadialGradient(x, y, 0, x, y, Math.max(w, h));
      // Hot white-gold core → ember orange → deep red, cooling outward.
      const heat = this.opts.intensity * (0.9 + lift * 0.3);
      if (i === 0) {
        g.addColorStop(0, `rgba(255, 246, 214, ${0.62 * heat})`);
        g.addColorStop(0.28, `rgba(255, 198, 108, ${0.40 * heat})`);
      } else {
        g.addColorStop(0, `rgba(255, 190, 116, ${(0.34 - t * 0.16) * heat})`);
      }
      g.addColorStop(0.6, `rgba(255, 122, 61, ${(0.20 - t * 0.10) * heat})`);
      g.addColorStop(1, 'rgba(120, 30, 20, 0)');

      ctx.fillStyle = g;
      ctx.beginPath();
      ctx.ellipse(x, y, w, h, 0, 0, TAU);
      ctx.fill();
    }
  }

  /** Chairs — anonymous seats, felt as small warm points around the ring. */
  _drawChairs() {
    const { ctx } = this;
    for (const chair of this.chairs) {
      const breathe = 0.68 + Math.sin(this.time * 0.9 + chair.phase) * 0.32;
      const r = this.scale * 0.052 * (0.7 + breathe * 0.5);
      const alpha = 0.16 + breathe * 0.30 * chair.warmth;

      const g = ctx.createRadialGradient(chair.x, chair.y, 0, chair.x, chair.y, r);
      g.addColorStop(0, `rgba(255, 200, 140, ${alpha})`);
      g.addColorStop(0.45, `rgba(230, 181, 102, ${alpha * 0.5})`);
      g.addColorStop(1, 'rgba(165, 159, 196, 0)');
      ctx.fillStyle = g;
      ctx.beginPath();
      ctx.arc(chair.x, chair.y, r, 0, TAU);
      ctx.fill();
    }
  }

  /**
   * Ripples. The ring is stroked in segments whose alpha is modulated by
   * cos(θ − phase), so the wave visibly leans in its phase direction while
   * still closing the circle — direction, not a one-sided arc.
   */
  _drawRipples() {
    const { ctx } = this;
    const SEGMENTS = 48;

    for (const rp of this.ripples) {
      const fade = rp.life * rp.life;
      ctx.lineWidth = Math.max(1, this.scale * 0.012 * (0.4 + rp.amplitude));
      ctx.strokeStyle = rp.color;

      for (let i = 0; i < SEGMENTS; i++) {
        const a0 = (i / SEGMENTS) * TAU;
        const a1 = ((i + 1) / SEGMENTS) * TAU;
        // 0.35 floor keeps the whole ring present; the rest leans downwind.
        const lean = 0.35 + 0.65 * (0.5 + 0.5 * Math.cos(a0 - rp.direction));
        ctx.globalAlpha = fade * rp.amplitude * lean * 0.5 * this.opts.intensity;
        ctx.beginPath();
        // Squashed vertically — the ring travels across the ground, not the wall.
        ctx.ellipse(this.cx, this.cy, rp.r, rp.r * 0.42, 0, a0, a1);
        ctx.stroke();
      }
      ctx.globalAlpha = 1;
    }
  }

  _drawSparks() {
    const { ctx } = this;
    for (const s of this.sparks) {
      const twinkle = 0.55 + Math.sin(this.time * 9 + s.seed) * 0.45;
      const alpha = s.life * s.life * twinkle * this.opts.intensity;
      const r = s.size * (0.5 + s.life * 0.9);

      const g = ctx.createRadialGradient(s.x, s.y, 0, s.x, s.y, r * 3.4);
      if (s.color) {
        g.addColorStop(0, s.color);
        g.addColorStop(1, 'rgba(0,0,0,0)');
        ctx.globalAlpha = alpha * 0.75;
      } else {
        g.addColorStop(0, `rgba(255, 226, 170, ${alpha})`);
        g.addColorStop(0.4, `rgba(255, 140, 70, ${alpha * 0.55})`);
        g.addColorStop(1, 'rgba(255, 90, 40, 0)');
        ctx.globalAlpha = 1;
      }
      ctx.fillStyle = g;
      ctx.beginPath();
      ctx.arc(s.x, s.y, r * 3.4, 0, TAU);
      ctx.fill();
    }
    ctx.globalAlpha = 1;
  }
}

/** Convenience: wire a canvas up and start it. */
export function mountFire(selector, options) {
  const canvas = typeof selector === 'string' ? document.querySelector(selector) : selector;
  if (!canvas) return null;
  const fire = new FireCanvas(canvas, options);
  fire.start();
  return fire;
}
