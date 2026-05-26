import AgentCore
import SwiftUI

/// Modal that edits the API backend's connection params. Loads the secret
/// from Keychain on appear; commits URL+model to UserDefaults and the secret
/// to Keychain on Save. Cancel reverts the in-flight edits.
struct APIConfigSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var baseURL: String = ""
    @State private var model: String = ""
    @State private var apiKey: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("API Endpoint").font(.headline)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 10) {
                field(label: "Base URL", placeholder: "https://api.openai.com/v1") {
                    TextField("", text: $baseURL, prompt: Text("https://api.openai.com/v1"))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
                field(label: "Model", placeholder: "gpt-4o-mini") {
                    TextField("", text: $model, prompt: Text("gpt-4o-mini"))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
                field(label: "API Key", placeholder: "sk-…") {
                    SecureField("", text: $apiKey, prompt: Text("sk-…"))
                        .textFieldStyle(.roundedBorder)
                }
            }

            Text("Any OpenAI-compatible endpoint works — OpenAI, OpenRouter, Together, Groq, vLLM, LM Studio, Ollama, etc. The key is stored in your macOS Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(baseURL.trimmingCharacters(in: .whitespaces).isEmpty
                              || model.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { load() }
    }

    @ViewBuilder
    private func field<V: View>(label: String, placeholder: String, @ViewBuilder content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func load() {
        let cfg = app.engine.apiConfig
        baseURL = cfg.baseURL
        model = cfg.model
        apiKey = Keychain.load(cfg.baseURL) ?? ""
    }

    private func save() {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespaces)
        let trimmedModel = model.trimmingCharacters(in: .whitespaces)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespaces)

        // Persist URL + model to UserDefaults; key to Keychain.
        UserDefaults.standard.set(trimmedURL, forKey: AppState.apiBaseURLKey)
        UserDefaults.standard.set(trimmedModel, forKey: AppState.apiModelKey)
        Keychain.save(trimmedKey, for: trimmedURL)

        // Push to engine — didSet recomputes state.
        app.engine.apiConfig = APIConfig(
            baseURL: trimmedURL,
            model: trimmedModel,
            apiKey: trimmedKey
        )
        dismiss()
    }
}
