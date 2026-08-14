// Measured experiment: Qwave's shipped "Lost in the Math" WebGL wave
// (WaveScene.fragmentShader — 5-octave fbm + domain warp) as a Metal
// compute kernel vs a scalar CPU port, at the real canvas resolution.
// The color mixes are omitted (they don't change the ALU profile); the
// final fbm value is written to a buffer so nothing gets optimized away.
import Metal
import Foundation
import simd

let width = 1512, height = 982            // realistic window canvas (1x)
let pixels = width * height
let frames = 100                           // GPU frames measured
let cpuFrames = 5                          // CPU is ~100x slower; 5 frames is honest

// MARK: - MSL kernel (exact port of the GLSL math)

let msl = """
#include <metal_stdlib>
using namespace metal;
constant float2x2 rot = float2x2(0.8775825619, 0.4794255386, -0.4794255386, 0.8775825619); // cos/sin(0.5), compile-time
static float rand2(float2 st) { return fract(sin(dot(st, float2(12.9898, 78.233))) * 43758.5453123); }
static float noise2(float2 st) {
    float2 i = floor(st); float2 f = fract(st);
    float a = rand2(i); float b = rand2(i + float2(1.0, 0.0));
    float c = rand2(i + float2(0.0, 1.0)); float d = rand2(i + float2(1.0, 1.0));
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}
static float fbm(float2 st) {
    float v = 0.0; float a = 0.5; float2 shift = float2(100.0);
    for (int k = 0; k < 5; ++k) { v += a * noise2(st); st = rot * st * 2.0 + shift; a *= 0.5; }
    return v;
}
kernel void wave_main(uint2 gid [[thread_position_in_grid]],
                      constant float2& resolution [[buffer(0)]],
                      constant float& time [[buffer(1)]],
                      device float* out [[buffer(2)]]) {
    float2 st = float2(gid) / resolution;
    st.x *= resolution.x / resolution.y;
    float2 q; q.x = fbm(st); q.y = fbm(st + float2(1.0));
    float2 r; r.x = fbm(st + 1.0 * q + float2(1.7, 9.2) + 0.15 * time);
              r.y = fbm(st + 1.0 * q + float2(8.3, 2.8) + 0.126 * time);
    uint idx = (uint)(gid.y * resolution.x + gid.x);
    out[idx] = fbm(st + r);
}
"""

// MARK: - CPU reference (same math, scalar Float)

var sinCount: Int = 0
func rand2(_ st: SIMD2<Float>) -> Float { sinCount += 1; let s = sin((st * SIMD2<Float>(12.9898, 78.233)).sum()) * 43758.5453123; return s - floor(s) }

func noise2(_ st: SIMD2<Float>) -> Float {
    let i = floor(st)
    let f = st - i
    let a = rand2(i)
    let b = rand2(i + SIMD2<Float>(1, 0))
    let c = rand2(i + SIMD2<Float>(0, 1))
    let d = rand2(i + SIMD2<Float>(1, 1))
    let u: SIMD2<Float> = f * f * (3.0 - 2.0 * f)
    let vx: Float = a + (b - a) * u.x
    let vy: Float = (c - a) * u.y * (1.0 - u.x)
    let vz: Float = (d - b) * u.x * u.y
    return vx + vy + vz
}

func fbmCPU(_ st: SIMD2<Float>) -> Float {
    var v: Float = 0, a: Float = 0.5, s = st
    let shift = SIMD2<Float>(100, 100)
    let c = cosf(0.5), sn = sinf(0.5)
    for _ in 0..<5 {
        v += a * noise2(s)
        s = SIMD2(c * s.x - sn * s.y, sn * s.x + c * s.y) * 2 + shift
        a *= 0.5
    }
    return v
}

// Global accumulator: a local sink can be proven dead by the optimizer and
// the whole loop eliminated (measured the hard way). A global that is read
// after timing cannot be.
var cpuSink: Float = 0

func cpuFrame() -> (ms: Double, sum: Double) {
    var frameSum: Double = 0
    let clock = ContinuousClock()
    let t = clock.measure {
        for y in 0..<height {
            for x in 0..<width {
                var st = SIMD2<Float>(Float(x), Float(y)) / SIMD2(Float(width), Float(height))
                st.x *= Float(width) / Float(height)
                let q = SIMD2<Float>(fbmCPU(st), fbmCPU(st + SIMD2<Float>(1, 0)))
                let r = SIMD2<Float>(
                    fbmCPU(st + q + SIMD2(1.7, 9.2)),
                    fbmCPU(st + q + SIMD2(8.3, 2.8)))
                let v = fbmCPU(st + r)
                cpuSink += v
                frameSum += Double(v)
            }
        }
    }
    return (Double(t.components.attoseconds) / 1e18 * 1000, frameSum)  // ms, sum
}

// MARK: - GPU path

guard let device = MTLCreateSystemDefaultDevice() else { fatalError("no Metal device") }
let library = try device.makeLibrary(source: msl, options: nil)
let kernel = library.makeFunction(name: "wave_main")!
let pipeline = try device.makeComputePipelineState(function: kernel)

let resBuffer = device.makeBuffer(bytes: [Float(width), Float(height)], length: 16, options: [])!
let timeBuffer = device.makeBuffer(length: 16, options: [])!
let outBuffer = device.makeBuffer(length: pixels * 4, options: [])!
let queue = device.makeCommandQueue()!

func gpuFrame() -> Double {
    let start = CFAbsoluteTimeGetCurrent()
    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pipeline)
    enc.setBuffer(resBuffer, offset: 0, index: 0)
    enc.setBuffer(timeBuffer, offset: 0, index: 1)
    enc.setBuffer(outBuffer, offset: 0, index: 2)
    enc.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    enc.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
    return (CFAbsoluteTimeGetCurrent() - start) * 1000
}

func gpuOverhead() -> Double {  // empty kernel: host dispatch + wait cost
    let start = CFAbsoluteTimeGetCurrent()
    for _ in 0..<frames {
        let cb = queue.makeCommandBuffer()!
        let enc = cb.makeComputeCommandEncoder()!
        enc.setComputePipelineState(pipeline)
        enc.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
    }
    return (CFAbsoluteTimeGetCurrent() - start) * 1000 / Double(frames)
}

// warmup
_ = gpuFrame()
var gpuTimes: [Double] = []
for _ in 0..<frames { gpuTimes.append(gpuFrame()) }
let overhead = gpuOverhead()
let gpuAvg = gpuTimes.reduce(0, +) / Double(frames)
let gpuKernel = max(0, gpuAvg - overhead)
let outPtr = outBuffer.contents().assumingMemoryBound(to: Float.self)
var metalChecksum: Double = 0
for i in 0..<pixels { metalChecksum += Double(outPtr[i]) }

var cpuTimes: [Double] = []
var cpuSums: [Double] = []
for _ in 0..<cpuFrames { let r = cpuFrame(); cpuTimes.append(r.ms); cpuSums.append(r.sum) }
let cpuAvg = cpuTimes.reduce(0, +) / Double(cpuTimes.count)
let cpuChecksum = cpuSums[0]
// Observable read: without it the optimizer can prove the global dead and
// eliminate the whole loop (confirmed twice the hard way).
print("cpu sink (must be non-zero):", cpuSink)
print("checksum cpu:", cpuChecksum, "metal:", metalChecksum)
print("sin calls (expected ~740M for 5 frames):", sinCount)

let formatter = { (ms: Double) -> String in String(format: "%8.2f", ms) }
print("resolution: \(width)x\(height) = \(pixels) pixels")
print("GPU  (Metal compute, \(device.name)): avg \(formatter(gpuAvg)) ms/frame  [host+dispatch \(formatter(overhead)) ms, kernel ~\(formatter(gpuKernel)) ms]")
print("CPU  (scalar Swift, 1 core):        avg \(formatter(cpuAvg)) ms/frame")
print("speedup: \(String(format: "%.0f", cpuAvg / gpuAvg))x  (\(String(format: "%.0f", cpuAvg / max(gpuKernel, 0.001)))x vs kernel-only)")
print("30fps cap budget: \(formatter(33.33)) ms -> GPU uses \(String(format: "%.1f", gpuAvg / 33.33 * 100))% of the budget")
print("fps potential: GPU \(String(format: "%.0f", 1000 / max(gpuKernel, 0.001))) | CPU \(String(format: "%.2f", 1000 / cpuAvg))")
