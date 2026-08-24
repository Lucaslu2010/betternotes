import SwiftUI
import AVFoundation
import UIKit

private struct ElementDraftFrame: Equatable {
    var posX: Double
    var posY: Double
    var width: Double
    var height: Double
    var rotation: Double

    init(element: PageElement) {
        self.posX = element.posX
        self.posY = element.posY
        self.width = element.width
        self.height = element.height
        self.rotation = element.rotation
    }
}

/// Floating overlay layer for text boxes, sticky notes, images, shapes, and audio.
/// Each element can be dragged and resized. Selection persists until background tap.
///
/// - `isInteractive`: when true, elements respond to drag/tap.
/// - `allowsDirectImageManipulation`: when true, images can be moved,
///   pinched, and rotated directly even outside lasso mode.
/// - `backgroundClearsSelection`: when true, tapping empty space deselects
///   (and the full-screen background captures taps). Set false for lasso mode
///   so empty-area touches pass through to the PKCanvasView beneath.
struct ElementOverlay: View {
    @Binding var elements: [PageElement]
    @Binding var selectedID: PersistentIdentifier?
    var isInteractive: Bool
    var allowsDirectImageManipulation: Bool = false
    var backgroundClearsSelection: Bool = true
    var playingAudioElementID: PersistentIdentifier?
    var audioIsPlaying = false
    var audioPlaybackProgress: Double = 0
    var onTextEdit: (PageElement) -> Void
    var onAudioToggle: (PageElement) -> Void
    var onAudioSeek: ((PageElement, Double) -> Void)?
    var onAudioTranscribe: ((PageElement) -> Void)?
    var onDelete: ((PageElement) -> Void)?
    var onDuplicate: ((PageElement) -> Void)?
    var onMutationBegan: (() -> Void)?
    var onMutationEnded: (() -> Void)?
    @State private var draftFrames: [PersistentIdentifier: ElementDraftFrame] = [:]

    var body: some View {
        ZStack {
            // NOTE: Do NOT insert a full-screen Color.clear.onTapGesture here.
            // It intercepts taps before element views, breaking tap-to-edit.
            // Deselection is handled by onToolUseChange in PageEditorView
            // (clears when drawing starts) and by tapping the page background
            // via PageBackground's tap gesture.

            ForEach(elements) { element in
                let frame = displayFrame(for: element)
                Group {
                    if allowsDirectManipulation(for: element) {
                        elementView(for: element, frame: frame)
                            .highPriorityGesture(dragGesture(for: element))
                            .simultaneousGesture(imageMagnificationGesture(for: element))
                            .simultaneousGesture(imageRotationGesture(for: element))
                            .onTapGesture {
                                // Defer to avoid "Publishing changes from within
                                // view updates" — tap gestures can fire during
                                // SwiftUI's re-render cycle.
                                DispatchQueue.main.async {
                                    selectedID = element.id
                                }
                            }
                    } else if isInteractive && !element.isLocked {
                        elementView(for: element, frame: frame)
                            .highPriorityGesture(dragGesture(for: element))
                            .onTapGesture {
                                DispatchQueue.main.async {
                                    selectedID = element.id
                                }
                            }
                    } else {
                        elementView(for: element, frame: frame)
                            .onTapGesture {
                                if isInteractive {
                                    DispatchQueue.main.async {
                                        selectedID = element.id
                                    }
                                }
                            }
                    }
                }
                .position(x: frame.posX, y: frame.posY)
                .contextMenu {
                    if isInteractive && (element.type == .textBox || element.type == .stickyNote) {
                        Button {
                            onTextEdit(element)
                        } label: {
                            Label("Edit Text", systemImage: "pencil")
                        }
                        .disabled(element.isLocked)
                    }
                    if isInteractive, let onDuplicate {
                        Button {
                            onDuplicate(element)
                        } label: {
                            Label("Duplicate", systemImage: "plus.square.on.square")
                        }
                        .disabled(element.isLocked)
                    }
                    if isInteractive, element.type == .audioRecording, let onAudioTranscribe {
                        Button {
                            onAudioTranscribe(element)
                        } label: {
                            Label(element.transcript == nil ? "Transcribe" : "Transcribe Again", systemImage: "captions.bubble")
                        }
                        .disabled(element.isLocked)
                    }
                    if isInteractive {
                        Divider()
                        Button(role: .destructive) {
                            onDelete?(element)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .disabled(element.isLocked)
                    }
                }
                .zIndex(element.type == .tape ? 999 : 0)
            }
        }
    }

    private func elementView(for element: PageElement, frame: ElementDraftFrame) -> some View {
        ElementView(
            element: element,
            displayFrame: frame,
            isSelected: selectedID.map { $0 == element.id } ?? false,
            isCurrentAudio: playingAudioElementID == element.id,
            isPlayingAudio: audioIsPlaying && playingAudioElementID == element.id,
            playbackProgress: playingAudioElementID == element.id ? audioPlaybackProgress : 0,
            onTextEdit: { onTextEdit(element) },
            onAudioToggle: { onAudioToggle(element) },
            onAudioSeek: { progress in onAudioSeek?(element, progress) },
            onTapeToggle: {
                guard isInteractive, !element.isLocked else { return }
                onMutationBegan?()
                element.isRevealed.toggle()
                onMutationEnded?()
            },
            onResizeBegan: { beginControlMutation(for: element) },
            onResize: { delta, isLeading in resize(element, by: delta, isLeading: isLeading) },
            onResizeEnded: { finishControlMutation(for: element) },
            onRotateBegan: { beginControlMutation(for: element) },
            onRotate: { deltaDeg in rotateElement(element, by: deltaDeg) },
            onRotateEnded: { finishControlMutation(for: element) }
        )
    }

    // MARK: - Gestures

    /// Drag and resize preview locally, then commit to SwiftData on gesture end.
    @State private var draggingElementID: PersistentIdentifier?
    @State private var dragBaseFrame: ElementDraftFrame?
    @State private var imageSizeOrigin: CGSize?
    @State private var imageRotationOrigin: Double?
    @State private var activeControlElementID: PersistentIdentifier?
    @State private var activeControlBaseFrame: ElementDraftFrame?

    private func allowsDirectManipulation(for element: PageElement) -> Bool {
        allowsDirectImageManipulation && element.type == .image && !element.isLocked
    }

    private func displayFrame(for element: PageElement) -> ElementDraftFrame {
        draftFrames[element.id] ?? ElementDraftFrame(element: element)
    }

    private func dragGesture(for element: PageElement) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard !element.isLocked else { return }
                guard activeControlElementID != element.id else { return }
                guard canStartDrag(at: value.startLocation, element: element) else { return }
                guard let idx = elements.firstIndex(where: { $0.id == element.id }) else { return }
                DispatchQueue.main.async { selectedID = element.id }
                if draggingElementID != element.id {
                    // Force-reset any stale drag state from a previously
                    // cancelled gesture (system interruption, etc.) that
                    // never reached onEnded.
                    if draggingElementID != nil {
                        if let staleID = draggingElementID {
                            draftFrames.removeValue(forKey: staleID)
                        }
                        draggingElementID = nil
                        dragBaseFrame = nil
                    }
                    onMutationBegan?()
                    // Capture the base frame from the COMMITTED model values,
                    // not from displayFrame (which may read a stale draft
                    // left behind by an aborted resize). Reading from the
                    // model prevents jitter where draft and model disagree.
                    dragBaseFrame = ElementDraftFrame(element: elements[idx])
                    draggingElementID = element.id
                }
                guard var frame = dragBaseFrame else { return }
                frame.posX += Double(value.translation.width)
                frame.posY += Double(value.translation.height)
                setDraftFrame(frame, for: element.id)
            }
            .onEnded { _ in
                // Unconditional cleanup — even if ids mismatch (cancelled gesture)
                commitDraftFrame(for: element.id)
                draftFrames.removeValue(forKey: element.id)
                dragBaseFrame = nil
                draggingElementID = nil
                onMutationEnded?()
            }
    }

    private func canStartDrag(at location: CGPoint, element: PageElement) -> Bool {
        if element.type == .audioRecording {
            return location.x <= 44
        }

        let controlSize: CGFloat = 36
        let isBottomHandle = location.y >= element.height - controlSize
            && (location.x <= controlSize || location.x >= element.width - controlSize)
        let isRotationHandle = element.type.isRotatable
            && location.y <= 24
            && abs(location.x - element.width / 2) <= controlSize
        return !isBottomHandle && !isRotationHandle
    }

    private func beginControlMutation(for element: PageElement) {
        // If a different element's control mutation was left active (e.g. by
        // a cancelled gesture), force-finalize it first so it doesn't lock
        // out the new interaction.
        if let activeID = activeControlElementID, activeID != element.id {
            commitDraftFrame(for: activeID)
            draftFrames.removeValue(forKey: activeID)
            activeControlElementID = nil
            activeControlBaseFrame = nil
            onMutationEnded?()
        }
        if activeControlElementID == element.id { return }
        activeControlElementID = element.id
        // Capture from the committed model, not from a stale draft.
        activeControlBaseFrame = ElementDraftFrame(element: element)
        onMutationBegan?()
    }

    private func finishControlMutation(for element: PageElement) {
        // Always clear control state — the guard caused stuck locks when
        // a gesture was cancelled and ids mismatched.
        commitDraftFrame(for: element.id)
        draftFrames.removeValue(forKey: element.id)
        activeControlElementID = nil
        activeControlBaseFrame = nil
        onMutationEnded?()
    }

    private func imageMagnificationGesture(for element: PageElement) -> some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                guard allowsDirectManipulation(for: element) else { return }
                guard let idx = elements.firstIndex(where: { $0.id == element.id }) else { return }
                DispatchQueue.main.async { selectedID = element.id }

                if imageSizeOrigin == nil {
                    onMutationBegan?()
                    imageSizeOrigin = CGSize(width: CGFloat(elements[idx].width), height: CGFloat(elements[idx].height))
                }
                let origin = imageSizeOrigin ?? CGSize(width: CGFloat(elements[idx].width), height: CGFloat(elements[idx].height))
                let clampedScale = min(max(scale, 0.2), 6)
                elements[idx].width = Double(max(40, origin.width * clampedScale))
                elements[idx].height = Double(max(40, origin.height * clampedScale))
            }
            .onEnded { _ in
                imageSizeOrigin = nil
                onMutationEnded?()
            }
    }

    private func imageRotationGesture(for element: PageElement) -> some Gesture {
        RotationGesture()
            .onChanged { angle in
                guard allowsDirectManipulation(for: element) else { return }
                guard let idx = elements.firstIndex(where: { $0.id == element.id }) else { return }
                DispatchQueue.main.async { selectedID = element.id }

                if imageRotationOrigin == nil {
                    onMutationBegan?()
                    imageRotationOrigin = elements[idx].rotation
                }
                elements[idx].rotation = (imageRotationOrigin ?? elements[idx].rotation) + angle.degrees
            }
            .onEnded { _ in
                imageRotationOrigin = nil
                onMutationEnded?()
            }
    }

    private func resize(_ element: PageElement, by delta: CGSize, isLeading: Bool) {
        guard !element.isLocked else { return }
        guard activeControlElementID == element.id else { return }
        let minW: CGFloat = element.type == .audioRecording ? 140 : 40
        let minH: CGFloat = element.type == .audioRecording ? 48 : 40
        // Use the committed base, not a stale draft.
        let base = activeControlBaseFrame ?? ElementDraftFrame(element: element)
        var frame = base

        // ResizeHandle already negates delta.width for the leading handle.
        // For the trailing handle, positive delta.width = grow rightward.
        // For the leading handle, positive delta.width (after negation) = grow leftward.
        let newWidth = Double(max(minW, CGFloat(base.width) + delta.width))
        let newHeight = Double(max(minH, CGFloat(base.height) + delta.height))
        frame.width = newWidth
        frame.height = newHeight

        // Shift center so the opposite edge stays fixed.
        // Trailing handle: center shifts right/down by half the growth.
        // Leading handle: center shifts left/up by half the growth.
        let widthGrowth = newWidth - base.width
        let heightGrowth = newHeight - base.height
        if isLeading {
            frame.posX = base.posX - widthGrowth / 2
            frame.posY = base.posY - heightGrowth / 2
        } else {
            frame.posX = base.posX + widthGrowth / 2
            frame.posY = base.posY + heightGrowth / 2
        }

        setDraftFrame(frame, for: element.id)
    }

    private func rotateElement(_ element: PageElement, by deltaDegrees: Double) {
        guard !element.isLocked else { return }
        guard activeControlElementID == element.id else { return }
        let base = activeControlBaseFrame ?? displayFrame(for: element)
        var frame = base
        frame.rotation = base.rotation + deltaDegrees
        setDraftFrame(frame, for: element.id)
    }

    private func setDraftFrame(_ frame: ElementDraftFrame, for id: PersistentIdentifier) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            draftFrames[id] = frame
        }
    }

    private func commitDraftFrame(for id: PersistentIdentifier) {
        guard let frame = draftFrames[id],
              let idx = elements.firstIndex(where: { $0.id == id }) else {
            draftFrames[id] = nil
            return
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            elements[idx].posX = frame.posX
            elements[idx].posY = frame.posY
            elements[idx].width = frame.width
            elements[idx].height = frame.height
            elements[idx].rotation = frame.rotation
            draftFrames[id] = nil
        }
    }
}

private struct ElementView: View {
    let element: PageElement
    let displayFrame: ElementDraftFrame
    let isSelected: Bool
    var isCurrentAudio: Bool = false
    var isPlayingAudio: Bool = false
    var playbackProgress: Double = 0
    var onTextEdit: () -> Void
    var onAudioToggle: () -> Void
    var onAudioSeek: ((Double) -> Void)?
    var onTapeToggle: () -> Void
    var onResizeBegan: () -> Void
    var onResize: (CGSize, Bool) -> Void
    var onResizeEnded: () -> Void
    var onRotateBegan: () -> Void
    var onRotate: ((Double) -> Void)?
    var onRotateEnded: () -> Void

    var body: some View {
        Group {
            switch element.type {
            case .textBox:       textBoxView
            case .stickyNote:    stickyView
            case .shape:         shapeView
            case .image:         imageView
            case .audioRecording: audioView
            case .tape:          tapeView
            }
        }
        .frame(width: CGFloat(displayFrame.width), height: CGFloat(displayFrame.height))
        .rotationEffect(.degrees(displayFrame.rotation))
        .overlay(selectionBorder)
        .overlay(alignment: .bottomTrailing) {
            if isSelected && element.type.isResizable && !element.isLocked {
                ResizeHandle(onBegan: onResizeBegan, onResize: onResize, onEnded: onResizeEnded).padding(2)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if isSelected && element.type.isResizable && !element.isLocked {
                ResizeHandle(isLeading: true, onBegan: onResizeBegan, onResize: onResize, onEnded: onResizeEnded).padding(2)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isSelected && element.isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.secondary))
                    .offset(x: 8, y: -8)
            }
        }
        // Rotation handle for selected elements that support free rotation.
        .overlay(alignment: .top) {
            if isSelected && element.type.isRotatable && !element.isLocked, let onRotate {
                RotationHandle(onBegan: onRotateBegan, onRotate: onRotate, onEnded: onRotateEnded)
                    .offset(y: -24)
            }
        }
    }

    private var selectionBorder: some View {
        RoundedRectangle(cornerRadius: element.type == .stickyNote ? 4 : 8)
            .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
            .allowsHitTesting(false)
    }

    // MARK: Variants

    private var textBoxView: some View {
        Group {
            if element.text?.isEmpty == false {
                RichTextElementText(attributedText: element.resolvedRichText)
            } else {
                Text("Tap to edit")
                    .font(styledFont)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: element.alignment.frameAlignment)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(Color(.tertiarySystemBackground).opacity(0.5))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if !element.isLocked {
                onTextEdit()
            }
        }
    }

    private var stickyView: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let text = element.text, !text.isEmpty {
                RichTextElementText(attributedText: element.resolvedRichText)
                    .frame(maxWidth: .infinity, alignment: element.alignment.frameAlignment)
            } else {
                Text("Note")
                    .font(styledFont)
                    .multilineTextAlignment(element.alignment.swiftUITextAlignment)
                    .frame(maxWidth: .infinity, alignment: element.alignment.frameAlignment)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Image(systemName: "note.text")
                    .font(.system(size: max(10, CGFloat(element.fontSize) * 0.7)))
                    .foregroundStyle(element.tint.opacity(0.6))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(element.tint.opacity(0.18))
        .overlay(
            RoundedRectangle(cornerRadius: 4).stroke(element.tint.opacity(0.4), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if !element.isLocked {
                onTextEdit()
            }
        }
    }

    private var styledFont: Font {
        let size = CGFloat(element.fontSize)
        let base: Font = element.fontName == "System"
            ? .system(size: size)
            : .custom(element.fontName, size: size)
        var result = base.weight(element.isBold ? .bold : .regular)
        if element.isItalic { result = result.italic() }
        return result
    }

    private var shapeView: some View {
        ZStack {
            let kind = ShapeKind(rawValue: element.shapeKind ?? "circle") ?? .circle
            Group {
                switch kind {
                case .circle:    Circle().stroke(element.tint, lineWidth: 3)
                case .rectangle: RoundedRectangle(cornerRadius: 6).stroke(element.tint, lineWidth: 3)
                case .line:
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: displayHeight / 2))
                        p.addLine(to: CGPoint(x: displayWidth, y: displayHeight / 2))
                    }.stroke(element.tint, style: StrokeStyle(lineWidth: 3))
                case .arrow:
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: displayHeight))
                        p.addLine(to: CGPoint(x: displayWidth, y: 0))
                        p.move(to: CGPoint(x: displayWidth, y: 0))
                        p.addLine(to: CGPoint(x: max(0, displayWidth - 20), y: 0))
                        p.move(to: CGPoint(x: displayWidth, y: 0))
                        p.addLine(to: CGPoint(x: displayWidth, y: min(displayHeight, 20)))
                    }.stroke(element.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                case .star:
                    Image(systemName: "star")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(element.tint)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private var imageView: some View {
        Group {
            if let data = element.imageData, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    private var displayWidth: CGFloat { CGFloat(displayFrame.width) }
    private var displayHeight: CGFloat { CGFloat(displayFrame.height) }

    private var audioView: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 32)
                .accessibilityHidden(true)

            Button(action: onAudioToggle) {
                Image(systemName: isPlayingAudio ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text("Recording")
                    .font(.caption.weight(.semibold))
                if let d = element.audioDuration {
                    Text(formatDuration(d))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let transcript = element.transcript, !transcript.isEmpty {
                    Text(transcript)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            // Scrubable progress slider — users can drag to adjust playback
            // position. Shows live progress during playback and allows seeking.
            if let d = element.audioDuration, d > 0, let onAudioSeek {
                Slider(value: Binding(
                    get: { isCurrentAudio ? playbackProgress : 0 },
                    set: { newProgress in onAudioSeek(newProgress) }
                ), in: 0...1)
                .frame(width: 70)
                .tint(.accentColor)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule().fill(Color(.tertiarySystemBackground))
        )
    }

    // MARK: Tape (cover/reveal)

    private var tapeView: some View {
        Group {
            if element.isRevealed {
                // Transparent — shows what's underneath. The eye icon
                // indicates content is visible; tap to cover again.
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.gray.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .overlay(
                        Image(systemName: "eye")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    )
            } else {
                // Opaque tape covering.
                RoundedRectangle(cornerRadius: 4)
                    .fill(
                        LinearGradient(
                            colors: [Color.gray.opacity(0.85), Color.gray.opacity(0.7)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .overlay(
                        VStack(spacing: 4) {
                            Image(systemName: "bandage.fill")
                                .font(.title3)
                            Text("Tap to reveal")
                                .font(.caption2)
                        }
                        .foregroundStyle(.white.opacity(0.7))
                    )
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTapeToggle()
        }
    }

    private func formatDuration(_ s: Double) -> String {
        let m = Int(s) / 60
        let sec = Int(s) % 60
        return String(format: "%d:%02d", m, sec)
    }
}

private struct RichTextElementText: UIViewRepresentable {
    let attributedText: NSAttributedString

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.backgroundColor = .clear
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        label.attributedText = attributedText
        return label
    }

    func updateUIView(_ uiView: UILabel, context: Context) {
        if uiView.attributedText?.isEqual(attributedText) != true {
            uiView.attributedText = attributedText
        }
    }
}

// MARK: - Resize Handle

private struct ResizeHandle: View {
    var isLeading: Bool = false
    var onBegan: () -> Void
    var onResize: (CGSize, Bool) -> Void
    var onEnded: () -> Void

    var body: some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
            .frame(width: 16, height: 16)
            .offset(x: isLeading ? -2 : 2, y: 2)
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        onBegan()
                        var delta = value.translation
                        if isLeading { delta.width = -delta.width }
                        onResize(delta, isLeading)
                    }
                    .onEnded { _ in
                        onEnded()
                    }
            )
    }
}

// MARK: - Rotation Handle

private struct RotationHandle: View {
    var onBegan: () -> Void
    var onRotate: (Double) -> Void
    var onEnded: () -> Void
    @State private var lastAngle: Double = 0

    var body: some View {
        Image(systemName: "rotate")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Circle().fill(Color.accentColor))
            .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onBegan()
                        // Use atan2 to compute the angle from the element
                        // center to the drag position, enabling natural
                        // circular rotation instead of horizontal-only.
                        let dx = value.location.x - 11 // half the handle width
                        let dy = value.location.y - 11
                        let angle = atan2(Double(dy), Double(dx)) * 180 / .pi
                        // Normalize to 0-360 range for consistent delta calc
                        let normalized = angle.truncatingRemainder(dividingBy: 360)

                        // Initialize lastAngle on first drag to prevent jump
                        if lastAngle == 0 {
                            lastAngle = normalized
                            return
                        }

                        let delta = normalized - lastAngle
                        // Handle wraparound at ±180
                        let adjustedDelta = delta > 180 ? delta - 360 : (delta < -180 ? delta + 360 : delta)
                        lastAngle = normalized
                        if abs(adjustedDelta) > 0.1 {
                            onRotate(adjustedDelta)
                        }
                    }
                    .onEnded { _ in
                        lastAngle = 0
                        onEnded()
                    }
            )
    }
}

// MARK: - Element type helpers

extension ElementType {
    var isResizable: Bool {
        switch self {
        case .image, .textBox, .stickyNote, .shape, .tape:
            return true
        case .audioRecording:
            return false
        }
    }

    var isRotatable: Bool {
        switch self {
        case .image, .shape:
            return true
        case .textBox, .stickyNote, .audioRecording, .tape:
            return false
        }
    }
}

// MARK: - Text Alignment

enum TextAlign: String, CaseIterable, Codable {
    case leading, center, trailing

    var swiftUITextAlignment: TextAlignment {
        switch self {
        case .leading:  return .leading
        case .center:   return .center
        case .trailing: return .trailing
        }
    }

    var nsTextAlignment: NSTextAlignment {
        switch self {
        case .leading:  return .left
        case .center:   return .center
        case .trailing: return .right
        }
    }

    init(nsTextAlignment: NSTextAlignment) {
        switch nsTextAlignment {
        case .center:
            self = .center
        case .right:
            self = .trailing
        default:
            self = .leading
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .leading:  return .topLeading
        case .center:   return .center
        case .trailing: return .topTrailing
        }
    }

    var label: String {
        switch self {
        case .leading:  return "Left"
        case .center:   return "Center"
        case .trailing: return "Right"
        }
    }

    var icon: String {
        switch self {
        case .leading:  return "text.alignleft"
        case .center:   return "text.aligncenter"
        case .trailing: return "text.alignright"
        }
    }
}

// MARK: - PersistentIdentifier

import SwiftData

extension PageElement {
    var id: PersistentIdentifier { persistentModelID }
}

// MARK: - Shape Picker Sheet

struct ShapePickerSheet: View {
    var onPick: (ShapeKind) -> Void
    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: 3)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(ShapeKind.allCases, id: \.self) { kind in
                        Button {
                            onPick(kind)
                            dismiss()
                        } label: {
                            VStack(spacing: 10) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 14)
                                        .fill(Color(.secondarySystemBackground))
                                    shapePreview(kind)
                                        .foregroundStyle(Color.accentColor)
                                        .padding(18)
                                }
                                .aspectRatio(1, contentMode: .fit)
                                Text(kind.label)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Insert Shape")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func shapePreview(_ kind: ShapeKind) -> some View {
        switch kind {
        case .circle:    Image(systemName: "circle")
        case .rectangle: Image(systemName: "rectangle")
        case .arrow:     Image(systemName: "arrow.up.right")
        case .line:      Image(systemName: "line.diagonal")
        case .star:      Image(systemName: "star.fill")
        }
    }
}

// MARK: - Conditional Drag Modifier (unused — kept for reference)
