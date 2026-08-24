import Foundation
import SwiftUI

/// Lightweight undo/redo history for a single page.
/// Snapshots both the ink drawing data and a frozen copy of all page elements,
/// so adding/removing/moving/resizing text, images, shapes, audio, and ink
/// are all undoable.
@MainActor
final class PageHistory: ObservableObject {

    @Published private(set) var revision: Int = 0

    struct Snapshot: Equatable {
        let ink: Data?
        let elements: [ElementSnapshot]
    }

    struct ElementSnapshot: Equatable {
        let id: PersistentIdentifier
        let type: String
        let posX: Double
        let posY: Double
        let width: Double
        let height: Double
        let rotation: Double
        let text: String?
        let richTextData: Data?
        let fontName: String
        let fontSize: Double
        let isBold: Bool
        let isItalic: Bool
        let isUnderline: Bool
        let textAlignment: String
        let shapeKind: String?
        let colorHex: String?
        let imageData: Data?
        let audioData: Data?
        let audioDuration: Double?
        let isRevealed: Bool
        let isLocked: Bool
        let transcript: String?

        init(from e: PageElement) {
            self.id = e.id
            self.type = e.elementType
            self.posX = e.posX
            self.posY = e.posY
            self.width = e.width
            self.height = e.height
            self.rotation = e.rotation
            self.text = e.text
            self.richTextData = e.richTextData
            self.fontName = e.fontName
            self.fontSize = e.fontSize
            self.isBold = e.isBold
            self.isItalic = e.isItalic
            self.isUnderline = e.isUnderline
            self.textAlignment = e.textAlignment
            self.shapeKind = e.shapeKind
            self.colorHex = e.colorHex
            self.imageData = e.imageData
            self.audioData = e.audioData
            self.audioDuration = e.audioDuration
            self.isRevealed = e.isRevealed
            self.isLocked = e.isLocked
            self.transcript = e.transcript
        }

        func apply(to e: PageElement) {
            e.elementType = type
            e.posX = posX
            e.posY = posY
            e.width = width
            e.height = height
            e.rotation = rotation
            e.text = text
            e.richTextData = richTextData
            e.fontName = fontName
            e.fontSize = fontSize
            e.isBold = isBold
            e.isItalic = isItalic
            e.isUnderline = isUnderline
            e.textAlignment = textAlignment
            e.shapeKind = shapeKind
            e.colorHex = colorHex
            e.imageData = imageData
            e.audioData = audioData
            e.audioDuration = audioDuration
            e.isRevealed = isRevealed
            e.isLocked = isLocked
            e.transcript = transcript
        }
    }

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var lastSnapshotTime: Date = .distantPast
    private let coalesceInterval: TimeInterval = 0.35

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Called *before* an element mutation so the previous state is recorded.
    func record(ink: Data?, elements: [PageElement], coalesce: Bool = false) {
        let now = Date()
        if coalesce && now.timeIntervalSince(lastSnapshotTime) < coalesceInterval {
            lastSnapshotTime = now
            return
        }
        lastSnapshotTime = now
        let snap = Snapshot(ink: ink, elements: elements.map { ElementSnapshot(from: $0) })
        undoStack.append(snap)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        revision &+= 1
    }

    /// Pushes a state onto the redo stack (called when undoing ink so it can be redone).
    func recordForRedo(ink: Data?, elements: [PageElement]) {
        redoStack.append(Snapshot(ink: ink, elements: elements.map { ElementSnapshot(from: $0) }))
        revision &+= 1
    }

    /// Pops the top of the redo stack for ink-level redo.
    func popRedo() -> Snapshot? {
        redoStack.popLast()
    }

    /// Clears the redo stack (called when new content invalidates redo history).
    func clearRedoStack() {
        redoStack.removeAll()
        revision &+= 1
    }

    /// Clears all history when switching to a different page.
    func clearAll() {
        undoStack.removeAll()
        redoStack.removeAll()
        lastSnapshotTime = .distantPast
        revision &+= 1
    }

    /// Restore the previous state. Returns the snapshot to apply, or nil.
    func undo(ink: Data?, elements: [PageElement]) -> Snapshot? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(Snapshot(ink: ink, elements: elements.map { ElementSnapshot(from: $0) }))
        revision &+= 1
        return previous
    }

    /// Re-apply a previously undone state. Returns the snapshot to apply, or nil.
    func redo(ink: Data?, elements: [PageElement]) -> Snapshot? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(Snapshot(ink: ink, elements: elements.map { ElementSnapshot(from: $0) }))
        revision &+= 1
        return next
    }
}

import SwiftData
