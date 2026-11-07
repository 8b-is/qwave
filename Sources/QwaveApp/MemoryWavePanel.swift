import SwiftUI
import MemoryWave
import SovereignCore

struct MemoryWavePanelView: View {
    var title: String
    var bodyText: String
    var footnote: String
    var isBusy: Bool
    var askDraft: Binding<String>
    var onAsk: () -> Void
    var onRemember: () -> Void
    var onSummarize: () -> Void

    @State private var ingestMode: RustI1Soul.IngestMode = .mine
    @State private var creatorHandle: String = "hue@8b.is"
    @State private var showFieldPolicies: Bool = false
    @State private var fieldPolicies: [RustI1Soul.PersonalField: RustI1Soul.FieldPolicy] = [
        .username: .alwaysAllow,
        .email: .askEveryTime,
        .phone: .requiredFormsOnly,
        .website: .alwaysAllow,
        .blog: .alwaysAllow,
        .xHandle: .alwaysAllow,
        .redditHandle: .alwaysAllow,
        .githubHandle: .alwaysAllow,
        .physicalAddress: .neverStrip,
        .legalName: .askEveryTime,
    ]

    private var evaluation: RustI1Soul.DeedEvaluation {
        let sample = bodyText.isEmpty ? title : bodyText
        return RustI1Soul.evaluateDeed(
            creatorId: creatorHandle,
            canonicalURL: title,
            pageText: sample,
            mode: ingestMode
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "waveform")
                    .accessibilityHidden(true)
                Text("Memory Wave × Smart Tree × i1.is").font(.headline)
                Spacer()
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Processing memory wave")
                }
            }
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            ScrollView {
                Text(
                    bodyText.isEmpty
                        ? "Nothing yet. Remember a page, summarize it, or seal its Soul Signature for i1.is — never automatic." : bodyText
                )
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 110, maxHeight: 200)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("i1.is Provenance & AI Training Consent")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    let authPct = Int((Double(evaluation.organicAuthenticityQ10) / 1024.0) * 100.0)
                    Text(String(format: "Soul %08X · %d%% Authentic", UInt32(truncatingIfNeeded: evaluation.soulTag), authPct))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.teal)
                }

                Picker("Disposition", selection: $ingestMode) {
                    ForEach(RustI1Soul.IngestMode.allCases, id: \.rawValue) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                HStack(spacing: 8) {
                    TextField("Creator ID / Soul Handle", text: $creatorHandle)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    Button(showFieldPolicies ? "Hide PII Rules" : "Personal Fields…") {
                        showFieldPolicies.toggle()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if showFieldPolicies {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(RustI1Soul.PersonalField.allCases, id: \.rawValue) { field in
                                HStack {
                                    Text(field.label)
                                        .font(.caption2)
                                        .frame(width: 96, alignment: .leading)
                                    Picker("", selection: Binding(
                                        get: { fieldPolicies[field] ?? .askEveryTime },
                                        set: { fieldPolicies[field] = $0 }
                                    )) {
                                        ForEach(RustI1Soul.FieldPolicy.allCases, id: \.rawValue) { pol in
                                            Text(pol.shortLabel).tag(pol)
                                        }
                                    }
                                    .labelsHidden()
                                    .controlSize(.mini)
                                }
                            }
                        }
                    }
                    .frame(height: 120)
                }

                HStack {
                    let stSavingsPct = Int((Double(evaluation.smartTreeSavingsQ10) / 1024.0) * 100.0)
                    Text("🌲 Smart Tree .m8: \(evaluation.smartTreeNodes) nodes (-\(stSavingsPct)% tokens) · \(evaluation.redactionCount) PII scrubbed")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            HStack {
                Button("Remember", action: onRemember)
                    .buttonStyle(.bordered)
                    .disabled(isBusy || ingestMode == .noArchivePrivate)
                    .accessibilityLabel("Remember this page")
                Button("Summarize", action: onSummarize)
                    .buttonStyle(.bordered)
                    .disabled(isBusy || !evaluation.canSummarizeLocal)
                    .accessibilityLabel("Summarize this page")
            }
            HStack {
                TextField("Ask about this page…", text: askDraft)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Question prompt")
                    .onSubmit(onAsk)
                Button("Ask", action: onAsk)
                    .buttonStyle(.borderedProminent)
                    .disabled(askDraft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy)
                    .accessibilityLabel("Ask Memory Wave")
            }
            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 440)
    }
}
