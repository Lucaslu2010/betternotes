import SwiftUI
import UIKit

/// Remember the tool to return to when the configured alternate is active.
struct PencilToolToggle {
    private var returnTool: DrawingTool?

    mutating func nextTool(current: DrawingTool, alternate: DrawingTool) -> DrawingTool {
        if current != alternate {
            returnTool = current
            return alternate
        }
        if let returnTool, returnTool != alternate { return returnTool }
        return alternate == .pen ? .eraser : .pen
    }
}

/// One interaction per notebook, so a vertical notebook never handles a single
/// double tap once per visible page. Tool changes use the same binding as UI.
struct PencilDoubleTapInteraction: UIViewRepresentable {
    let isEnabled: Bool
    let onDoubleTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onDoubleTap: onDoubleTap) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        let interaction = UIPencilInteraction()
        interaction.delegate = context.coordinator
        interaction.isEnabled = isEnabled
        view.addInteraction(interaction)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onDoubleTap = onDoubleTap
        for case let interaction as UIPencilInteraction in view.interactions {
            interaction.isEnabled = isEnabled
        }
    }

    final class Coordinator: NSObject, UIPencilInteractionDelegate {
        var onDoubleTap: () -> Void

        init(onDoubleTap: @escaping () -> Void) { self.onDoubleTap = onDoubleTap }

        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            handleTap(interaction)
        }

        @available(iOS 17.5, *)
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
            handleTap(interaction)
        }

        private func handleTap(_ interaction: UIPencilInteraction) {
            // Honor system-wide disabling, including Accessibility settings.
            guard interaction.isEnabled, UIPencilInteraction.preferredTapAction != .ignore,
                  let window = interaction.view?.window, window.isKeyWindow,
                  window.windowScene?.activationState == .foregroundActive,
                  window.rootViewController?.presentedViewController == nil else { return }
            onDoubleTap()
        }
    }
}
