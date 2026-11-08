import AppKit
import SwiftUI

@MainActor
struct IntegrationSettingsView: View {
    let store: ReviewStore
    @Bindable var settings: ReviewSettings
    let clustering: ClusteringCoordinator
    @State private var copiedField: CopyField?

    private enum CopyField: Equatable { case endpoint, token }
    private var isStarting: Bool { store.apiToken != nil && !store.apiRunning }

    var body: some View {
        Form {
            Section("Local Review API") {
                LabeledContent("Status") {
                    Label(
                        store.apiRunning ? "Running on this Mac" : isStarting ? "Starting…" : "Stopped",
                        systemImage: store.apiRunning ? "checkmark.circle.fill" : "circle"
                    )
                    .foregroundStyle(store.apiRunning ? Color.green : Color.secondary)
                }
                TextField("Port", value: $settings.apiPort, format: .number.grouping(.never))
                    .monospacedDigit()
                    .disabled(store.apiRunning || isStarting)
                if settings.apiPortValue == nil {
                    Text("Enter a port from 1024 to 65535.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                TextField("Browser origin", text: $settings.apiBrowserOrigin, prompt: Text("Optional"))
                    .autocorrectionDisabled()
                    .disabled(store.apiRunning || isStarting)
                if let issue = settings.originValidationMessage {
                    Text(issue).font(.caption).foregroundStyle(.red)
                }
                Text("Leave the browser origin blank for built-in clustering. An external browser client needs its exact origin, including scheme, host and port.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    if store.apiRunning || isStarting {
                        Button("Stop API", systemImage: "stop.circle") {
                            store.stopAPI()
                            copiedField = nil
                        }
                        .disabled(clustering.isBusy || clustering.canResume)
                    } else {
                        Button("Start API", systemImage: "play.circle") {
                            guard let port = settings.apiPortValue else { return }
                            copiedField = nil
                            store.startAPI(port: port, allowedOrigin: settings.apiOriginValue)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(settings.apiPortValue == nil || settings.originValidationMessage != nil
                                  || isStarting || store.isLoadingLibrary || store.isImporting)
                    }
                    if isStarting { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if clustering.isBusy || clustering.canResume {
                    Text("Finish or cancel clustering before stopping its review API connection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let endpoint = store.apiEndpoint, store.apiRunning {
                Section("External Client Connection") {
                    HStack(alignment: .firstTextBaseline) {
                        Text(endpoint)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button(copiedField == .endpoint ? "Copied" : "Copy Endpoint", systemImage: "doc.on.doc") {
                            copy(endpoint, field: .endpoint)
                        }
                    }
                    HStack {
                        SecureField("Access token", text: .constant(store.apiToken ?? ""))
                            .textFieldStyle(.roundedBorder)
                            .privacySensitive()
                            .accessibilityLabel("API access token")
                            .disabled(true)
                        Button(copiedField == .token ? "Copied" : "Copy Token", systemImage: "key") {
                            if let token = store.apiToken { copy(token, field: .token) }
                        }
                        .disabled(store.apiToken == nil)
                    }
                    Text("Tokens stay in memory and change when the API restarts. Built-in clustering connects automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let message = store.apiMessage, !message.isEmpty {
                Section("API Message") {
                    Text(message).font(.callout).textSelection(.enabled)
                }
            }
            Section("Reviewed Groups") {
                if let summary = store.apiLastImport, !summary.isEmpty {
                    Label(summary, systemImage: "arrow.down.doc")
                        .font(.callout)
                        .textSelection(.enabled)
                } else {
                    Text("Groups you explicitly import appear in the Groups sidebar and are saved in this library.")
                        .foregroundStyle(.secondary)
                }
                Text("The API listens only on this Mac while Footage Review is running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func copy(_ value: String, field: CopyField) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setString(value, forType: .string) { copiedField = field }
    }
}
