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

/// A leftward drag past the last page, reported while it happens so the
/// editor can show the page being pulled. Distances are points of leftward
/// finger travel.
enum PageEdgePull {
    case changed(CGFloat)
    /// `flick` is a fast leftward release, which commits without a full pull.
    case ended(distance: CGFloat, flick: Bool)
    case cancelled
}

/// Long-press recognizer for the blank-canvas paste menu that ignores a
/// resting palm. A fingertip's touch majorRadius is typically under ~15pt;
/// a palm heel reports well above that. Without this check, a hand resting
/// on the page while writing was treated like any other long press and
/// popped the paste menu.
private final class BlankCanvasLongPressGestureRecognizer: UILongPressGestureRecognizer {
    private let maxTouchRadius: CGFloat = 20

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if touches.contains(where: { $0.majorRadius > maxTouchRadius }) {
            state = .failed
            return
        }
        super.touchesBegan(touches, with: event)
    }
}

struct ZoomablePageView<Content: View>: UIViewRepresentable {
    let pageSize: CGSize
    let panRequiresTwoFingers: Bool
    let onPageSwipe: (PageSwipeDirection) -> Void
    let canPullToAddPage: Bool
    let onPullToAddPage: (PageEdgePull) -> Void
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
        canPullToAddPage: Bool = false,
        onPullToAddPage: @escaping (PageEdgePull) -> Void = { _ in },
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
        self.canPullToAddPage = canPullToAddPage
        self.onPullToAddPage = onPullToAddPage
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
            canPullToAddPage: canPullToAddPage,
            onPullToAddPage: onPullToAddPage,
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
        context.coordinator.installBlankCanvasPasteMenu()

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.hostingController.rootView = content
        context.coordinator.onPageSwipe = onPageSwipe
        context.coordinator.canPullToAddPage = canPullToAddPage
        context.coordinator.onPullToAddPage = onPullToAddPage
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

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate, UIEditMenuInteractionDelegate {
        let hostingController: UIHostingController<Content>
        let contentView = UIView()
        var onPageSwipe: (PageSwipeDirection) -> Void
        var canPullToAddPage: Bool
        var onPullToAddPage: (PageEdgePull) -> Void
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
        private weak var blankCanvasEditMenuInteraction: UIEditMenuInteraction?

        init(
            content: Content,
            pageSize: CGSize,
            onPageSwipe: @escaping (PageSwipeDirection) -> Void,
            canPullToAddPage: Bool,
            onPullToAddPage: @escaping (PageEdgePull) -> Void,
            canShowBlankCanvasMenu: @escaping (CGPoint) -> Bool,
            onBlankCanvasMenuWillShow: @escaping () -> Void,
            onBlankCanvasPaste: @escaping () -> Void
        ) {
            self.hostingController = UIHostingController(rootView: content)
            self.onPageSwipe = onPageSwipe
            self.canPullToAddPage = canPullToAddPage
            self.onPullToAddPage = onPullToAddPage
            self.canShowBlankCanvasMenu = canShowBlankCanvasMenu
            self.onBlankCanvasMenuWillShow = onBlankCanvasMenuWillShow
            self.onBlankCanvasPaste = onBlankCanvasPaste
            self.lastPageSize = pageSize
        }

        func installBlankCanvasPasteMenu() {
            guard blankCanvasEditMenuInteraction == nil else { return }
            let interaction = UIEditMenuInteraction(delegate: self)
            contentView.addInteraction(interaction)
            blankCanvasEditMenuInteraction = interaction

            let press = BlankCanvasLongPressGestureRecognizer(target: self, action: #selector(handleBlankCanvasLongPress(_:)))
            press.minimumPressDuration = 0.5
            press.delegate = self
            contentView.addGestureRecognizer(press)
        }

        @objc private func handleBlankCanvasLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began else { return }
            let location = gesture.location(in: contentView)
            guard canShowBlankCanvasMenu(location) else { return }
            onBlankCanvasMenuWillShow()
            blankCanvasEditMenuInteraction?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: location))
        }

        func installPageSwipeGesture(on scrollView: UIScrollView) {
            guard pageSwipeGesture == nil else { return }

            let gesture = UIPanGestureRecognizer(target: self, action: #selector(handlePageSwipePan(_:)))
            gesture.minimumNumberOfTouches = 1
            gesture.maximumNumberOfTouches = 1
            gesture.cancelsTouchesInView = false
            gesture.delaysTouchesBegan = false
            gesture.delaysTouchesEnded = false
            // Page turns are finger gestures. Pencil strokes must continue
            // straight to PencilKit, even when a stroke runs horizontally.
            gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
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

            // contentSize must track zoomScale, not the raw page size — see
            // centerPage(), which keeps it in sync on every zoom/layout pass.
            scrollView.maximumZoomScale = 4.0
            scrollView.panGestureRecognizer.minimumNumberOfTouches = panRequiresTwoFingers ? 2 : 1
            // Finger drawing uses one finger, so page turns use two in that
            // mode. With Pencil drawing, a single finger can turn the page.
            pageSwipeGesture?.minimumNumberOfTouches = panRequiresTwoFingers ? 2 : 1
            pageSwipeGesture?.maximumNumberOfTouches = panRequiresTwoFingers ? 2 : 1

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
            let horizontalDrag = abs(translation.x) >= 5 && abs(translation.x) > abs(translation.y) * 1.2
            let horizontalFlick = abs(velocity.x) > 150 && abs(velocity.x) > abs(velocity.y)
            return horizontalDrag || horizontalFlick
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard let pageSwipeGesture else {
                return false
            }
            // PencilKit has its own nested scroll view. Its pan recognizer
            // must be allowed alongside this recognizer or the page swipe
            // loses the touch before it can finish.
            return (gestureRecognizer === pageSwipeGesture && otherGestureRecognizer is UIPanGestureRecognizer)
                || (otherGestureRecognizer === pageSwipeGesture && gestureRecognizer is UIPanGestureRecognizer)
        }

        private var pullIsEligible = false
        private var isPullingToAddPage = false

        /// True when the page cannot scroll any further to the right, so a
        /// leftward drag is a request for the next page and not a pan of a
        /// zoomed-in page.
        private func isPinnedToTrailingEdge(_ scrollView: UIScrollView) -> Bool {
            let maxOffsetX = scrollView.contentSize.width - scrollView.bounds.width + scrollView.adjustedContentInset.right
            return scrollView.contentOffset.x >= maxOffsetX - 1
        }

        /// Reports a leftward drag on the last page so the editor can show the
        /// page being pulled. Returns true when this gesture belongs to the pull.
        private func handleAddPagePull(_ gesture: UIPanGestureRecognizer, in scrollView: UIScrollView) -> Bool {
            let translation = gesture.translation(in: scrollView)
            switch gesture.state {
            case .began:
                pullIsEligible = isPinnedToTrailingEdge(scrollView)
                isPullingToAddPage = false
                return false
            case .changed:
                guard pullIsEligible else { return false }
                let leftward = -translation.x
                let horizontal = abs(translation.x) > abs(translation.y) * 1.2
                if leftward > 0, isPullingToAddPage || horizontal {
                    isPullingToAddPage = true
                    onPullToAddPage(.changed(leftward))
                    return true
                }
                if isPullingToAddPage {
                    onPullToAddPage(.changed(0))
                    return true
                }
                return false
            case .ended:
                guard isPullingToAddPage else { return false }
                isPullingToAddPage = false
                let velocity = gesture.velocity(in: scrollView)
                onPullToAddPage(.ended(distance: max(0, -translation.x), flick: velocity.x < -800))
                return true
            case .cancelled, .failed:
                guard isPullingToAddPage else { return false }
                isPullingToAddPage = false
                onPullToAddPage(.cancelled)
                return true
            default:
                return false
            }
        }

        @objc private func handlePageSwipePan(_ gesture: UIPanGestureRecognizer) {
            if canPullToAddPage, let scrollView = gesture.view as? UIScrollView,
               handleAddPagePull(gesture, in: scrollView) {
                return
            }
            guard gesture.state == .ended, let view = gesture.view else { return }

            let translation = gesture.translation(in: view)
            let velocity = gesture.velocity(in: view)
            let horizontalDistance = abs(translation.x)
            let verticalDistance = abs(translation.y)
            let isLongHorizontalSwipe = horizontalDistance > 50 && horizontalDistance > verticalDistance * 1.2
            let isFastHorizontalSwipe = abs(velocity.x) > 500 && abs(velocity.x) > abs(velocity.y) * 1.1
            guard isLongHorizontalSwipe || isFastHorizontalSwipe else { return }

            let directionValue = isLongHorizontalSwipe ? translation.x : velocity.x
            let direction: PageSwipeDirection = directionValue < 0 ? .next : .previous
            // On the last page the next page is added only by pulling, which
            // shows the pull and asks for a full drag, not by a bare swipe.
            if canPullToAddPage && direction == .next { return }
            onPageSwipe(direction)
        }

        func editMenuInteraction(
            _ interaction: UIEditMenuInteraction,
            menuFor configuration: UIEditMenuConfiguration,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            UIMenu(children: [
                UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                    self?.onBlankCanvasPaste()
                }
            ])
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
            // UIScrollView doesn't rescale contentSize on its own as zoomScale
            // changes — it only transforms the zoomed view visually. Without
            // this, contentSize stays pinned to the unzoomed page size, so the
            // maximum scroll offset UIKit allows is far short of the actual
            // (scaled) bottom of the page: any zoom above 1x gets stuck around
            // the vertical middle and can never reach the bottom.
            let scaledContentSize = CGSize(width: scaledWidth, height: scaledHeight)
            if scrollView.contentSize != scaledContentSize {
                scrollView.contentSize = scaledContentSize
            }
            let horizontalInset = max((scrollView.bounds.width - scaledWidth) / 2, 0)
            let verticalInset = max((scrollView.bounds.height - scaledHeight) / 2, 0)
            // Leave room to scroll the last line of a page above the home
            // indicator instead of stopping it underneath the bottom inset.
            let bottomClearance = max(scrollView.window?.safeAreaInsets.bottom ?? 0, 0) + 8
            scrollView.contentInset = UIEdgeInsets(
                top: verticalInset,
                left: horizontalInset,
                bottom: verticalInset + bottomClearance,
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
