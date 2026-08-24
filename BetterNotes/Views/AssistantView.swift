import SwiftData
import SwiftUI

/// Renders assistant output as Markdown.
///
/// `AttributedString(markdown:)` collapses newlines unless full-document
/// parsing is requested, and assistant answers are line-oriented (bullets,
/// checklists, Q/A pairs), so each line is parsed on its own and rejoined.
enum AssistantMarkdown {
    static func render(_ text: String) -> AttributedString {
        var output = AttributedString()
        let lines = text.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() {
            if index > 0 { output.append(AttributedString("\n")) }
            output.append(renderLine(line))
        }
        return output
    }

    private static func renderLine(_ line: String) -> AttributedString {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else {
            return AttributedString(line)
        }
        // Markdown has no checkbox syntax, so map task-list markers to symbols
        // before parsing; otherwise "- [ ]" renders as a bullet plus literal
        // brackets.
        var source = line
        for (marker, replacement) in [("- [ ] ", "☐ "), ("- [x] ", "☑ "), ("- [X] ", "☑ ")] {
            if let range = source.range(of: marker), range.lowerBound == source.startIndex {
                source = replacement + source[range.upperBound...]
                break
            }
        }
        if let parsed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return parsed
        }
        return AttributedString(source)
    }
}

struct AssistantView: View {
    let notebook: Notebook
    let page: Page
    let isReadOnly: Bool
    let canReplaceSelection: Bool
    var onOpenCitation: (SourceCitation) -> Void
    var onInsert: (String) -> Void
    var onReplaceSelection: (String) -> Void
    var onCreateNote: (String) -> Void
    var onDismiss: () -> Void
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var coordinator: AssistantCoordinator
    @EnvironmentObject private var aiService: AIService
    @Query(sort: \AssistantThread.updatedAt, order: .reverse) private var threads: [AssistantThread]
    @State private var selectedThreadID: UUID?
    @State private var composer = ""
    @State private var lastQuestion = ""
    @State private var showingProviderSettings = false
    @State private var showingRename = false
    @State private var renameText = ""
    @State private var draftScope = AssistantScope.allNotes
    @State private var isStartingNewConversation = false
    @State private var confirmingClear = false
    @State private var confirmingDelete = false
    @FocusState private var composerFocused: Bool

    private let starters = [
        ("Explain a concept", "Explain the most important concept in these notes in simple terms."),
        ("Create a study guide", "Create a concise study guide from these notes."),
        ("Compare topics", "Compare the main topics in these notes and explain how they differ."),
        ("Test understanding", "Test my understanding with five questions, then provide an answer key."),
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                scopePicker
                quickActions
                Divider()
                conversation
                composerBar
            }
            // Floating close button on the chat interface itself, isolated
            // from the navigation toolbar. Positioned at the top-trailing
            // corner so it's always reachable without competing with the
            // conversation menu in the leading toolbar position.
            .overlay(alignment: .topTrailing) {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .padding(.top, 6)
                .padding(.trailing, 10)
                .accessibilityIdentifier("assistant-dismiss")
                .accessibilityLabel("Close Assistant")
            }
            .navigationTitle(currentThread?.title ?? "Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { assistantToolbar }
            .onDisappear { coordinator.cancel() }
            .sheet(isPresented: $showingProviderSettings) {
                AIProviderSettingsSheet(service: aiService)
            }
            .alert("Rename Conversation", isPresented: $showingRename) {
                TextField("Conversation name", text: $renameText)
                Button("Rename") { renameCurrentThread() }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Clear this conversation?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Clear Conversation", role: .destructive) { clearCurrentThread() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The conversation will remain, but all of its messages will be removed.")
            }
            .confirmationDialog("Delete this conversation?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete Conversation", role: .destructive) { deleteCurrentThread() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This cannot be undone.")
            }
        }
    }

    private var scopePicker: some View {
        Picker("Note scope", selection: Binding(
            get: { currentThread?.scope ?? draftScope },
            set: { scope in
                coordinator.clearTransientState()
                draftScope = scope
                if let currentThread {
                    currentThread.scope = scope
                    currentThread.updatedAt = .now
                    try? context.save()
                }
            }
        )) {
            ForEach(AssistantScope.allCases, id: \.self) { scope in
                Text(scope.label).tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .padding(12)
        .accessibilityLabel("Assistant note scope")
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if currentMessages.isEmpty && !coordinator.isResponding {
                        starterPrompts
                    }
                    ForEach(currentMessages) { message in
                        messageView(message)
                            .id(message.stableID)
                    }
                    if coordinator.isResponding || !coordinator.responseDraft.isEmpty {
                        streamingMessage
                            .id("streaming-response")
                    }
                }
                .padding(16)
            }
            .onChange(of: currentMessages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: coordinator.responseDraft) { _, _ in scrollToBottom(proxy) }
        }
    }

    private var quickActions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                quickAction("Summary", icon: "text.alignleft", prompt: "Summarize the selected notes into concise study points.")
                quickAction("Quiz", icon: "questionmark.circle", prompt: "Create five practice questions with a concise answer key from the selected notes.")
                quickAction("Action Items", icon: "checklist", prompt: "Extract decisions, deadlines, and action items from the selected notes. Do not invent tasks.")
                quickAction("Improve Writing", icon: "text.badge.checkmark", prompt: "Improve the clarity and structure of the selected notes without changing their meaning.")
                Button {
                    composerFocused = true
                } label: {
                    Label("Ask Notes", systemImage: "bubble.left")
                }
                .buttonStyle(.bordered)
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    private func quickAction(_ title: String, icon: String, prompt: String) -> some View {
        Button { submit(prompt) } label: { Label(title, systemImage: icon) }
            .buttonStyle(.bordered)
    }

    private var starterPrompts: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(aiService.isRemoteConfigured ? "Ask across your notes" : "On-device assistant")
                .font(.headline)
            Text(aiService.isRemoteConfigured
                 ? "Choose a starting point or write your own question."
                 : "Search and extract answers locally, or configure a provider for synthesized responses.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ForEach(starters, id: \.0) { starter in
                Button {
                    submit(starter.1)
                } label: {
                    Label(starter.0, systemImage: starterIcon(starter.0))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func messageView(_ message: AssistantMessage) -> some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
            // Assistant prompts ask for Markdown (checklists, bullets, bold),
            // so render it instead of showing raw "- [ ]" and "**" markup.
            Text(AssistantMarkdown.render(message.content))
                .font(.body)
                .textSelection(.enabled)
                .padding(11)
                .background(
                    message.role == .user ? Color.accentColor.opacity(0.14) : Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 8)
                )
            if let notice = message.providerNotice {
                Label(notice, systemImage: message.isFailure ? "exclamationmark.triangle" : "iphone")
                    .font(.caption)
                    .foregroundStyle(message.isFailure ? .orange : .secondary)
            }
            if message.role == .assistant {
                citationsView(message.citations)
                responseActions(message.content)
            } else {
                Button {
                    composer = message.content
                    composerFocused = true
                } label: {
                    Label("Edit and resend", systemImage: "pencil")
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    private var streamingMessage: some View {
        VStack(alignment: .leading, spacing: 8) {
            if coordinator.responseDraft.isEmpty {
                HStack(spacing: 9) {
                    ProgressView()
                    Text("Searching your notes...")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(coordinator.responseDraft)
                    .textSelection(.enabled)
            }
            if let notice = coordinator.notice {
                Label(notice, systemImage: "iphone")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private func citationsView(_ citations: [SourceCitation]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(citations) { citation in
                Button {
                    onOpenCitation(citation)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text.magnifyingglass")
                        Text("[\(citation.token)] \(citation.sourceLabel)")
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                    }
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityHint(citation.excerpt)
            }
        }
    }

    private func responseActions(_ text: String) -> some View {
        HStack(spacing: 14) {
            Button { UIPasteboard.general.string = text } label: {
                Image(systemName: "doc.on.doc")
            }
            .accessibilityLabel("Copy response")
            Menu {
                Button("Insert on Current Page", systemImage: "plus.square") { onInsert(text) }
                    .disabled(isReadOnly)
                Button("Replace Selected Text", systemImage: "arrow.triangle.2.circlepath") { onReplaceSelection(text) }
                    .disabled(isReadOnly || !canReplaceSelection)
                Button("Create New Note", systemImage: "doc.badge.plus") { onCreateNote(text) }
                    .disabled(isReadOnly)
                if isReadOnly {
                    Text("Enable editing to use a response in your notebook.")
                } else if !canReplaceSelection {
                    Text("Select a text box or sticky note to replace its text.")
                }
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .accessibilityLabel("Use response")
        }
        .font(.caption)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private var composerBar: some View {
        VStack(spacing: 8) {
            if let error = coordinator.errorMessage, !coordinator.isResponding {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                    Spacer()
                    Button("Retry") { submit(lastQuestion) }
                        .font(.caption.weight(.semibold))
                    Button("Setup") { showingProviderSettings = true }
                        .font(.caption.weight(.semibold))
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask your notes", text: $composer, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.roundedBorder)
                    .focused($composerFocused)
                    .submitLabel(.send)
                    .onSubmit { submit(composer) }
                if coordinator.isResponding {
                    Button { coordinator.cancel() } label: {
                        Image(systemName: "stop.fill")
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Stop response")
                } else {
                    Button { submit(composer) } label: {
                        Image(systemName: "arrow.up")
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send message")
                }
            }
        }
        .padding(12)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var assistantToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Button("New Conversation", systemImage: "square.and.pencil") { startNewConversation() }
                Button("Rename Conversation", systemImage: "pencil") {
                    renameText = currentThread?.title ?? ""
                    showingRename = true
                }
                .disabled(currentThread == nil)
                Button("Clear Conversation", systemImage: "eraser") { confirmingClear = true }
                    .disabled(currentMessages.isEmpty)
                Button("Delete Conversation", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                    .disabled(currentThread == nil)
                if currentThread == nil {
                    Text("Send a message to create a conversation.")
                } else if currentMessages.isEmpty {
                    Text("There are no messages to clear.")
                }
                Divider()
                ForEach(threads) { thread in
                    Button {
                        coordinator.clearTransientState()
                        selectedThreadID = thread.stableID
                        isStartingNewConversation = false
                        draftScope = thread.scope
                    } label: {
                        Label(thread.title, systemImage: selectedThreadID == thread.stableID ? "checkmark" : "bubble.left")
                    }
                }
            } label: {
                Image(systemName: "bubble.left.and.bubble.right")
            }
            .accessibilityLabel("Conversations")
        }
    }

    private var currentThread: AssistantThread? {
        guard !isStartingNewConversation else { return nil }
        guard let selectedThreadID else { return threads.first }
        return threads.first { $0.stableID == selectedThreadID }
    }

    private var currentMessages: [AssistantMessage] {
        currentThread?.orderedMessages ?? []
    }

    private func startNewConversation() {
        coordinator.clearTransientState()
        // Eagerly create the thread so it appears in the conversation
        // switcher immediately, giving visible feedback that "New
        // Conversation" worked. Previously the thread was only created
        // lazily on first message send, making the button appear broken.
        let thread = AssistantThread(scope: draftScope)
        context.insert(thread)
        try? context.save()
        selectedThreadID = thread.stableID
        isStartingNewConversation = false
        draftScope = .allNotes
        composer = ""
        composerFocused = true
    }

    private func threadForSubmission() -> AssistantThread {
        if let currentThread {
            selectedThreadID = currentThread.stableID
            return currentThread
        }
        // Fallback: create thread if somehow none exists (shouldn't happen
        // after the eager-creation fix above, but keeps the safety net).
        let thread = AssistantThread(scope: draftScope)
        context.insert(thread)
        try? context.save()
        selectedThreadID = thread.stableID
        isStartingNewConversation = false
        return thread
    }

    private func clearCurrentThread() {
        guard let thread = currentThread else { return }
        coordinator.clearTransientState()
        for message in thread.messages { context.delete(message) }
        thread.messages = []
        thread.updatedAt = .now
        try? context.save()
    }

    private func deleteCurrentThread() {
        guard let thread = currentThread else { return }
        coordinator.clearTransientState()
        context.delete(thread)
        try? context.save()
        selectedThreadID = threads.first(where: { $0.stableID != thread.stableID })?.stableID
        isStartingNewConversation = selectedThreadID == nil
    }

    private func renameCurrentThread() {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let thread = currentThread, !name.isEmpty else { return }
        thread.title = name
        thread.updatedAt = .now
        try? context.save()
    }

    private func submit(_ rawQuestion: String) {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !coordinator.isResponding else { return }
        let thread = threadForSubmission()
        let history = thread.orderedMessages.map { AIConversationMessage(role: $0.role, content: $0.content) }
        let userMessage = AssistantMessage(role: .user, content: question)
        userMessage.thread = thread
        thread.messages.append(userMessage)
        if thread.messages.count == 1 {
            thread.title = question.split(separator: " ").prefix(6).joined(separator: " ")
        }
        thread.updatedAt = .now
        context.insert(userMessage)
        try? context.save()
        composer = ""
        lastQuestion = question

        coordinator.send(
            question: question,
            scope: thread.scope,
            notebookID: notebook.stableID,
            pageID: page.stableID,
            history: history
        ) { reply in
            guard thread.modelContext != nil else { return }
            let message = AssistantMessage(
                role: .assistant,
                content: reply.text,
                citations: reply.citations,
                providerNotice: reply.notice ?? reply.error,
                isFailure: reply.error != nil
            )
            message.thread = thread
            thread.messages.append(message)
            thread.updatedAt = .now
            context.insert(message)
            try? context.save()
            coordinator.clearTransientState()
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.18)) {
            if coordinator.isResponding || !coordinator.responseDraft.isEmpty {
                proxy.scrollTo("streaming-response", anchor: .bottom)
            } else if let last = currentMessages.last {
                proxy.scrollTo(last.stableID, anchor: .bottom)
            }
        }
    }

    private func starterIcon(_ title: String) -> String {
        switch title {
        case "Explain a concept": return "lightbulb"
        case "Create a study guide": return "list.bullet.rectangle"
        case "Compare topics": return "arrow.left.arrow.right"
        default: return "checkmark.bubble"
        }
    }
}
