import AppKit
import SwiftUI

/// A zoom the viewer's buttons ask for. A new id means "go there now".
struct ZoomRequest: Equatable {
  let id = UUID()
  let magnification: CGFloat
}

/// The viewer's photo on AppKit's magnifying scroll view: trackpad pinch and
/// smart zoom, double-click to zoom where you clicked, and animated steps from
/// the viewer's buttons. Dragging the photo out still gives other apps the file.
struct ZoomableImage: NSViewRepresentable {
  static let range: ClosedRange<CGFloat> = 1...6
  static let doubleClickMagnification: CGFloat = 2.5

  let image: NSImage
  let fileURL: URL
  /// Changes whenever another photo is shown, which starts it at fit.
  let identity: String
  let request: ZoomRequest?
  /// Told the magnification after every change, for the viewer's buttons.
  let onZoom: (CGFloat) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(onZoom: onZoom) }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = FittingScrollView()
    scroll.allowsMagnification = true
    scroll.minMagnification = Self.range.lowerBound
    scroll.maxMagnification = Self.range.upperBound
    scroll.hasHorizontalScroller = true
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.drawsBackground = false
    let imageView = PhotoView()
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.imageAlignment = .alignCenter
    imageView.onDoubleClick = { [weak scroll, weak coordinator = context.coordinator] point in
      guard let scroll, let coordinator else { return }
      let target = scroll.magnification > 1.01 ? 1 : Self.doubleClickMagnification
      coordinator.zoom(scroll, to: target, centeredAt: point)
    }
    scroll.documentView = imageView
    context.coordinator.observe(scroll)
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    let coordinator = context.coordinator
    coordinator.onZoom = onZoom
    guard let imageView = scroll.documentView as? PhotoView else { return }
    if imageView.image !== image { imageView.image = image }
    imageView.fileURL = fileURL
    if coordinator.identity != identity {
      coordinator.identity = identity
      scroll.magnification = 1
      onZoom(1)
    }
    if let request, request.id != coordinator.lastRequest {
      coordinator.lastRequest = request.id
      let visible = scroll.contentView.bounds
      coordinator.zoom(scroll, to: request.magnification, centeredAt: CGPoint(x: visible.midX, y: visible.midY))
    }
  }

  final class Coordinator {
    var onZoom: (CGFloat) -> Void
    var identity: String?
    var lastRequest: UUID?
    private var observer: NSObjectProtocol?

    init(onZoom: @escaping (CGFloat) -> Void) { self.onZoom = onZoom }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    /// Reports pinches as they end, so the buttons know the new zoom.
    func observe(_ scroll: NSScrollView) {
      observer = NotificationCenter.default.addObserver(
        forName: NSScrollView.didEndLiveMagnifyNotification, object: scroll, queue: .main
      ) { [weak self, weak scroll] _ in
        guard let scroll else { return }
        self?.onZoom(scroll.magnification)
      }
    }

    /// Glides to `magnification`, keeping `point` (in the photo's coordinates)
    /// under the same spot; jumps instead when Reduce Motion is on.
    func zoom(_ scroll: NSScrollView, to magnification: CGFloat, centeredAt point: CGPoint) {
      let target = magnification.clamped(to: ZoomableImage.range)
      if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        scroll.setMagnification(target, centeredAt: point)
        onZoom(target)
        return
      }
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.25
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        context.allowsImplicitAnimation = true
        scroll.animator().setMagnification(target, centeredAt: point)
      } completionHandler: { [weak self] in
        self?.onZoom(target)
      }
    }
  }
}

/// Keeps the photo exactly the size of the view at fit, so magnification 1
/// shows all of it and zooming in has the whole picture to move around.
private final class FittingScrollView: NSScrollView {
  override func layout() {
    super.layout()
    let size = contentSize
    if let documentView, documentView.frame.size != size { documentView.setFrameSize(size) }
  }
}

/// The photo itself: double-click zooms; dragging hands the file to other apps.
private final class PhotoView: NSImageView, NSDraggingSource {
  var onDoubleClick: ((CGPoint) -> Void)?
  var fileURL: URL?
  private var pressed: NSEvent?

  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 {
      pressed = nil
      onDoubleClick?(convert(event.locationInWindow, from: nil))
    } else {
      pressed = event
    }
  }

  override func mouseDragged(with event: NSEvent) {
    guard let pressed, let fileURL, let image else { return }
    self.pressed = nil
    let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
    let start = convert(pressed.locationInWindow, from: nil)
    item.setDraggingFrame(NSRect(x: start.x - 48, y: start.y - 48, width: 96, height: 96), contents: image)
    beginDraggingSession(with: [item], event: pressed, source: self)
  }

  override func mouseUp(with event: NSEvent) { pressed = nil }

  func draggingSession(
    _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    .copy
  }
}

extension Comparable {
  fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
    min(max(self, range.lowerBound), range.upperBound)
  }
}
