import AppKit
import Foundation
import Persistence

/// Compiled with the real app loader by scripts/test-favicon-privacy.py.
/// All hosts, image responses and database rows are synthetic.
@main
struct FaviconPrivacyProbe {
    static let container = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let burner = UUID(uuidString: "00000000-0000-0000-0000-00000000EE01")!
    static let ordinary = "ordinary.invalid"
    static let privateHost = "private.invalid"

    @MainActor
    static func fetch(
        _ loader: FaviconLoader, _ url: URL, host: String, containerID: UUID? = nil,
        policy: FaviconLoader.CachePolicy
    ) async -> NSImage? {
        await withCheckedContinuation { continuation in
            loader.load(iconURL: url, pageHost: host, containerID: containerID, cachePolicy: policy) {
                continuation.resume(returning: $0)
            }
        }
    }

    @MainActor
    static func isRed(_ image: NSImage?) -> Bool {
        guard let image, let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let color = bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB)
        else { preconditionFailure("Expected a decoded fixture image") }
        return color.redComponent > color.blueComponent
    }

    @MainActor
    static func cached(_ loader: FaviconLoader, host: String, containerID: UUID? = nil) async throws -> NSImage? {
        for _ in 0..<100 {
            if let image = loader.cachedIcon(forHost: host, containerID: containerID, cachePolicy: .persistent) {
                return image
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    @MainActor
    static func main() async throws {
        let mode = CommandLine.arguments[1]
        let database = try SQLiteDatabase(url: URL(fileURLWithPath: CommandLine.arguments[2]))
        let store = try await FaviconStore(database: database)
        let loader = FaviconLoader(store: store)
        let base = URL(string: CommandLine.arguments[3])!
        let redURL = base.appendingPathComponent("red.png")
        let blueURL = base.appendingPathComponent("blue.png")
        let red = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[4]))
        let blue = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[5]))
        var checks: [String] = []

        // Includes missing views (fresh/hibernated) and nonpersistent views
        // whose tab flag is false. A profile alone cannot permit persistence.
        for privateWindow in [false, true] {
            for ephemeralTab in [false, true] {
                for ephemeralContainer in [false, true] {
                    for persistent in [true, false, nil] as [Bool?] {
                        let policy = FaviconLoader.CachePolicy(
                            isPrivateWindow: privateWindow, isEphemeralTab: ephemeralTab,
                            isEphemeralContainer: ephemeralContainer, dataStoreIsPersistent: persistent)
                        let expected = !privateWindow && !ephemeralTab && !ephemeralContainer && persistent == true
                        precondition((policy == .persistent) == expected)
                    }
                }
            }
        }
        checks.append("24 privacy-policy combinations")

        if mode == "write" {
            // An ordinary persisted icon must be invisible to a private read,
            // even before the loader has populated its memory cache.
            try await store.store(host: ordinary, containerID: nil, data: red)
            for _ in 0..<3 {
                precondition(loader.cachedIcon(forHost: ordinary, containerID: nil, cachePolicy: .tabOnly) == nil)
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let diskImage = try await cached(loader, host: ordinary)
            precondition(isRed(diskImage))
            let privateImage = await fetch(loader, blueURL, host: ordinary, policy: .tabOnly)
            precondition(!isRed(privateImage))
            precondition(isRed(loader.cachedIcon(forHost: ordinary, containerID: nil, cachePolicy: .persistent)))
            let unchanged = try await store.load(host: ordinary, containerID: nil)
            precondition(unchanged == red)
            checks.append("private read/fetch ignores ordinary disk and memory caches; ordinary image unchanged")

            // Private default-container and burner-container requests leave no
            // reusable memory entry or database row, even on repeated loads.
            for id in [nil, burner] as [UUID?] {
                let first = await fetch(loader, redURL, host: privateHost, containerID: id, policy: .tabOnly)
                let second = await fetch(loader, blueURL, host: privateHost, containerID: id, policy: .tabOnly)
                let repeated = await fetch(loader, blueURL, host: privateHost, containerID: id, policy: .tabOnly)
                precondition(isRed(first) && !isRed(second) && !isRed(repeated))
                precondition(loader.cachedIcon(forHost: privateHost, containerID: id, cachePolicy: .tabOnly) == nil)
                precondition(loader.cachedIcon(forHost: privateHost, containerID: id, cachePolicy: .persistent) == nil)
            }
            checks.append("private default/burner requests have no shared cache; repeated URL fetches stay independent")

            let isolated = await fetch(loader, blueURL, host: ordinary, containerID: container, policy: .persistent)
            precondition(!isRed(isolated))
            let cachedAgain = await fetch(loader, redURL, host: ordinary, containerID: container, policy: .persistent)
            precondition(!isRed(cachedAgain))
            checks.append("ordinary container cache reuse remains isolated from default")

            // Both fetches must complete even when an ordinary request for the
            // same key is in flight; the private result must not replace it.
            async let ordinaryFlight = fetch(loader, redURL, host: "overlap.invalid", policy: .persistent)
            async let privateFlight = fetch(loader, blueURL, host: "overlap.invalid", policy: .tabOnly)
            let (normal, ephemeral) = await (ordinaryFlight, privateFlight)
            precondition(isRed(normal) && !isRed(ephemeral))
            checks.append("concurrent private/ordinary requests complete independently")

            for _ in 0..<100 {
                let ordinaryBytes = try await store.load(host: ordinary, containerID: container)
                let overlapBytes = try await store.load(host: "overlap.invalid", containerID: nil)
                if ordinaryBytes == blue && overlapBytes == red { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        } else {
            precondition(mode == "restart")
            let ordinaryImage = try await cached(loader, host: ordinary)
            let containerImage = try await cached(loader, host: ordinary, containerID: container)
            precondition(isRed(ordinaryImage) && !isRed(containerImage))
            precondition(loader.cachedIcon(forHost: ordinary, containerID: nil, cachePolicy: .tabOnly) == nil)
            precondition(loader.cachedIcon(forHost: ordinary, containerID: container, cachePolicy: .tabOnly) == nil)
            checks.append("fresh process reuses only ordinary persisted icons; private reads remain empty")
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        let ordinaryBytes = try await store.load(host: ordinary, containerID: nil)
        let containerBytes = try await store.load(host: ordinary, containerID: container)
        let overlapBytes = try await store.load(host: "overlap.invalid", containerID: nil)
        precondition(ordinaryBytes == red && containerBytes == blue && overlapBytes == red)
        for id in [nil, burner] as [UUID?] {
            let privateBytes = try await store.load(host: privateHost, containerID: id)
            precondition(privateBytes == nil)
            precondition(loader.cachedIcon(forHost: privateHost, containerID: id, cachePolicy: .persistent) == nil)
        }
        let rows = try await database.rows("SELECT host FROM favicons;")
        precondition(rows.count == 3, "Only the three ordinary fixture rows may persist")
        checks.append("exactly three ordinary rows persist; no private rows")
        let report: [String: Any] = ["mode": mode, "checks": checks, "status": "passed"]
        print(
            String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    }
}
