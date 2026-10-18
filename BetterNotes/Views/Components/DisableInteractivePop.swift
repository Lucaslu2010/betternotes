import SwiftUI
import UIKit

/// Reserve horizontal swipes for notebook pages without changing the gesture
/// delegates of the library or any navigation stacks presented above it.
struct DisableInteractivePop: UIViewControllerRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> Controller {
        Controller(coordinator: context.coordinator)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.disableInteractivePop()
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: Coordinator) {
        coordinator.restore()
    }

    final class Coordinator {
        private weak var gesture: UIGestureRecognizer?
        private var wasEnabled = true

        func install(on navigationController: UINavigationController?) {
            guard let next = navigationController?.interactivePopGestureRecognizer else { return }
            if gesture !== next {
                restore()
                gesture = next
                wasEnabled = next.isEnabled
            }
            if next.isEnabled { next.isEnabled = false }
        }

        func restore() {
            if let gesture, gesture.isEnabled != wasEnabled { gesture.isEnabled = wasEnabled }
            gesture = nil
        }
    }

    final class Controller: UIViewController {
        let coordinator: Coordinator

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(nibName: nil, bundle: nil)
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            if parent == nil { coordinator.restore() }
            else { disableInteractivePop() }
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            disableInteractivePop()
        }

        override func viewWillLayoutSubviews() {
            super.viewWillLayoutSubviews()
            disableInteractivePop()
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            coordinator.restore()
        }

        func disableInteractivePop() {
            coordinator.install(on: navigationController)
        }
    }
}
