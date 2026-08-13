import SwiftUI
import MemoryWave

struct MemoryWavePanelView: View {
    var title: String
    var bodyText: String
    var footnote: String
    var isBusy: Bool
    var askDraft: Binding<String>
    var onAsk: () -> Void
    var onRemember: () -> Void
    var onSummarize: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "waveform")
                Text("Memory Wave").font(.headline)
                Spacer()
                if isBusy { ProgressView().controlSize(.small) }
            }
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            ScrollView {
                Text(bodyText.isEmpty ? "Nothing yet. Remember a page, summarize it, or ask — never automatic." : bodyText)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 140, maxHeight: 260)
            HStack {
                Button("Remember", action: onRemember)
                Button("Summarize", action: onSummarize)
            }
            HStack {
                TextField("Ask about this page…", text: askDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(onAsk)
                Button("Ask", action: onAsk)
                    .disabled(askDraft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy)
            }
            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 420)
    }
}
