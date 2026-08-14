// foundation-models-probe: availability tri-state, TTFT/total latency per input
// size, quality notes, and provider-seam verification for FoundationModels
// (macOS 26 SDK, arm64e-apple-macos.swiftinterface read verbatim).
//
// Strict Swift 6 concurrency. Zero network. Reads committed fixtures only.
import Foundation
import FoundationModels

// MARK: - Availability

@available(macOS 26.0, *)
func probeAvailability() -> [String: Any] {
    let model = SystemLanguageModel.default
    var out: [String: Any] = [:]
    switch model.availability {
    case .available:
        out["state"] = "available"
    case .unavailable(let reason):
        out["state"] = "unavailable"
        out["reason"] = "\(reason)"
    }
    out["isAvailable"] = model.isAvailable
    out["contextSize"] = model.contextSize
    out["supportedLanguageCount"] = model.supportedLanguages.count
    out["supportsCurrentLocale"] = model.supportsLocale(Locale.current)
    // The three UnavailableReason cases compile (proving the enum surface):
    // .deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady.
    // The observed machine can only ever exhibit one at a time; the mapping to
    // app behaviour (vanish cleanly per state) is documented in README.md.
    return out
}

// MARK: - Guardrails × instructions matrix

// First smoke run refused a plain municipal-news summary ("May contain
// sensitive content") — but the refused runs also carried an `instructions`
// string, while the accepted control had none. Two variables moved at once;
// this 4-cell matrix pins the refusal to a variable. Same fixture, same
// prompt, greedy sampling.
@available(macOS 26.0, *)
func guardrailsMatrix(_ text: String) async -> [[String: Any]] {
    let clock = ContinuousClock()
    let prompt = "Summarise the following page in three sentences:\n\n\(text)"
    let instructions = "You are a precise summariser. Summarise concisely; never add outside knowledge."
    var cells: [[String: Any]] = []
    for (gName, guardrails) in [
        ("default", SystemLanguageModel.Guardrails.default),
        ("permissive", SystemLanguageModel.Guardrails.permissiveContentTransformations),
    ] {
        for (iName, instr) in [("none", nil as String?), ("set", instructions)] {
            let session = LanguageModelSession(
                model: SystemLanguageModel(useCase: .general, guardrails: guardrails),
                tools: [],
                instructions: instr
            )
            let started = clock.now
            do {
                let r = try await session.respond(to: prompt)
                cells.append([
                    "guardrails": gName, "instructions": iName,
                    "outcome": "accepted",
                    "latencyMs": ms(clock.now - started),
                    "summary": String(r.content.prefix(120)),
                ])
            } catch let e {
                cells.append([
                    "guardrails": gName, "instructions": iName,
                    "outcome": "refused",
                    "error": String("\(e)".prefix(200)),
                    "latencyMs": ms(clock.now - started),
                ])
            }
        }
    }
    return cells
}

// MARK: - Stream vs respond path probe

// Every fixture run that used streamResponse (with a tokenCount call before
// it) refused instantly; every plain respond() call in the matrix accepted.
// Three-way isolation: respond alone / tokenCount-then-respond /
// streamResponse alone.
@available(macOS 26.0, *)
func streamPathProbe(_ text: String) async -> [[String: Any]] {
    let clock = ContinuousClock()
    let prompt = "Summarise the following page in three sentences:\n\n\(text)"
    let model = SystemLanguageModel(useCase: .general, guardrails: .default)
    var cells: [[String: Any]] = []

    // 1. respond alone
    do {
        let s = LanguageModelSession(model: model)
        let t = clock.now
        let r = try await s.respond(to: prompt)
        cells.append(["path": "respond-only", "outcome": "accepted", "latencyMs": ms(clock.now - t)])
    } catch let e {
        cells.append(["path": "respond-only", "outcome": "refused", "error": String("\(e)".prefix(120))])
    }

    // 2. tokenCount, then respond (same session)
    do {
        let s = LanguageModelSession(model: model)
        var n: Int?
        if #available(macOS 26.4, *) {
            n = try? await SystemLanguageModel.default.tokenCount(for: prompt.promptRepresentation)
        }
        let t = clock.now
        let r = try await s.respond(to: prompt)
        cells.append([
            "path": "tokenCount-then-respond", "tokens": n as Any, "outcome": "accepted",
            "latencyMs": ms(clock.now - t),
        ])
    } catch let e {
        cells.append(["path": "tokenCount-then-respond", "outcome": "refused", "error": String("\(e)".prefix(120))])
    }

    // 3. streamResponse alone
    do {
        let s = LanguageModelSession(model: model)
        let t = clock.now
        var text = ""
        for try await snap in s.streamResponse(to: prompt, generating: String.self) {
            text = snap.content
        }
        cells.append([
            "path": "stream-only", "outcome": "accepted", "latencyMs": ms(clock.now - t), "chars": text.count,
        ])
    } catch let e {
        cells.append(["path": "stream-only", "outcome": "refused", "error": String("\(e)".prefix(120))])
    }

    // 4. streamResponse with an innocuous prompt (content control: does the
    //    stream path refuse ANYTHING, or just this content class?)
    do {
        let s = LanguageModelSession(model: model)
        let t = clock.now
        var text = ""
        for try await snap in s.streamResponse(to: "Say hello in one short sentence.", generating: String.self) {
            text = snap.content
        }
        cells.append([
            "path": "stream-innocuous", "outcome": "accepted", "latencyMs": ms(clock.now - t), "chars": text.count,
            "sample": String(text.prefix(60)),
        ])
    } catch let e {
        cells.append(["path": "stream-innocuous", "outcome": "refused", "error": String("\(e)".prefix(120))])
    }
    return cells
}

// MARK: - Latency + quality

@available(macOS 26.0, *)
struct FixtureRun {
    let fixture: String
    let sample: Int
    let inputChars: Int
    let inputTokens: Int?
    let ttftMs: Double
    let totalMs: Double
    let outputChars: Int
    let summary: String
    let error: String?
}

@available(macOS 26.0, *)
func runFixture(
    _ text: String, name: String, sample: Int, mode: String
) async -> [String: Any] {
    let clock = ContinuousClock()
    // Settled by the probes: guardrails/instructions do not matter, and
    // streamResponse refuses this content class on macOS 26.4.1 (see
    // streamPathProbe) — so TTFT is reported as unavailable and the fixture
    // runs use the proven respond() path. Total latency is the usable metric.
    let session = LanguageModelSession(
        model: SystemLanguageModel(useCase: .general, guardrails: .default)
    )
    let prompt =
        "Summarise the following page in exactly three sentences:\n\n\(text)"

    var inputTokens: Int?
    if #available(macOS 26.4, *) {
        inputTokens = try? await SystemLanguageModel.default.tokenCount(
            for: prompt.promptRepresentation
        )
    }

    var total: Duration = .zero
    var summary = ""
    var error: String?
    var refusals = 0
    // The refusals are nondeterministic (same input accepted 4/4 in the
    // matrix, refused 2/2 in the fixture loop) — retry up to 3 attempts per
    // sample and count the refusals so the flakiness is quantified.
    for attempt in 1...3 where error != nil || summary.isEmpty {
        do {
            let started = clock.now
            let r = try await session.respond(to: prompt)
            total = clock.now - started
            summary = r.content
            error = nil
            break
        } catch let e {
            error = "\(e)"
            if String(describing: e).contains("refusal") { refusals += 1 }
            if attempt < 3 { try? await Task.sleep(for: .milliseconds(500)) }
        }
    }

    // Reasoning-degradation probe on the dense fixture only: a direct question,
    // not a summary. The brief expects the ~3B @ ~2-bit model to degrade here.
    var reasoning: [String: Any]?
    if mode == "full" && name == "dense-technical" && sample == 1 {
        let rSession = LanguageModelSession(model: .default)
        let rStarted = clock.now
        do {
            let r = try await rSession.respond(
                to:
                    "Given this page, what exactly does the spec claim about the second cache index, and why? Quote the relevant sentence if it exists:\n\n\(text)"
            )
            reasoning = [
                "answer": r.content,
                "latencyMs": ms(clock.now - rStarted),
            ]
        } catch {
            reasoning = ["error": "\(error)"]
        }
    }

    var out: [String: Any] = [
        "fixture": name,
        "sample": sample,
        "inputChars": text.count,
        "inputTokens": inputTokens as Any,
        "ttftMs": "unavailable (streamResponse refuses this content class on macOS 26.4.1 — see streamPathProbe)"
            as Any,
        "totalMs": ms(total),
        "outputChars": summary.count,
        "summary": summary,
        "refusalCount": refusals,
    ]
    if let error { out["error"] = error }
    if let reasoning { out["reasoningProbe"] = reasoning }
    return out
}

// MARK: - Provider seam

@available(macOS 26.0, *)
func probeProviderSeam() -> [String: Any] {
    // Compile-time evidence: there is no public `LanguageModelProvider` /
    // `Provider` protocol in FoundationModels (macOS 26.4 SDK swiftinterface).
    // The extension point is `SystemLanguageModel.Adapter` — model *assets*,
    // not a generic protocol any LLM backend can conform to.
    var out: [String: Any] = [:]
    out["protocolsInModule"] = [
        "Generable", "ConvertibleFromGeneratedContent", "ConvertibleToGeneratedContent",
        "InstructionsRepresentable", "PromptRepresentable", "Tool",
    ]
    out["providerProtocolPresent"] = false
    out["seam"] = "SystemLanguageModel.Adapter (init(name:)/init(fileURL:) + compile())"
    // Runtime evidence: the adapter registry query is non-throwing and safe.
    let ids = SystemLanguageModel.Adapter.compatibleAdapterIdentifiers(
        name: "com.example.mlx-backend"
    )
    out["adapterIdentifiersForExampleName"] = ids
    // LanguageModelSession binds concretely to SystemLanguageModel; a custom
    // backend plugs in via SystemLanguageModel(adapter:), i.e. model files
    // packaged as adapter assets — not by conforming to a protocol.
    out["sessionModelParameterType"] = "SystemLanguageModel (concrete, not protocol)"
    return out
}

// MARK: - Entry

@available(macOS 26.0, *)
func ms(_ d: Duration) -> Double {
    let c = d.components
    return Double(c.seconds) * 1_000 + Double(c.attoseconds) / 1e15
}

@main
struct Probe {
    static func main() async {
        var args = Set(CommandLine.arguments.dropFirst())
        let mode = args.remove("--quick") != nil ? "quick" : "full"
        let skipProbes = args.remove("--skip-probes") != nil
        let prewarm = args.remove("--prewarm") != nil
        let onlyFixture = args.first(where: { $0.hasPrefix("--fixture=") })?
            .replacingOccurrences(of: "--fixture=", with: "")

        let fm = FileManager.default
        let root = URL(fileURLWithPath: fm.currentDirectoryPath)
        let fixtureDir = root.appendingPathComponent("Fixtures")
        let fixtures = ["news-article", "docs-page", "dense-technical", "paywalled-teaser", "spa-rendered"]

        var results: [String: Any] = [:]
        results["_stamps"] = [
            "date": ISO8601DateFormatter().string(from: Date()),
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "machine": hostname(),
            "mode": mode,
        ]

        if #available(macOS 26.0, *) {
            results["availability"] = probeAvailability()
            results["providerSeam"] = probeProviderSeam()

            if prewarm {
                // prewarm experiment (P1c of docs/SUMMARIZE.md): time the
                // prewarm call itself, then the fixture run below measures the
                // first-response latency with the model already warm.
                let clock = ContinuousClock()
                let session = LanguageModelSession(
                    model: SystemLanguageModel(useCase: .general, guardrails: .default)
                )
                let t = clock.now
                session.prewarm(promptPrefix: nil)
                results["prewarmExperiment"] = [
                    "prewarmDurationMs": ms(clock.now - t),
                    "note": "fixture first-sample latency below is post-prewarm",
                ]
            }

            if !skipProbes {
                let controlText =
                    (try? String(
                        contentsOf: fixtureDir.appendingPathComponent("news-article.txt"),
                        encoding: .utf8
                    )) ?? ""
                results["guardrailsMatrix"] = await guardrailsMatrix(controlText)
                results["streamPathProbe"] = await streamPathProbe(controlText)
            }

            var runs: [[String: Any]] = []
            for fixture in fixtures where onlyFixture == nil || onlyFixture == fixture {
                guard
                    let text = try? String(
                        contentsOf: fixtureDir.appendingPathComponent(fixture + ".txt"),
                        encoding: .utf8
                    )
                else {
                    runs.append(["fixture": fixture, "error": "missing fixture file"])
                    continue
                }
                let samples = mode == "quick" ? [1] : [1, 2]
                for sample in samples {
                    let r = await runFixture(text, name: fixture, sample: sample, mode: mode)
                    runs.append(r)
                }
            }
            results["runs"] = runs
        } else {
            results["runs"] = ["error": "FoundationModels requires macOS 26+"]
        }

        let out = root.appendingPathComponent("results.json")
        try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            .write(to: out)
        print("wrote \(out.path)")
    }

    static func hostname() -> String {
        var name = [CChar](repeating: 0, count: 256)
        _ = gethostname(&name, name.count)
        return String(decoding: name.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
    }
}
