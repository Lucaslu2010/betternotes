import SwiftData
import SwiftUI

struct MacAssistantView: View {
    let notebook: Notebook?
    let page: Page?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var corpus: NoteCorpusStore
    @EnvironmentObject private var settings: AISettingsStore
    @Query(sort: \AssistantThread.updatedAt, order: .reverse) private var threads: [AssistantThread]
    @State private var selectedThreadID: UUID?
    @State private var question = ""
    @State private var scope = AssistantScope.allNotes
    @State private var coordinator: AssistantCoordinator?
    @State private var showingSettings = false
    @State private var saveError: String?

    private var thread: AssistantThread? {
        threads.first { $0.stableID == selectedThreadID }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedThreadID) {
                ForEach(threads, id: \.stableID) { thread in
                    Text(thread.title).tag(thread.stableID)
                }
            }
            .navigationTitle("Conversations")
            .toolbar { Button("New", systemImage: "plus") { selectedThreadID = nil } }
        } detail: {
            VStack(spacing: 0) {
                Picker("Scope", selection: $scope) {
                    ForEach(AssistantScope.allCases, id: \.self) { item in
                        Text(item.label).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(thread?.orderedMessages ?? []) { message in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(message.role == .user ? "You" : "Assistant").font(.caption).bold()
                                Text(message.content)
                                    .textSelection(.enabled)
                                if !message.citations.isEmpty {
                                    Text(message.citations.map(\.token).joined(separator: " "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(message.role == .user ? Color.accentColor.opacity(0.1) : Color.gray.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                        }
                        if let coordinator, !coordinator.responseDraft.isEmpty {
                            Text(coordinator.responseDraft).textSelection(.enabled)
                        }
                    }
                    .padding()
                }
                Divider()
                HStack {
                    TextField("Ask about your notes", text: $question, axis: .vertical)
                        .lineLimit(2...5)
                        .onSubmit(send)
                    Button("Send", action: send)
                        .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || coordinator?.isResponding == true)
                }
                .padding()
            }
            .navigationTitle("Assistant")
            .toolbar {
                Button("Provider Settings", systemImage: "gearshape") { showingSettings = true }
                Button("Close", systemImage: "xmark") { dismiss() }
            }
        }
        .sheet(isPresented: $showingSettings) { MacAISettingsView().frame(width: 480) }
        .alert("Conversation Couldn’t Be Saved", isPresented: Binding(
            get: { saveError != nil }, set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .onAppear {
            coordinator = AssistantCoordinator(settings: settings, client: AIClient(), indexer: corpus.indexer)
        }
        .onDisappear { coordinator?.cancel() }
        .onChange(of: selectedThreadID) { _, _ in
            if let thread { scope = thread.scope }
        }
    }

    private func send() {
        guard let coordinator else { return }
        let prompt = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        let isNewThread = thread == nil
        let target: AssistantThread
        if let thread {
            target = thread
        } else {
            target = AssistantThread(title: String(prompt.prefix(44)), scope: scope)
            context.insert(target)
            selectedThreadID = target.stableID
        }
        let previousUpdatedAt = target.updatedAt
        let history = target.orderedMessages.map { AIConversationMessage(role: $0.role, content: $0.content) }
        let userMessage = AssistantMessage(role: .user, content: prompt)
        userMessage.thread = target
        target.messages.append(userMessage)
        target.updatedAt = .now
        guard saveConversation() else {
            target.messages.removeAll { $0.id == userMessage.id }
            context.delete(userMessage)
            target.updatedAt = previousUpdatedAt
            if isNewThread {
                context.delete(target)
                selectedThreadID = nil
            }
            return
        }
        question = ""
        coordinator.send(
            question: prompt,
            scope: scope,
            notebookID: notebook?.stableID,
            pageID: page?.stableID,
            history: history,
            resolvePageImage: { id in
                guard let page, page.stableID == id else { return nil }
                return MacPageSnapshot.jpeg(page)
            },
            completion: { reply in
                let answer = AssistantMessage(role: .assistant, content: reply.text,
                                              citations: reply.citations,
                                              providerNotice: reply.notice,
                                              isFailure: reply.error != nil)
                answer.thread = target
                target.messages.append(answer)
                target.updatedAt = .now
                saveConversation()
            }
        )
    }

    @discardableResult
    private func saveConversation() -> Bool {
        do {
            try context.save()
            saveError = nil
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }
}

private struct MacAISettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AISettingsStore
    @State private var baseURL = ""
    @State private var model = ""
    @State private var apiKey = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            TextField("Provider URL", text: $baseURL)
            TextField("Model", text: $model)
            SecureField("API Key (leave blank to keep current)", text: $apiKey)
            Toggle("Send page images to provider", isOn: Binding(
                get: { settings.sendsPageImages }, set: { settings.setSendsPageImages($0) }
            ))
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            HStack {
                Button("Clear Key") { settings.clear() }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    do {
                        try settings.update(apiKey: apiKey.isEmpty ? nil : apiKey,
                                            baseURL: baseURL, model: model)
                        dismiss()
                    } catch { errorMessage = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .onAppear { baseURL = settings.baseURL; model = settings.model }
    }
}
