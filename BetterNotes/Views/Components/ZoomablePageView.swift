import SwiftUI
import UIKit
import PencilKit

enum PageZoomAction: Equatable {
    case fitPage
    case fitWidth
    case actualSize
    case zoomIn
    case zoomOut
}

struct PageZoomCommand: Equatable, Identifiable {
    let id = UUID()
    let action: PageZoomAction

    static var fitPage: PageZoomCommand { PageZoomCommand(action: .fitPage) }
    static var fitWidth: PageZoomCommand { PageZoomCommand(action: .fitWidth) }
    static var actualSize: PageZoomCommand { PageZoomCommand(action: .actualSize) }
    static var zoomIn: PageZoomCommand { PageZoomCommand(action: .zoomIn) }
    static var zoomOut: PageZoomCommand { PageZoomCommand(action: .zoomOut) }
}

enum PageSwipeDirection {
    case previous
    case next
}

struct ZoomablePageView<Content: View>: UIViewRepresentable {
    let pageSize: CGSize
    let panRequiresTwoFingers: Bool
    let onPageSwipe: (PageSwipeDirection) -> Void
    @Binding var zoomCommand: PageZoomCommand?
    @Binding var zoomScale: CGFloat
    @Binding var zoomRatio: CGFloat
    @Binding var visiblePageCenter: CGPoint
    let canShowBlankCanvasMenu: (CGPoint) -> Bool
    let onBlankCanvasMenuWillShow: () -> Void
    let onBlankCanvasPaste: () -> Void
    let content: Content

    init(
        pageSize: CGSize,
        panRequiresTwoFingers: Bool,
        onPageSwipe: @escaping (PageSwipeDirection) -> Void = { _ in },
        zoomCommand: Binding<PageZoomCommand?> = .constant(nil),
        zoomScale: Binding<CGFloat> = .constant(1),
        zoomRatio: Binding<CGFloat> = .constant(1),
        visiblePageCenter: Binding<CGPoint> = .constant(.zero),
        canShowBlankCanvasMenu: @escaping (CGPoint) -> Bool = { _ in false },
        onBlankCanvasMenuWillShow: @escaping () -> Void = {},
        onBlankCanvasPaste: @escaping () -> Void = {},
        @ViewBuilder content: () -> Content
    ) {
        self.pageSize = pageSize
        self.panRequiresTwoFingers = panRequiresTwoFingers
        self.onPageSwipe = onPageSwipe
        self._zoomCommand = zoomCommand
        self._zoomScale = zoomScale
        self._zoomRatio = zoomRatio
        self._visiblePageCenter = visiblePageCenter
        self.canShowBlankCanvasMenu = canShowBlankCanvasMenu
        self.onBlankCanvasMenuWillShow = onBlankCanvasMenuWillShow
        self.onBlankCanvasPaste = onBlankCanvasPaste
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            content: content,
            pageSize: pageSize,
            onPageSwipe: onPageSwipe,
            canShowBlankCanvasMenu: canShowBlankCanvasMenu,
            onBlankCanvasMenuWillShow: onBlankCanvasMenuWillShow,
            onBlankCanvasPaste: onBlankCanvasPaste
        )
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.accessibilityIdentifier = "page-canvas"
        scrollView.delegate = context.coordinator
        scrollView.backgroundColor = UIColor.systemGroupedBackground
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        // Delays on touches so the PKCanvasView can start drawing before the
        // scroll view claims the gesture for panning.
        scrollView.delaysContentTouches = true
        scrollView.canCancelContentTouches = true
        scrollView.contentInsetAdjustmentBehavior = .never

        let contentView = context.coordinator.contentView
        contentView.backgroundColor = .clear
        contentView.clipsToBounds = false
        contentView.frame = CGRect(origin: .zero, size: pageSize)
        scrollView.addSubview(contentView)

        let hostedView = context.coordinator.hostingController.view!
        hostedView.backgroundColor = .clear
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hostedView.clipsToBounds = false
        contentView.addSubview(hostedView)

        context.coordinator.installPageSwipeGesture(on: scrollView)
        context.coordinator.installBlankCanvasMenu()

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.hostingController.rootView = content
        context.coordinator.onPageSwipe = onPageSwipe
        context.coordinator.canShowBlankCanvasMenu = canShowBlankCanvasMenu
        context.coordinator.onBlankCanvasMenuWillShow = onBlankCanvasMenuWillShow
        context.coordinator.onBlankCanvasPaste = onBlankCanvasPaste
        context.coordinator.update(
            scrollView,
            pageSize: pageSize,
            panRequiresTwoFingers: panRequiresTwoFingers,
            zoomRatio: zoomRatio,
            zoomCommand: zoomCommand,
            setZoomCommand: { zoomCommand = $0 },
            setZoomScale: { zoomScale = $0 },
            setZoomRatio: { zoomRatio = $0 },
            setVisiblePageCenter: { visiblePageCenter = $0 }
        )
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate, UIContextMenuInteractionDelegate {
        let hostingController: UIHostingController<Content>
        let contentView = UIView()
        var onPageSwipe: (PageSwipeDirection) -> Void
        var canShowBlankCanvasMenu: (CGPoint) -> Bool
        var onBlankCanvasMenuWillShow: () -> Void
        var onBlankCanvasPaste: () -> Void
        private var lastPageSize: CGSize
        private var didSetInitialZoom = false
        private var lastZoomCommandID: UUID?
        private var setZoomScale: ((CGFloat) -> Void)?
        private var setZoomRatio: ((CGFloat) -> Void)?
        private var setVisiblePageCenter: ((CGPoint) -> Void)?
        private weak var pageSwipeGesture: UIPanGestureRecognizer?
        private var lastRenderingScale: CGFloat = 0

        init(
            content: Content,
            pageSize: CGSize,
            onPageSwipe: @escaping (PageSwipeDirection) -> Void,
            canShowBlankCanvasMenu: @escaping (CGPoint) -> Bool,
            onBlankCanvasMenuWillShow: @escaping () -> Void,
            onBlankCanvasPaste: @escaping () -> Void
        ) {
            self.hostingController = UIHostingController(rootView: content)
            self.onPageSwipe = onPageSwipe
            self.canShowBlankCanvasMenu = canShowBlankCanvasMenu
            self.onBlankCanvasMenuWillShow = onBlankCanvasMenuWillShow
            self.onBlankCanvasPaste = onBlankCanvasPaste
            self.lastPageSize = pageSize
        }

        func installBlankCanvasMenu() {
            guard contentView.interactions.contains(where: { $0 is UIContextMenuInteraction }) == false else { return }
            contentView.addInteraction(UIContextMenuInteraction(delegate: self))
        }

        func installPageSwipeGesture(on scrollView: UIScrollView) {
            guard pageSwipeGesture == nil else { return }

            let gesture = UIPanGestureRecognizer(target: self, action: #selector(handlePageSwipePan(_:)))
            gesture.minimumNumberOfTouches = 1
            gesture.maximumNumberOfTouches = 1
            gesture.cancelsTouchesInView = false
            gesture.delaysTouchesBegan = false
            gesture.delaysTouchesEnded = false
            gesture.delegate = self
            scrollView.addGestureRecognizer(gesture)
            pageSwipeGesture = gesture
        }

        func update(
            _ scrollView: UIScrollView,
            pageSize: CGSize,
            panRequiresTwoFingers: Bool,
            zoomRatio: CGFloat,
            zoomCommand: PageZoomCommand?,
            setZoomCommand: @escaping (PageZoomCommand?) -> Void,
            setZoomScale: @escaping (CGFloat) -> Void,
            setZoomRatio: @escaping (CGFloat) -> Void,
            setVisiblePageCenter: @escaping (CGPoint) -> Void
        ) {
            self.setZoomScale = setZoomScale
            self.setZoomRatio = setZoomRatio
            self.setVisiblePageCenter = setVisiblePageCenter

            if lastPageSize != pageSize {
                didSetInitialZoom = false
                lastPageSize = pageSize
                contentView.transform = .identity
                contentView.frame = CGRect(origin: .zero, size: pageSize)
                hostingController.view.frame = contentView.bounds
            } else if contentView.bounds.size != pageSize {
                contentView.bounds = CGRect(origin: .zero, size: pageSize)
                hostingController.view.frame = contentView.bounds
            }

            scrollView.contentSize = pageSize
            scrollView.maximumZoomScale = 4.0
            scrollView.panGestureRecognizer.minimumNumberOfTouches = panRequiresTwoFingers ? 2 : 1
            pageSwipeGesture?.isEnabled = !panRequiresTwoFingers

            DispatchQueue.main.async { [weak self, weak scrollView] in
                guard let self, let scrollView else { return }
                self.configureZoomScale(scrollView, pageSize: pageSize, zoomRatio: zoomRatio)
                if let zoomCommand, self.lastZoomCommandID != zoomCommand.id {
                    self.lastZoomCommandID = zoomCommand.id
                    self.apply(zoomCommand.action, to: scrollView, pageSize: pageSize)
                    setZoomCommand(nil)
                }
                self.centerPage(in: scrollView, pageSize: pageSize)
                self.refreshRenderingScale(for: scrollView)
                self.reportZoom(scrollView, pageSize: pageSize)
                self.reportVisiblePageCenter(scrollView, pageSize: pageSize)
            }
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            contentView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerPage(in: scrollView, pageSize: lastPageSize)
            refreshRenderingScale(for: scrollView)
            reportZoom(scrollView, pageSize: lastPageSize)
            reportVisiblePageCenter(scrollView, pageSize: lastPageSize)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            reportVisiblePageCenter(scrollView, pageSize: lastPageSize)
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            lastRenderingScale = 0
            refreshRenderingScale(for: scrollView)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === pageSwipeGesture,
                  let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = pan.view
            else {
                return true
            }

            let translation = pan.translation(in: view)
            let velocity = pan.velocity(in: view)
            let horizontalDrag = abs(translation.x) > 10 && abs(translation.x) > abs(translation.y)
            let horizontalFlick = abs(velocity.x) > 150 && abs(velocity.x) > abs(velocity.y)
            return horizontalDrag || horizontalFlick
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard let pageSwipeGesture,
                  let scrollView = pageSwipeGesture.view as? UIScrollView else {
                return false
            }
            let scrollPan = scrollView.panGestureRecognizer
            return (gestureRecognizer === pageSwipeGesture && otherGestureRecognizer === scrollPan)
                || (otherGestureRecognizer === pageSwipeGesture && gestureRecognizer === scrollPan)
        }

        @objc private func handlePageSwipePan(_ gesture: UIPanGestureRecognizer) {
            guard gesture.state == .ended, let view = gesture.view else { return }

            let translation = gesture.translation(in: view)
            let velocity = gesture.velocity(in: view)
            let horizontalDistance = abs(translation.x)
            let verticalDistance = abs(translation.y)
            let isLongHorizontalSwipe = horizontalDistance > 50 && horizontalDistance > verticalDistance * 1.2
            let isFastHorizontalSwipe = abs(velocity.x) > 500 && abs(velocity.x) > abs(velocity.y) * 1.1
            guard isLongHorizontalSwipe || isFastHorizontalSwipe else { return }

            let directionValue = isLongHorizontalSwipe ? translation.x : velocity.x
            onPageSwipe(directionValue < 0 ? .next : .previous)
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            guard canShowBlankCanvasMenu(location) else { return nil }
            onBlankCanvasMenuWillShow()
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                UIMenu(children: [
                    UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { _ in
                        self?.onBlankCanvasPaste()
                    }
                ])
            }
        }

        private func configureZoomScale(_ scrollView: UIScrollView, pageSize: CGSize, zoomRatio: CGFloat) {
            guard scrollView.bounds.width > 0, scrollView.bounds.height > 0 else { return }

            let scales = calculatedScales(for: scrollView, pageSize: pageSize)

            scrollView.minimumZoomScale = scales.minimum
            scrollView.maximumZoomScale = scales.maximum

            if !didSetInitialZoom {
                let persistedRatio = zoomRatio.isFinite && zoomRatio > 0 ? zoomRatio : 1
                scrollView.zoomScale = clamped(scales.fitWidth * persistedRatio, in: scrollView)
                didSetInitialZoom = true
            } else if scrollView.zoomScale < scrollView.minimumZoomScale {
                scrollView.zoomScale = scrollView.minimumZoomScale
            } else if scrollView.zoomScale > scrollView.maximumZoomScale {
                scrollView.zoomScale = scrollView.maximumZoomScale
            }
        }

        private func apply(_ action: PageZoomAction, to scrollView: UIScrollView, pageSize: CGSize) {
            guard scrollView.bounds.width > 0, scrollView.bounds.height > 0 else { return }
            let scales = calculatedScales(for: scrollView, pageSize: pageSize)
            let target: CGFloat
            switch action {
            case .fitPage:
                target = scales.fitPage
            case .fitWidth:
                target = scales.fitWidth
            case .actualSize:
                target = 1.0
            case .zoomIn:
                target = scrollView.zoomScale * 1.25
            case .zoomOut:
                target = scrollView.zoomScale / 1.25
            }
            scrollView.setZoomScale(clamped(target, in: scrollView), animated: true)
        }

        private func calculatedScales(for scrollView: UIScrollView, pageSize: CGSize) -> (fitPage: CGFloat, fitWidth: CGFloat, minimum: CGFloat, maximum: CGFloat) {
            let horizontalPadding: CGFloat = 24
            let verticalPadding: CGFloat = 24
            let availableWidth = max(1, scrollView.bounds.width - horizontalPadding)
            let availableHeight = max(1, scrollView.bounds.height - verticalPadding)
            let widthScale = max(0.2, availableWidth / pageSize.width)
            let heightScale = max(0.2, availableHeight / pageSize.height)
            let fitPageScale = min(widthScale, heightScale)
            return (fitPage: fitPageScale, fitWidth: widthScale, minimum: fitPageScale, maximum: 4.0)
        }

        private func clamped(_ scale: CGFloat, in scrollView: UIScrollView) -> CGFloat {
            min(max(scale, scrollView.minimumZoomScale), scrollView.maximumZoomScale)
        }

        private func reportZoom(_ scrollView: UIScrollView, pageSize: CGSize) {
            setZoomScale?(scrollView.zoomScale)
            setZoomRatio?(normalizedZoomRatio(for: scrollView, pageSize: pageSize))
        }

        private func reportVisiblePageCenter(_ scrollView: UIScrollView, pageSize: CGSize) {
            guard scrollView.bounds.width > 0, scrollView.bounds.height > 0 else { return }
            let viewportCenter = CGPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY)
            let pageCenter = contentView.convert(viewportCenter, from: scrollView)
            setVisiblePageCenter?(CGPoint(
                x: min(max(pageCenter.x, 0), pageSize.width),
                y: min(max(pageCenter.y, 0), pageSize.height)
            ))
        }

        private func normalizedZoomRatio(for scrollView: UIScrollView, pageSize: CGSize) -> CGFloat {
            let fitWidth = calculatedScales(for: scrollView, pageSize: pageSize).fitWidth
            guard fitWidth > 0 else { return 1 }
            return scrollView.zoomScale / fitWidth
        }

        private func centerPage(in scrollView: UIScrollView, pageSize: CGSize) {
            let scaledWidth = pageSize.width * scrollView.zoomScale
            let scaledHeight = pageSize.height * scrollView.zoomScale
            let horizontalInset = max((scrollView.bounds.width - scaledWidth) / 2, 0)
            let verticalInset = max((scrollView.bounds.height - scaledHeight) / 2, 0)
            scrollView.contentInset = UIEdgeInsets(
                top: verticalInset,
                left: horizontalInset,
                bottom: verticalInset,
                right: horizontalInset
            )
        }

        private func refreshRenderingScale(for scrollView: UIScrollView) {
            let displayScale = scrollView.window?.screen.scale ?? (UITraitCollection.current.displayScale > 0 ? UITraitCollection.current.displayScale : 2)
            let zoomedScale = displayScale * max(scrollView.zoomScale, 1)
            let renderingScale = min(max(zoomedScale, displayScale), 8)
            guard abs(renderingScale - lastRenderingScale) >= 0.1 else { return }

            lastRenderingScale = renderingScale
            applyRenderingScale(renderingScale, to: contentView)
        }

        private func applyRenderingScale(_ scale: CGFloat, to view: UIView) {
            view.contentScaleFactor = scale
            view.layer.contentsScale = scale
            view.layer.rasterizationScale = scale
            view.layer.shouldRasterize = false

            if view is PKCanvasView {
                view.setNeedsDisplay()
            }

            for subview in view.subviews {
                applyRenderingScale(scale, to: subview)
            }
        }
    }
}
