import SwiftUI
import UIKit

struct OCRSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: OCRSettingsStore
    @EnvironmentObject private var service: OCRService
    @State private var provider = OCRProvider.local
    @State private var format = OCRAPIFormat.paddleOCR
    @State private var endpoint = ""
    @State private var token = ""
    @State private var model = ""
    @State private var errorMessage: String?
    @State private var connectionStatus: String?
    @State private var connectionTask: Task<Void, Never>?
    @State private var isTesting = false
    @State private var hasLoadedDraft = false

    var body: some View {
        // This form uses Settings' navigation stack, including the setup guide.
        Group {
            Form {
                Section {
                    Picker("Text Recognition", selection: $provider) {
                        ForEach(OCRProvider.allCases) { provider in
                            Text(provider.label).tag(provider)
                        }
                    }
                    .accessibilityIdentifier("ocr-provider-picker")
                } header: {
                    Text("OCR Provider")
                } footer: {
                    Text("On-device OCR always detects the handwritten ?? marker. The selected provider reads the question and your notes. Your answering AI model is configured separately.")
                }

                if provider == .custom {
                    Section {
                        Label("Baidu PaddleOCR", systemImage: "text.viewfinder")
                        Text("Start with PaddleOCR-VL-1.6 for notes with text, formulas, and tables. PaddleOCR-VL-1.5 is also supported. Try your own handwriting to compare accuracy.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        NavigationLink("Set Up a Free PaddleOCR API Token") {
                            PaddleOCRSetupView()
                        }
                    } header: {
                        Text("Recommended")
                    }

                    Section {
                        Picker("API Format", selection: $format) {
                            ForEach(OCRAPIFormat.allCases) { format in
                                Text(format.label).tag(format)
                            }
                        }
                        TextField("Full API Endpoint", text: $endpoint)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .accessibilityIdentifier("ocr-endpoint")
                        if format == .visionChat {
                            TextField("Vision Model", text: $model)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        SecureField(settings.hasToken ? "Token saved — enter to replace" : "Access Token / API Key", text: $token)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("ocr-token")
                        Button(action: testConnection) {
                            if isTesting {
                                HStack { ProgressView(); Text("Testing Connection") }
                            } else {
                                Label("Test Connection", systemImage: "network")
                            }
                        }
                        .disabled(isTesting)
                    } header: {
                        Text("Custom Provider")
                    } footer: {
                        Text(format == .paddleOCR
                             ? "Paste the synchronous API_URL and TOKEN from AI Studio's API example. The endpoint selects the model. PaddleOCR document parsing and text recognition responses are supported."
                             : "Enter the full chat/completions endpoint and a model that accepts images. The API key is separate from your answering model's key.")
                    }

                    Section {
                        Label("Your token stays in Keychain", systemImage: "lock.shield")
                    } footer: {
                        Text("Question detection stays on device. Your custom provider receives note images when a ?? question is detected, when you ask the assistant or Ask Notes, or when you explicitly recognize or update handwriting search. Ordinary drawing does not upload pages. Provider quotas and terms apply.")
                    }
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
                if let connectionStatus {
                    Section { Text(connectionStatus).foregroundStyle(.secondary) }
                }
                if settings.hasToken {
                    Section {
                        Button("Remove OCR Token", role: .destructive) {
                            do {
                                try settings.removeToken()
                                token = ""
                                provider = .local
                                connectionStatus = nil
                            } catch { errorMessage = error.localizedDescription }
                        }
                    }
                }
            }
            .navigationTitle("OCR Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        do { try save(); dismiss() } catch { errorMessage = error.localizedDescription }
                    }
                    .bold()
                    .disabled(isTesting)
                }
            }
            .onAppear {
                guard !hasLoadedDraft else { return }
                hasLoadedDraft = true
                provider = settings.provider
                endpoint = settings.endpoint
                format = settings.format
                model = settings.model
            }
            .onDisappear { connectionTask?.cancel() }
        }
    }

    private func save() throws {
        try settings.save(provider: provider, endpoint: endpoint, token: token.isEmpty ? nil : token, format: format, model: model)
        token = ""
        errorMessage = nil
    }

    private func testConnection() {
        // Test draft values without changing the active provider or saved key.
        let config: OCRConfiguration
        do {
            config = try settings.testConfiguration(endpoint: endpoint, token: token.isEmpty ? nil : token, format: format, model: model)
        } catch { errorMessage = error.localizedDescription; return }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 120))
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 120))
            ("BetterNotes OCR" as NSString).draw(at: CGPoint(x: 20, y: 35), withAttributes: [.font: UIFont.systemFont(ofSize: 36), .foregroundColor: UIColor.black])
        }
        guard let data = image.pngData() else { return }
        errorMessage = nil
        connectionStatus = nil
        isTesting = true
        connectionTask = Task { @MainActor in
            defer { isTesting = false }
            do {
                let text = try await service.client.recognize(imageData: data, configuration: config)
                try Task.checkCancellation()
                connectionStatus = text.isEmpty ? "Connected, but the test image returned no text." : "Connection succeeded. Read: \(text)"
            } catch is CancellationError {
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct PaddleOCRSetupView: View {
    var body: some View {
        Form {
            Section("1. Create Your Account") {
                Text("Open Baidu AI Studio and register or sign in with a Baidu account. Complete any account verification requested by AI Studio.")
                Link("Open Baidu AI Studio", destination: URL(string: "https://aistudio.baidu.com/paddleocr")!)
            }
            Section("2. Choose a Model") {
                Text("Open the API area and choose PaddleOCR-VL-1.6 for mixed notes, formulas, and tables. If it is unavailable in your account, choose PaddleOCR-VL-1.5. PP-OCRv5 or PP-OCRv6 are alternatives for text-only notes.")
                Link("Open PaddleOCR API", destination: URL(string: "https://aistudio.baidu.com/paddleocr/task")!)
            }
            Section("3. Copy Your Endpoint and Token") {
                Text("Open the model's synchronous API call example. Copy API_URL into Full API Endpoint, then copy TOKEN into Access Token. Keep API Format set to PaddleOCR API. Use the URL and token from the same example.")
                Link("Official API Setup and Examples", destination: URL(string: "https://ai.baidu.com/ai-doc/AISTUDIO/Cmkz2m0ma")!)
                Link("AI Studio Access Tokens", destination: URL(string: "https://aistudio.baidu.com/account/accessToken")!)
            }
            Section("4. Test and Save") {
                Text("Return to OCR Settings, choose Custom OCR, paste your values, and tap Test Connection. Tap Save to use this provider for note recognition.")
            }
            Section {
                Link("Official Free Quota and Limits", destination: URL(string: "https://ai.baidu.com/ai-doc/AISTUDIO/Xmjclapam")!)
            } footer: {
                Text("AI Studio offers a free API quota. Availability, verification requirements, and limits are controlled by Baidu and may change. Check your account before using the service.")
            }
        }
        .navigationTitle("Set Up PaddleOCR")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(false)
    }
}
