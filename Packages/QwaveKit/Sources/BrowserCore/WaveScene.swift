import Foundation

/// The domain-warped WebGL wave — shared by the start page, error pages,
/// and the markdown reader. Fragment shader is the "Lost in the Math" scene.
public enum WaveScene {
    public static let fragmentShader = """
        #ifdef GL_ES
        precision highp float;
        #endif

        uniform float u_time;
        uniform vec2 u_resolution;

        float random (in vec2 _st) {
            return fract(sin(dot(_st.xy, vec2(12.9898,78.233))) * 43758.5453123);
        }

        float noise (in vec2 _st) {
            vec2 i = floor(_st);
            vec2 f = fract(_st);
            float a = random(i);
            float b = random(i + vec2(1.0, 0.0));
            float c = random(i + vec2(0.0, 1.0));
            float d = random(i + vec2(1.0, 1.0));
            vec2 u = f * f * (3.0 - 2.0 * f);
            return mix(a, b, u.x) +
                    (c - a)* u.y * (1.0 - u.x) +
                    (d - b) * u.x * u.y;
        }

        #define NUM_OCTAVES 5
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

        void main() {
            vec2 st = gl_FragCoord.xy/u_resolution.xy;
            st.x *= u_resolution.x/u_resolution.y;

            vec3 color = vec3(0.0);
            vec2 q = vec2(0.);
            q.x = fbm( st + 0.00*u_time);
            q.y = fbm( st + vec2(1.0));

            vec2 r = vec2(0.);
            r.x = fbm( st + 1.0*q + vec2(1.7,9.2)+ 0.15*u_time );
            r.y = fbm( st + 1.0*q + vec2(8.3,2.8)+ 0.126*u_time);

            float f = fbm(st+r);

            color = mix(vec3(0.101961,0.619608,0.666667),
                        vec3(0.666667,0.666667,0.498039),
                        clamp((f*f)*4.0,0.0,1.0));

            color = mix(color,
                        vec3(0.0,0.0,0.164706),
                        clamp(length(q),0.0,1.0));

            color = mix(color,
                        vec3(0.666667,1.0,1.0),
                        clamp(length(r.x),0.0,1.0));

            gl_FragColor = vec4((f*f*f+.6*f*f+.5*f)*color,1.0);
        }
        """

    public static let canvasScript = """
        (function () {
          const canvas = document.getElementById("glCanvas");
          if (!canvas) return;
          const gl = canvas.getContext("webgl");
          if (!gl) return;

          const vertexShaderSource = `
            attribute vec2 position;
            void main() { gl_Position = vec4(position, 0.0, 1.0); }
          `;
          const fragmentShaderSource = document.getElementById("fragShader").text;

          function createShader(gl, type, source) {
            const shader = gl.createShader(type);
            gl.shaderSource(shader, source);
            gl.compileShader(shader);
            if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
              console.error(gl.getShaderInfoLog(shader));
              gl.deleteShader(shader);
              return null;
            }
            return shader;
          }

          const vertexShader = createShader(gl, gl.VERTEX_SHADER, vertexShaderSource);
          const fragmentShader = createShader(gl, gl.FRAGMENT_SHADER, fragmentShaderSource);
          if (!vertexShader || !fragmentShader) return;

          const program = gl.createProgram();
          gl.attachShader(program, vertexShader);
          gl.attachShader(program, fragmentShader);
          gl.linkProgram(program);
          if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
            console.error(gl.getProgramInfoLog(program));
            return;
          }
          gl.useProgram(program);

          const positionLocation = gl.getAttribLocation(program, "position");
          const buffer = gl.createBuffer();
          gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
          gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([
            -1, -1,  1, -1, -1,  1,
            -1,  1,  1, -1,  1,  1,
          ]), gl.STATIC_DRAW);
          gl.enableVertexAttribArray(positionLocation);
          gl.vertexAttribPointer(positionLocation, 2, gl.FLOAT, false, 0, 0);

          const uTimeLocation = gl.getUniformLocation(program, "u_time");
          const uResolutionLocation = gl.getUniformLocation(program, "u_resolution");
          const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

          function resize() {
            canvas.width = window.innerWidth;
            canvas.height = window.innerHeight;
            gl.viewport(0, 0, canvas.width, canvas.height);
          }
          window.addEventListener("resize", resize);
          resize();

          function render(time) {
            const seconds = reduce ? 8.0 : time * 0.001;
            gl.uniform1f(uTimeLocation, seconds);
            gl.uniform2f(uResolutionLocation, canvas.width, canvas.height);
            gl.drawArrays(gl.TRIANGLES, 0, 6);
          }

          // GPU demand control. The shader runs in WebKit's GPU process
          // (Metal-backed on Apple Silicon), one instance per tab, full
          // window. 30 fps is imperceptible for this slow FBM drift but
          // halves GPU work on 60 Hz displays and quarters it on ProMotion;
          // pausing on visibilitychange covers occluded windows.
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

          if (reduce) {
            render(8000);
          } else if (!document.hidden) {
            rafId = requestAnimationFrame(frame);
          }
        })();
        """

    public static let overlayCSS = """
        body, html { margin: 0; padding: 0; overflow: hidden; background: #000; height: 100%;
                     font-family: 'Courier New', Courier, monospace; }
        canvas { display: block; width: 100%; height: 100%; position: fixed; inset: 0; z-index: 0; }
        .overlay {
            position: absolute; top: 50%; left: 50%; transform: translate(-50%, -50%);
            text-align: center; z-index: 10; color: rgba(255, 255, 255, 0.9);
            mix-blend-mode: exclusion; pointer-events: none; width: min(720px, 92vw);
        }
        .overlay.interactive, .overlay a, .overlay button, .overlay input, .overlay form {
            pointer-events: auto;
        }
        h1 { font-size: 8rem; margin: 0; letter-spacing: -5px; font-weight: 700; }
        .lead { font-size: 1.5rem; margin-bottom: 30px; text-transform: uppercase; letter-spacing: 5px; }
        .escape-btn {
            display: inline-block; padding: 15px 40px; border: 1px solid rgba(255, 255, 255, 0.5);
            color: #fff; text-decoration: none; font-size: 1.2rem; text-transform: uppercase;
            letter-spacing: 3px; transition: all 0.3s ease; background: rgba(0, 0, 0, 0.3);
            backdrop-filter: blur(5px); cursor: pointer; font-family: inherit;
        }
        .escape-btn:hover { background: #fff; color: #000; box-shadow: 0 0 20px rgba(255, 255, 255, 0.5); }
        """
}
