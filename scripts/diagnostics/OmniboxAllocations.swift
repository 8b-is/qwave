import Foundation

// Diagnostic only: the same synthetic URLs as the 500-entry Omnibox benchmark.
// Primitive counts cannot establish whole-suggester performance or change a gate.
let urls = (0..<500).map { URL(string: "https://site\($0 % 97).example/page/\($0)")! }
let cachedHosts = urls.map { $0.host ?? "" }
let libc = dlopen(nil, RTLD_NOW)!
let allocate = unsafeBitCast(
    dlsym(libc, "malloc")!, to: (@convention(c) (Int) -> UnsafeMutableRawPointer?).self)
let deallocate = unsafeBitCast(
    dlsym(libc, "free")!, to: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self)

@inline(never) func emptyControl() -> Int { 50000 }

@inline(never) func allocationControl() -> Int {
    var checksum = 0
    for index in 0..<100 {
        let pointer = allocate(128)!
        pointer.storeBytes(of: index, as: Int.self)
        checksum &+= pointer.load(as: Int.self)
        deallocate(pointer)
    }
    return checksum
}

@inline(never) func absoluteStrings() -> Int {
    var checksum = 0
    for _ in 0..<100 {
        for url in urls { checksum &+= url.absoluteString.utf8.count }
    }
    return checksum
}

@inline(never) func legacyHosts() -> Int {
    var checksum = 0
    for _ in 0..<100 {
        for url in urls { checksum &+= (url.host ?? "").utf8.count }
    }
    return checksum
}

@inline(never) func encodedHosts() -> Int {
    var checksum = 0
    for _ in 0..<100 {
        for url in urls { checksum &+= (url.host(percentEncoded: true) ?? "").utf8.count }
    }
    return checksum
}

@inline(never) func guardedHosts() -> Int {
    var checksum = 0
    for _ in 0..<100 {
        for url in urls {
            let host: String?
            if let encoded = url.host(percentEncoded: true),
                !encoded.utf8.contains(where: { $0 == 0x25 || $0 >= 0x80 })
            {
                host = encoded
            } else {
                host = url.host
            }
            checksum &+= (host ?? "").utf8.count
        }
    }
    return checksum
}

@inline(never) func cachedHostReads() -> Int {
    var checksum = 0
    for _ in 0..<100 {
        for host in cachedHosts { checksum &+= host.utf8.count }
    }
    return checksum
}

let operations: [(String, () -> Int)] = [
    ("empty_control", emptyControl),
    ("malloc_100_control", allocationControl),
    ("absolute_string_500x100", absoluteStrings),
    ("legacy_host_500x100", legacyHosts),
    ("encoded_host_500x100", encodedHosts),
    ("guarded_host_500x100", guardedHosts),
    ("cached_host_read_500x100", cachedHostReads),
]
var measurements = [[String: Any]]()
for (name, operation) in operations {
    let expected = operation()
    for trial in 1...3 {
        let before = qwave_allocation_count()
        let checksum = operation()
        let after = qwave_allocation_count()
        precondition(after >= before, "Allocation counter moved backwards")
        let count = after - before
        precondition(checksum == expected, "Operation checksum changed")
        if name == "malloc_100_control" {
            precondition(count >= 100, "Positive control did not observe its 100 allocations")
        }
        measurements.append([
            "case": name, "trial": trial, "malloc_count": count, "checksum": checksum,
        ])
    }
}
let report: [String: Any] = [
    "backend": "jemalloc small + large nrequests",
    "jemalloc_version": String(cString: qwave_jemalloc_version()),
    "os": ProcessInfo.processInfo.operatingSystemVersionString,
    "fixture_urls": urls.count,
    "passes_per_trial": 100,
    "measurements": measurements,
]
print(
    String(
        decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
        as: UTF8.self
    ))
