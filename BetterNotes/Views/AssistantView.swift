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
    @State private var isNewConversation = false
    @State private var composer = ""
    @State private var lastQuestion = ""
    @State private var showingProviderSettings = false
    @State private var conversationSaveError: String?
    @State private var cancellationNotice: String?
    @State private var draftScope = AssistantScope.allNotes
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
                HStack {
                    conversationMenu
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
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
            .navigationTitle(currentThread?.title ?? AppLocalization.text("Assistant"))
            .navigationBarTitleDisplayMode(.inline)
            .onDisappear { coordinator.cancel() }
            .sheet(isPresented: $showingProviderSettings) {
                AIProviderSettingsSheet(service: aiService)
            }
            .alert("Conversation Couldn’t Be Saved", isPresented: Binding(
                get: { conversationSaveError != nil },
                set: { if !$0 { conversationSaveError = nil } }
            )) {
                Button("OK", role: .cancel) { conversationSaveError = nil }
            } message: {
                Text(conversationSaveError ?? "")
            }
        }
    }

    private var conversationMenu: some View {
        Menu {
            Button("New Conversation", systemImage: "plus.bubble") {
                coordinator.clearTransientState()
                draftScope = currentThread?.scope ?? draftScope
                selectedThreadID = nil
                isNewConversation = true
                cancellationNotice = nil
            }
            if !threads.isEmpty {
                Divider()
                ForEach(Array(threads.prefix(12))) { thread in
                    Button(thread.title) {
                        coordinator.clearTransientState()
                        selectedThreadID = thread.stableID
                        isNewConversation = false
                        draftScope = thread.scope
                        cancellationNotice = nil
                    }
                }
            }
        } label: {
            Label("Conversations", systemImage: "bubble.left.and.bubble.right")
                .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("assistant-conversations-menu")
    }

    private var scopePicker: some View {
        Picker("Note scope", selection: Binding(
            get: { currentThread?.scope ?? draftScope },
            set: { scope in
                coordinator.clearTransientState()
                draftScope = scope
                if let currentThread {
                    let previousScope = currentThread.scope
                    let previousUpdatedAt = currentThread.updatedAt
                    currentThread.scope = scope
                    currentThread.updatedAt = .now
                    if !saveConversation() {
                        currentThread.scope = previousScope
                        currentThread.updatedAt = previousUpdatedAt
                    }
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
        Button { submit(AppLocalization.text(prompt)) } label: {
            Label(AppLocalization.text(title), systemImage: icon)
        }
            .buttonStyle(.bordered)
    }

    private var starterPrompts: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppLocalization.text(aiService.isRemoteConfigured ? "Ask across your notes" : "On-device assistant"))
                .font(.headline)
            Text(AppLocalization.text(aiService.isRemoteConfigured
                 ? "Choose a starting point or write your own question."
                 : "Search and extract answers locally, or configure a provider for synthesized responses."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ForEach(starters, id: \.0) { starter in
                Button {
                    submit(AppLocalization.text(starter.1))
                } label: {
                    Label(AppLocalization.text(starter.0), systemImage: starterIcon(starter.0))
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
            if let cancellationNotice {
                Label(cancellationNotice, systemImage: "stop.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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
                    Button {
                        coordinator.clearTransientState()
                        cancellationNotice = AppLocalization.text("Response stopped. Your notes were not changed.")
                    } label: {
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

    private var currentThread: AssistantThread? {
        if isNewConversation { return nil }
        guard let selectedThreadID else { return threads.first }
        return threads.first { $0.stableID == selectedThreadID }
    }

    private var currentMessages: [AssistantMessage] {
        currentThread?.orderedMessages ?? []
    }

    private func threadForSubmission() -> AssistantThread {
        if let currentThread {
            selectedThreadID = currentThread.stableID
            return currentThread
        }
        // Lazily create a thread on first use -- there's no longer a UI
        // affordance to create one explicitly.
        let thread = AssistantThread(scope: draftScope)
        context.insert(thread)
        selectedThreadID = thread.stableID
        isNewConversation = false
        return thread
    }

    private func submit(_ rawQuestion: String) {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !coordinator.isResponding else { return }
        cancellationNotice = nil
        let isNewThread = currentThread == nil
        let thread = threadForSubmission()
        let previousTitle = thread.title
        let previousUpdatedAt = thread.updatedAt
        var history = thread.orderedMessages
            .filter { !$0.isFailure }
            .map { AIConversationMessage(role: $0.role, content: $0.content) }
        // Retry already has the prior user question in the saved thread.
        // Sending it twice wastes context and can skew retrieval.
        if history.last?.role == .user, history.last?.content == question {
            history.removeLast()
        }
        let userMessage = AssistantMessage(role: .user, content: question)
        userMessage.thread = thread
        thread.messages.append(userMessage)
        if thread.messages.count == 1 {
            thread.title = question.split(separator: " ").prefix(6).joined(separator: " ")
        }
        thread.updatedAt = .now
        context.insert(userMessage)
        guard saveConversation() else {
            thread.messages.removeAll { $0.id == userMessage.id }
            context.delete(userMessage)
            thread.title = previousTitle
            thread.updatedAt = previousUpdatedAt
            if isNewThread {
                context.delete(thread)
                selectedThreadID = nil
                isNewConversation = true
            }
            return
        }
        composer = ""
        lastQuestion = question

        coordinator.send(
            question: question,
            scope: thread.scope,
            notebookID: notebook.stableID,
            pageID: page.stableID,
            history: history,
            resolvePageImage: { pageID in
                let descriptor = FetchDescriptor<Page>(predicate: #Predicate { $0.stableID == pageID })
                guard let page = try? context.fetch(descriptor).first else { return nil }
                return PDFExport.renderPageImage(page)
            }
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
            if saveConversation() { coordinator.clearTransientState() }
        }
    }

    @discardableResult
    private func saveConversation() -> Bool {
        do {
            try context.save()
            conversationSaveError = nil
            return true
        } catch {
            conversationSaveError = error.localizedDescription
            return false
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
