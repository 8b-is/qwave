import SwiftUI

/// The Summarize panel: honest about the cost (12–16 s warm on M1 Pro —
/// docs/SUMMARIZE.md), with a Cancel that abandons the response. The summary
/// is inert, selectable text. Nothing here can act: no links, no buttons
/// downstream of the model beyond Cancel.
struct SummarizePanelView: View {
    var title: String
    var bodyText: String
    var footnote: String
    var isBusy: Bool
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "text.badge.star")
                    .accessibilityHidden(true)
                Text("Summarize").font(.headline)
                Spacer()
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Summarizing content")
                } else if bodyText.isEmpty {
                    Image(systemName: "bolt.slash")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Summary unavailable")
                }
            }
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            ScrollView {
                Text(bodyText)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120, maxHeight: 260)
            if isBusy {
                HStack {
                    Text("On-device · ~10–20 s on this Mac").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", role: .cancel, action: onCancel)
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Cancel summarization")
                }
            } else {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}
