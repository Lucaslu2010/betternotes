import SwiftUI
import UIKit
import PencilKit
import SwiftData

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

struct PageScrollCommand: Equatable, Identifiable {
    let id = UUID()
    let rect: CGRect
}

/// Native page coordinates for the one zoomable vertical writing area.
struct VerticalNotebookLayout {
    static let spacing: CGFloat = 24
    static let padding: CGFloat = 24
    let pageFrames: [CGRect]
    let contentSize: CGSize

    init(pageSizes: [CGSize], showsAddPage: Bool) {
        let width = pageSizes.map(\.width).max() ?? 1
        var y = Self.padding
        var frames: [CGRect] = []
        for size in pageSizes {
            frames.append(CGRect(x: (width - size.width) / 2, y: y, width: size.width, height: size.height))
            y += size.height + Self.spacing
        }
        if showsAddPage { y += 68 }
        let trailingSpacing = showsAddPage || pageSizes.isEmpty ? 0 : Self.spacing
        contentSize = CGSize(width: width, height: y + Self.padding - trailingSpacing)
        pageFrames = frames
    }

    func pageIndex(at viewport: CGRect) -> Int? {
        guard !viewport.isEmpty else { return nil }
        if let index = pageFrames.firstIndex(where: { viewport.midY >= $0.minY && viewport.midY <= $0.maxY }) { return index }
        return pageFrames.indices.min { abs(pageFrames[$0].midY - viewport.midY) < abs(pageFrames[$1].midY - viewport.midY) }
    }

    func visibleCenter(for index: Int, viewport: CGRect) -> CGPoint {
        let frame = pageFrames[index]
        let visible = frame.intersection(viewport)
        guard !visible.isNull, !visible.isEmpty else { return CGPoint(x: frame.width / 2, y: frame.height / 2) }
        return CGPoint(x: visible.midX - frame.minX, y: visible.midY - frame.minY)
    }
}

struct ZoomablePageView<Content: View>: UIViewRepresentable {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var aiSettings: AISettingsStore
    @EnvironmentObject private var aiService: AIService
    @EnvironmentObject private var corpusStore: NoteCorpusStore
    @EnvironmentObject private var assistantCoordinator: AssistantCoordinator
    @EnvironmentObject private var writingSuggestions: WritingSuggestionCoordinator
    @EnvironmentObject private var ocrSettings: OCRSettingsStore
    @EnvironmentObject private var ocrService: OCRService

    struct HostedContent: View {
        let content: Content
        let modelContext: ModelContext
        let aiSettings: AISettingsStore
        let aiService: AIService
        let corpusStore: NoteCorpusStore
        let assistantCoordinator: AssistantCoordinator
        let writingSuggestions: WritingSuggestionCoordinator
        let ocrSettings: OCRSettingsStore
        let ocrService: OCRService

        var body: some View {
            content
                .environment(\.modelContext, modelContext)
                .environmentObject(aiSettings)
                .environmentObject(aiService)
                .environmentObject(corpusStore)
                .environmentObject(assistantCoordinator)
                .environmentObject(writingSuggestions)
                .environmentObject(ocrSettings)
                .environmentObject(ocrService)
        }
    }

    private var hostedContent: HostedContent {
        HostedContent(content: content, modelContext: modelContext, aiSettings: aiSettings,
                      aiService: aiService, corpusStore: corpusStore, assistantCoordinator: assistantCoordinator,
                      writingSuggestions: writingSuggestions, ocrSettings: ocrSettings, ocrService: ocrService)
    }

    let pageSize: CGSize
    let isZoomEnabled: Bool
    let continuousScrolling: Bool
    let zoomReferenceSize: CGSize?
    let panRequiresTwoFingers: Bool
    let onPageSwipe: (PageSwipeDirection) -> Void
    @Binding var zoomCommand: PageZoomCommand?
    @Binding var zoomScale: CGFloat
    @Binding var zoomRatio: CGFloat
    @Binding var visiblePageCenter: CGPoint
    @Binding var visibleContentRect: CGRect
    @Binding var scrollCommand: PageScrollCommand?
    let canShowBlankCanvasMenu: (CGPoint) -> Bool
    let onBlankCanvasMenuWillShow: () -> Void
    let onBlankCanvasPaste: () -> Void
    let content: Content

    init(
        pageSize: CGSize,
        panRequiresTwoFingers: Bool,
        isZoomEnabled: Bool = true,
        continuousScrolling: Bool = false,
        zoomReferenceSize: CGSize? = nil,
        onPageSwipe: @escaping (PageSwipeDirection) -> Void = { _ in },
        zoomCommand: Binding<PageZoomCommand?> = .constant(nil),
        zoomScale: Binding<CGFloat> = .constant(1),
        zoomRatio: Binding<CGFloat> = .constant(1),
        visiblePageCenter: Binding<CGPoint> = .constant(.zero),
        visibleContentRect: Binding<CGRect> = .constant(.zero),
        scrollCommand: Binding<PageScrollCommand?> = .constant(nil),
        canShowBlankCanvasMenu: @escaping (CGPoint) -> Bool = { _ in false },
        onBlankCanvasMenuWillShow: @escaping () -> Void = {},
        onBlankCanvasPaste: @escaping () -> Void = {},
        @ViewBuilder content: () -> Content
    ) {
        self.pageSize = pageSize
        self.isZoomEnabled = isZoomEnabled
        self.continuousScrolling = continuousScrolling
        self.zoomReferenceSize = zoomReferenceSize
        self.panRequiresTwoFingers = panRequiresTwoFingers
        self.onPageSwipe = onPageSwipe
        self._zoomCommand = zoomCommand
        self._zoomScale = zoomScale
        self._zoomRatio = zoomRatio
        self._visiblePageCenter = visiblePageCenter
        self._visibleContentRect = visibleContentRect
        self._scrollCommand = scrollCommand
        self.canShowBlankCanvasMenu = canShowBlankCanvasMenu
        self.onBlankCanvasMenuWillShow = onBlankCanvasMenuWillShow
        self.onBlankCanvasPaste = onBlankCanvasPaste
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(
            content: hostedContent,
            pageSize: pageSize,
            onPageSwipe: onPageSwipe,
            canShowBlankCanvasMenu: canShowBlankCanvasMenu,
            onBlankCanvasMenuWillShow: onBlankCanvasMenuWillShow,
            onBlankCanvasPaste: onBlankCanvasPaste
        )
        coordinator.isZoomEnabled = isZoomEnabled
        coordinator.continuousScrolling = continuousScrolling
        coordinator.zoomReferenceSize = zoomReferenceSize
        return coordinator
    }

    func makeUIView(context: Context) -> UIScrollView {
        context.coordinator.hostingController.rootView = hostedContent
        let scrollView = UIScrollView()
        scrollView.accessibilityIdentifier = continuousScrolling ? "notebook-canvas" : "page-canvas"
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

        if isZoomEnabled && !continuousScrolling { context.coordinator.installPageSwipeGesture(on: scrollView) }
        if !continuousScrolling { context.coordinator.installBlankCanvasMenu() }

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        // Forward app dependencies, never the entire environment: copying it
        // also copies SwiftUI's private navigation/presentation machinery into
        // a second hosting controller and can dismiss the notebook on entry.
        context.coordinator.hostingController.rootView = hostedContent
        context.coordinator.onPageSwipe = onPageSwipe
        context.coordinator.canShowBlankCanvasMenu = canShowBlankCanvasMenu
        context.coordinator.onBlankCanvasMenuWillShow = onBlankCanvasMenuWillShow
        context.coordinator.onBlankCanvasPaste = onBlankCanvasPaste
        context.coordinator.isZoomEnabled = isZoomEnabled
        context.coordinator.continuousScrolling = continuousScrolling
        context.coordinator.zoomReferenceSize = zoomReferenceSize
        context.coordinator.setVisibleContentRect = { rect in
            if visibleContentRect != rect { visibleContentRect = rect }
        }
        context.coordinator.scrollCommand = scrollCommand
        context.coordinator.clearScrollCommand = { self.scrollCommand = nil }
        context.coordinator.update(
            scrollView,
            pageSize: pageSize,
            panRequiresTwoFingers: panRequiresTwoFingers,
            zoomRatio: zoomRatio,
            zoomCommand: zoomCommand,
            setZoomCommand: { zoomCommand = $0 },
            setZoomScale: { if zoomScale != $0 { zoomScale = $0 } },
            setZoomRatio: { if zoomRatio != $0 { zoomRatio = $0 } },
            setVisiblePageCenter: { if visiblePageCenter != $0 { visiblePageCenter = $0 } }
        )
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate, UIContextMenuInteractionDelegate {
        private let memoryActivity = MemoryDiagnostics.begin("page-host")
        let hostingController: UIHostingController<HostedContent>
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
        var isZoomEnabled = true
        var continuousScrolling = false
        var zoomReferenceSize: CGSize?
        var setVisibleContentRect: ((CGRect) -> Void)?
        var scrollCommand: PageScrollCommand?
        var clearScrollCommand: (() -> Void)?
        private var lastScrollCommandID: UUID?

        init(
            content: HostedContent,
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
                lastPageSize = pageSize
                if continuousScrolling {
                    // Adding/removing a page changes the document's bounds,
                    // not its zoom or the position of the pages above it.
                    contentView.bounds = CGRect(origin: .zero, size: pageSize)
                    contentView.center = CGPoint(x: pageSize.width * scrollView.zoomScale / 2, y: pageSize.height * scrollView.zoomScale / 2)
                } else {
                    didSetInitialZoom = false
                    contentView.transform = .identity
                    contentView.frame = CGRect(origin: .zero, size: pageSize)
                }
                hostingController.view.frame = contentView.bounds
            } else if contentView.bounds.size != pageSize {
                contentView.bounds = CGRect(origin: .zero, size: pageSize)
                hostingController.view.frame = contentView.bounds
            }

            scrollView.contentSize = CGSize(width: pageSize.width * scrollView.zoomScale, height: pageSize.height * scrollView.zoomScale)
            scrollView.maximumZoomScale = 4.0
            scrollView.isScrollEnabled = isZoomEnabled
            scrollView.pinchGestureRecognizer?.isEnabled = isZoomEnabled
            scrollView.panGestureRecognizer.minimumNumberOfTouches = panRequiresTwoFingers ? 2 : 1
            pageSwipeGesture?.isEnabled = isZoomEnabled && !continuousScrolling && !panRequiresTwoFingers

            if !isZoomEnabled {
                scrollView.minimumZoomScale = 1
                scrollView.maximumZoomScale = 1
                scrollView.zoomScale = 1
                scrollView.contentInset = .zero
                return
            }

            DispatchQueue.main.async { [weak self, weak scrollView] in
                guard let self, let scrollView else { return }
                self.configureZoomScale(scrollView, pageSize: pageSize, zoomRatio: zoomRatio)
                if self.isZoomEnabled, let zoomCommand, self.lastZoomCommandID != zoomCommand.id {
                    self.lastZoomCommandID = zoomCommand.id
                    self.apply(zoomCommand.action, to: scrollView, pageSize: pageSize)
                    setZoomCommand(nil)
                }
                self.centerPage(in: scrollView, pageSize: pageSize)
                if self.isZoomEnabled, let command = self.scrollCommand, self.lastScrollCommandID != command.id {
                    self.lastScrollCommandID = command.id
                    let viewport = scrollView.bounds.size
                    let target = CGRect(origin: command.rect.origin, size: CGSize(
                        width: min(command.rect.width, viewport.width / scrollView.zoomScale),
                        height: min(command.rect.height, viewport.height / scrollView.zoomScale)
                    ))
                    scrollView.scrollRectToVisible(self.contentView.convert(target, to: scrollView), animated: true)
                    self.clearScrollCommand?()
                }
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
            if isZoomEnabled { updateInkViewport(in: contentView, scrollView: scrollView) }
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

            guard isZoomEnabled else {
                scrollView.minimumZoomScale = 1
                scrollView.maximumZoomScale = 1
                scrollView.zoomScale = 1
                return
            }

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
            let referenceHeight = zoomReferenceSize?.height ?? pageSize.height
            let heightScale = max(0.2, availableHeight / referenceHeight)
            let fitPageScale = min(widthScale, heightScale)
            let minimum = continuousScrolling ? widthScale * 0.5 : fitPageScale
            return (fitPage: fitPageScale, fitWidth: widthScale, minimum: minimum, maximum: 4.0)
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
            setVisibleContentRect?(contentView.convert(scrollView.bounds, from: scrollView))
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
            let verticalInset = continuousScrolling ? 0 : max((scrollView.bounds.height - scaledHeight) / 2, 0)
            scrollView.contentInset = UIEdgeInsets(
                top: verticalInset,
                left: horizontalInset,
                bottom: verticalInset,
                right: horizontalInset
            )
        }

        private func refreshRenderingScale(for scrollView: UIScrollView) {
            guard isZoomEnabled else { return }
            let renderingScale = scrollView.zoomScale
            updateInkViewport(in: contentView, scrollView: scrollView)
            guard abs(renderingScale - lastRenderingScale) >= 0.1 else { return }

            lastRenderingScale = renderingScale
            applyRenderingScale(renderingScale, to: contentView)
        }

        private func updateInkViewport(in view: UIView, scrollView: UIScrollView) {
            if let viewport = view as? InkCanvasViewport {
                viewport.updateVisibleRect(viewport.convert(scrollView.bounds, from: scrollView))
                return
            }
            for child in view.subviews { updateInkViewport(in: child, scrollView: scrollView) }
        }

        private func applyRenderingScale(_ scale: CGFloat, to view: UIView) {
            if let viewport = view as? InkCanvasViewport {
                viewport.updateZoom(scale)
                return
            }
            // PencilKit owns the scale of its private tile views. Overriding
            // their contentsScale stretches tiles and adds allocations.
            for subview in view.subviews {
                applyRenderingScale(scale, to: subview)
            }
        }
    }
}
