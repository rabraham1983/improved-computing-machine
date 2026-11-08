import SwiftUI
import CodeScopeCore

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var keyDraft = ""
    @State private var keySaved = false

    var body: some View {
        Form {
            Section {
                SecureField("Anthropic API key", text: $keyDraft, prompt: Text("sk-ant-…"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveKey)
                HStack {
                    Button("Save key", action: saveKey)
                        .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Remove key", role: .destructive) {
                        settings.apiKey = ""
                        keyDraft = ""
                        keySaved = false
                    }
                    .disabled(!settings.hasAPIKey)
                    Spacer()
                    if settings.hasAPIKey {
                        Label(keySaved ? "Saved to Keychain" : "Key configured", systemImage: "checkmark.seal")
                            .font(.caption).foregroundStyle(.green)
                    } else {
                        Label("No key", systemImage: "key").font(.caption).foregroundStyle(.orange)
                    }
                }
                Link("Create or manage API keys at console.anthropic.com", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    .font(.caption)
            } header: {
                Text("Authentication")
            } footer: {
                Text("The key is stored in your login Keychain and sent only to api.anthropic.com. The ANTHROPIC_API_KEY environment variable is used as a fallback if no key is saved.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Model") {
                Picker("Model", selection: $settings.model) {
                    ForEach(ClaudeModels.available) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                if let info = ClaudeModels.available.first(where: { $0.id == settings.model }) {
                    Text(info.note).font(.caption).foregroundStyle(.secondary)
                }
                Picker("Effort", selection: $settings.effort) {
                    ForEach(Effort.allCases) { effort in
                        Text(effort.displayName).tag(effort)
                    }
                }
                Text("Effort controls how much the model thinks before answering. High is a good default for understanding code; use Extra high or Max for difficult optimizations, Low for quick questions.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show reasoning summaries", isOn: $settings.showThinking)
                Toggle("Fall back to another Claude model if a request is declined by safety filters", isOn: $settings.enableFallbacks)
                    .disabled(!ClaudeModels.supportsFallbacks(settings.model))
            }

            Section {
                Picker("Snapshot budget", selection: $settings.tokenBudget) {
                    ForEach([100_000, 200_000, 300_000, 450_000, 600_000, 800_000], id: \.self) { budget in
                        Text("\(budget / 1000)K tokens").tag(budget)
                    }
                }
                Text("How much of the project is sent to Claude in full with every request. Files beyond the budget are sent as symbol outlines and read on demand. Larger budgets give better answers on big projects but cost more per request (cached after the first call).")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Context")
            }

            Section("Recent projects") {
                if settings.recentProjects.isEmpty {
                    Text("None yet").foregroundStyle(.secondary)
                } else {
                    ForEach(settings.recentProjects, id: \.self) { path in
                        HStack {
                            Text(path).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button {
                                settings.removeRecentProject(path)
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 620)
        .onAppear { keyDraft = settings.apiKey }
    }

    private func saveKey() {
        settings.apiKey = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        keySaved = settings.hasAPIKey
    }
}
