import SwiftUI
import UIKit

/// Disables the interactive (swipe-to-go-back) pop gesture on a NavigationStack,
/// so swiping right only navigates pages within the notebook (not back to library).
struct DisableInteractivePop: UIViewControllerRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = Controller(coordinator: context.coordinator)
        vc.disableInteractivePop()
        return vc
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        guard let controller = uiViewController as? Controller else { return }
        controller.coordinator = context.coordinator
        controller.disableInteractivePop()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func install(in root: UIViewController?) {
            guard let root else { return }
            for navigationController in root.findNavigationControllers() {
                install(on: navigationController)
            }
        }

        private func install(on navigationController: UINavigationController) {
            guard let popGesture = navigationController.interactivePopGestureRecognizer else { return }
            popGesture.isEnabled = false
            popGesture.delegate = self
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            false
        }
    }

    final class Controller: UIViewController {
        weak var coordinator: Coordinator?

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(nibName: nil, bundle: nil)
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            disableInteractivePop()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            disableInteractivePop()
        }

        override func viewWillLayoutSubviews() {
            super.viewWillLayoutSubviews()
            disableInteractivePop()
        }

        func disableInteractivePop() {
            DispatchQueue.main.async { [weak self] in
                self?.disableInteractivePopNow()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.disableInteractivePopNow()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.disableInteractivePopNow()
            }
        }

        private func disableInteractivePopNow() {
            coordinator?.install(in: self)
            coordinator?.install(in: parent)
            coordinator?.install(in: navigationController)
            coordinator?.install(in: view.window?.rootViewController)
        }
    }
}

private extension UIViewController {
    func findNavigationControllers() -> [UINavigationController] {
        var result: [UINavigationController] = []
        if let navigationController = self as? UINavigationController {
            result.append(navigationController)
        }
        if let navigationController {
            result.append(navigationController)
        }
        for child in children {
            result.append(contentsOf: child.findNavigationControllers())
        }
        if let presentedViewController {
            result.append(contentsOf: presentedViewController.findNavigationControllers())
        }
        return result
    }
}
