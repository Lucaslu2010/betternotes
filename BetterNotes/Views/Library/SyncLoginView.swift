import SwiftUI

/// Login form for the cloud sync feature. Posts credentials to the smart-edu
/// auth bridge and stores the resulting bearer token in the Keychain via
/// `SyncAuth`. On success the sheet dismisses and the caller triggers a pull.
struct SyncLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var auth: SyncAuth

    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Sign in with your smart-edu account to sync notebooks between this iPad and the web.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Account") {
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.subheadline)
                    }
                }

                Section {
                    Button {
                        Task { await login() }
                    } label: {
                        HStack {
                            if isLoading { ProgressView().tint(.white) }
                            Text(isLoading ? "Signing in…" : "Sign In").bold()
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(isLoading || email.isEmpty || password.isEmpty)

                    Text("Server: \(SyncConfig.baseURL)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    if SyncConfig.requiresATSException(SyncConfig.baseURL) {
                        #if DEBUG
                        Label(
                            "Plain http:// on the local network. This Debug build allows it; a Release build will block it.",
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        #else
                        Label(
                            "This is a plain http:// address on your local network. Release builds block it — use an https:// server.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        #endif
                    }
                }
            }
            .navigationTitle("Cloud Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    @MainActor
    private func login() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            try await auth.login(email: email, password: password)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Account / sync status sheet shown when already logged in. Displays the
/// account info, last sync time, and a Sync Now + Logout button.
struct SyncAccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var auth: SyncAuth
    @ObservedObject var engine: SyncEngine
    /// Called when the user taps "Sync Now". The parent owns the notebooks
    /// array and SwiftData context, so it performs the actual sync.
    var onSyncNow: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Email", value: auth.email ?? "—")
                    if let name = auth.userName { LabeledContent("Name", value: name) }
                }

                Section("Sync") {
                    if let last = engine.lastSyncDate {
                        LabeledContent("Last sync", value: last.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        Text("Not synced yet").foregroundStyle(.secondary)
                    }
                    if let err = engine.lastError {
                        Text(err).foregroundStyle(.red).font(.subheadline)
                    }
                    if engine.conflictCount > 0 {
                        LabeledContent("Conflicts preserved", value: "\(engine.conflictCount)")
                    }
                    Button {
                        onSyncNow()
                    } label: {
                        HStack {
                            if engine.isSyncing { ProgressView().tint(.accentColor) }
                            Label(engine.isSyncing ? "Syncing…" : "Sync Now", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(engine.isSyncing)
                }

                Section {
                    Button("Log Out", role: .destructive) {
                        auth.logout()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Cloud Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
