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

private final class PullToAddPageIndicator: UIView {
    private let track = CAShapeLayer()
    private let progressRing = CAShapeLayer()
    private let arrow = UIImageView(image: UIImage(systemName: "arrow.up"))
    private let pageIcon = UIImageView(image: UIImage(systemName: "plus.square"))
    private let caption = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityIdentifier = "pull-to-add-page"
        tintColor = .systemBlue

        for ring in [track, progressRing] {
            ring.fillColor = UIColor.clear.cgColor
            ring.lineWidth = 4
            ring.lineCap = .round
            layer.addSublayer(ring)
        }
        progressRing.strokeEnd = 0
        arrow.tintColor = .systemBlue
        arrow.contentMode = .scaleAspectFit
        pageIcon.tintColor = .secondaryLabel
        pageIcon.contentMode = .scaleAspectFit
        caption.textAlignment = .center
        caption.font = .preferredFont(forTextStyle: .footnote)
        caption.textColor = .secondaryLabel
        addSubview(arrow)
        addSubview(pageIcon)
        addSubview(caption)
        setProgress(0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let centerX = bounds.midX
        arrow.frame = CGRect(x: centerX - 10, y: 0, width: 20, height: 18)
        pageIcon.frame = CGRect(x: centerX - 13, y: 34, width: 26, height: 26)
        caption.frame = CGRect(x: 0, y: 75, width: bounds.width, height: 22)
        let circle = UIBezierPath(
            arcCenter: CGPoint(x: centerX, y: 47),
            radius: 24,
            startAngle: -.pi / 2,
            endAngle: 3 * .pi / 2,
            clockwise: true
        ).cgPath
        track.path = circle
        progressRing.path = circle
    }

    func setProgress(_ progress: CGFloat) {
        let ready = progress >= 1
        progressRing.strokeEnd = min(max(progress, 0), 1)
        caption.text = AppLocalization.text(ready ? "Release to Add Page" : "Pull to Add Page")
        accessibilityLabel = caption.text
        arrow.tintColor = ready ? .systemGreen : .systemBlue
        progressRing.strokeColor = (ready ? UIColor.systemGreen : UIColor.systemBlue).cgColor
        track.strokeColor = UIColor.tertiaryLabel.cgColor
    }
}

struct ZoomablePageView<Content: View>: UIViewRepresentable {
    let pageSize: CGSize
    let panRequiresTwoFingers: Bool
    let onPageSwipe: (PageSwipeDirection) -> Void
    let canPullToAddPage: Bool
    let onPullToAddPage: () -> Void
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
        onPullToAddPage: @escaping () -> Void = {},
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
        scrollView.alwaysBounceVertical = canPullToAddPage
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
        scrollView.insertSubview(context.coordinator.pullToAddIndicator, belowSubview: contentView)

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
        fileprivate let pullToAddIndicator = PullToAddPageIndicator(frame: CGRect(x: 0, y: 0, width: 240, height: 100))
        var onPageSwipe: (PageSwipeDirection) -> Void
        var canPullToAddPage: Bool
        var onPullToAddPage: () -> Void
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
            onPullToAddPage: @escaping () -> Void,
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
            pullToAddIndicator.isHidden = true
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
            scrollView.alwaysBounceVertical = canPullToAddPage
            scrollView.panGestureRecognizer.minimumNumberOfTouches = panRequiresTwoFingers ? 2 : 1
            // Finger drawing uses one finger, so page turns use two in that
            // mode. With Pencil drawing, a single finger can turn the page.
            pageSwipeGesture?.minimumNumberOfTouches = panRequiresTwoFingers ? 2 : 1
            pageSwipeGesture?.maximumNumberOfTouches = panRequiresTwoFingers ? 2 : 1
            if !canPullToAddPage { pullToAddIndicator.isHidden = true }

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
            updatePullToAddIndicator(in: scrollView)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            let shouldAdd = canPullToAddPage && bottomOverscroll(in: scrollView) >= 100
            pullToAddIndicator.isHidden = true
            if shouldAdd { onPullToAddPage() }
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
            pullToAddIndicator.frame.origin = CGPoint(
                x: (scaledWidth - pullToAddIndicator.bounds.width) / 2,
                y: scaledHeight + 8
            )
        }

        private func bottomOverscroll(in scrollView: UIScrollView) -> CGFloat {
            let bottomOffset = max(
                -scrollView.adjustedContentInset.top,
                scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
            )
            return max(0, scrollView.contentOffset.y - bottomOffset)
        }

        private func updatePullToAddIndicator(in scrollView: UIScrollView) {
            guard canPullToAddPage, scrollView.isDragging, !scrollView.isZooming else {
                pullToAddIndicator.isHidden = true
                return
            }
            let distance = bottomOverscroll(in: scrollView)
            pullToAddIndicator.isHidden = distance < 8
            if distance >= 8 { pullToAddIndicator.setProgress(distance / 100) }
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
