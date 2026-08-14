// Measured experiment (2026-08-14, Apple M1 Pro, macOS 26.4.1, Xcode 26.4.1):
// 1) the new synchronization primitives vs the classics, under contention
// 2) ARC traffic at an @inline(never) ABI boundary: copyable value passed by
//    value (retain/release per call) vs ~Copyable consumed (zero refcount churn)
import Foundation
import Synchronization
import os

// MARK: - 1. Lock contention: 8 threads x 2M increments

let threads = 8, perThread = 2_000_000

func bench(_ name: String, _ body: @escaping @Sendable (Int) -> Void) {
    let clock = ContinuousClock()
    let t = clock.measure {
        DispatchQueue.concurrentPerform(iterations: threads) { _ in body(perThread) }
    }
    let ms = Double(t.components.attoseconds) / 1e15
    print(name.padding(toLength: 28, withPad: " ", startingAt: 0) + String(format: "%8.1f ms", ms))
}

print("starting locks"); fflush(stdout)
let syncMutex = Mutex<Int>(0)
bench("Mutex (synchronization)") { n in
    for _ in 0..<n { syncMutex.withLock { $0 += 1 } }
}

let unfair = OSAllocatedUnfairLock(initialState: 0)
bench("os_unfair_lock (OSAllocated)") { n in
    for _ in 0..<n { unfair.withLock { $0 += 1 } }
}

let atomic = Atomic<Int>(0)
bench("Atomic<Int> (synchronization)") { n in
    for _ in 0..<n { atomic.add(1, ordering: .relaxed) }
}

final class LockedBox: @unchecked Sendable { var v = 0 }
let nsBox = LockedBox()
let nsLock = NSLock()
bench("NSLock") { n in
    for _ in 0..<n { nsLock.lock(); nsBox.v += 1; nsLock.unlock() }
}

nonisolated(unsafe) let unfairRaw = os_unfair_lock_t.allocate(capacity: 1)
unfairRaw.initialize(to: os_unfair_lock())
bench("os_unfair_lock (raw)") { n in
    for _ in 0..<n {
        os_unfair_lock_lock(unfairRaw)
        // no shared counter; the lock/unlock pair is the cost
        os_unfair_lock_unlock(unfairRaw)
    }
}

print("locks done; starting ARC"); fflush(stdout)
// MARK: - 2. ARC at an inlineless boundary: copy vs consume

final class Box: @unchecked Sendable { let tag = 42 }

struct CopyableValue {
    let box: Box
    let a: Int64 = 1, b: Int64 = 2, c: Int64 = 3, d: Int64 = 4  // 32 bytes + ref
}
struct NonCopyableValue: ~Copyable {
    let box: Box
    let a: Int64 = 1, b: Int64 = 2, c: Int64 = 3, d: Int64 = 4
}

var copySink = 0
var consumeSink = 0
let iterations = 50_000_000
let sharedBox = Box()
var copyableGlobal = CopyableValue(box: sharedBox)
// Callee-side global stores force real ARC traffic: the copyable path
// retains on the copy into the parameter AND on the store into the global
// (releasing the previous occupant); the consume path only replaces the
// global (one release), zero retains.
nonisolated(unsafe) var lastCopy = CopyableValue(box: sharedBox)
nonisolated(unsafe) var lastConsume = NonCopyableValue(box: sharedBox)

@inline(never)
func copyProcess(_ v: CopyableValue) -> Int { lastCopy = v; return v.box.tag }

@inline(never)
func consumeProcess(_ v: consuming NonCopyableValue) -> Int { let tag = v.box.tag; lastConsume = v; return tag }

let clock2 = ContinuousClock()
let copyReuseT = clock2.measure {
    for _ in 0..<iterations { copySink += copyProcess(copyableGlobal) }
}
let copyFreshT = clock2.measure {
    for _ in 0..<iterations { copySink += copyProcess(CopyableValue(box: sharedBox)) }
}
let consumeT = clock2.measure {
    for _ in 0..<iterations { consumeSink += consumeProcess(NonCopyableValue(box: sharedBox)) }
}
func ms(_ d: Duration) -> Double { Double(d.components.attoseconds) / 1e15 }
print("copyable, reused global, N=50M".padding(toLength: 28, withPad: " ", startingAt: 0) + String(format: "%8.1f ms", ms(copyReuseT)))
print("copyable, fresh per iter, N=50M".padding(toLength: 28, withPad: " ", startingAt: 0) + String(format: "%8.1f ms", ms(copyFreshT)))
print("~Copyable consume, N=50M".padding(toLength: 28, withPad: " ", startingAt: 0) + String(format: "%8.1f ms", ms(consumeT)))
print("sinks (must be non-zero):", copySink, consumeSink)
