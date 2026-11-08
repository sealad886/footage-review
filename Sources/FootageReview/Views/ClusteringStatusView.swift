import SwiftUI

@MainActor
struct ClusteringStatusView: View {
    let clustering: ClusteringCoordinator
    let review: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Label("Face Clustering", systemImage: "person.2.crop.square.stack")
                    .font(.callout.weight(.semibold))
                Spacer()
                if clustering.total > 0 {
                    Text("\(clustering.completed.formatted()) of \(clustering.total.formatted())")
                        .monospacedDigit()
                }
                if clustering.canPause {
                    Button("Pause") { Task { await clustering.pause() } }
                }
                if clustering.canResume {
                    Button("Resume") { Task { await clustering.resume() } }
                }
                if clustering.canCancel {
                    Button("Cancel") { Task { await clustering.cancel() } }
                }
                if clustering.hasSavedRun || clustering.workspace != nil {
                    Button("Review Suggestions", action: review)
                        .disabled(clustering.isBusy)
                }
            }
            if clustering.isBusy && clustering.total > 0 {
                ProgressView(value: Double(clustering.completed), total: Double(max(1, clustering.total)))
                    .accessibilityLabel("Clustering progress")
            }
            Text(clustering.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let message = clustering.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
