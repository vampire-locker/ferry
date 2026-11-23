import AppKit
import FerryCore
import QuartzCore
import SwiftUI

/// Only the small native layers animate. No frame clock publishes task state
/// or reevaluates the SwiftUI task card, list, or retained browser.
struct SailingProgressView: View {
  let transferred: Int64
  let total: Int64
  let state: DownloadTaskState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    SailingProgressHost(
      progress: total > 0 ? Display.progress(bytes: transferred, total: total) : nil,
      isRunning: state == .running, reduceMotion: reduceMotion, scene: SailingScene(state)
    )
    .frame(height: 34)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(L10n.text("下载进度"))
    .accessibilityValue(
      total > 0
        ? String(
          format: "%.0f%%", locale: L10n.locale,
          Display.progress(bytes: transferred, total: total) * 100)
        : L10n.text("正在准备下载…"))
  }
}

private struct SailingProgressHost: NSViewRepresentable {
  let progress: Double?
  let isRunning: Bool
  let reduceMotion: Bool
  let scene: SailingScene

  func makeNSView(context: Context) -> SailingProgressNSView { SailingProgressNSView() }
  func updateNSView(_ view: SailingProgressNSView, context: Context) {
    view.update(
      progress: progress, isRunning: isRunning, reduceMotion: reduceMotion, scene: scene)
  }
  static func dismantleNSView(_ view: SailingProgressNSView, coordinator: ()) { view.stop() }
}

enum SailingScene: Equatable {
  case sailing, docked, anchored, distress

  init(_ state: DownloadTaskState) {
    switch state {
    case .completed: self = .docked
    case .cancelled, .interrupted: self = .anchored
    case .failed: self = .distress
    default: self = .sailing
    }
  }
}

struct SailingMotionConditions {
  var isRunning = false
  var reduceMotion = false
  var appActive = false
  var windowVisible = false
  var inViewport = false

  var allowsMotion: Bool {
    isRunning && !reduceMotion && appActive && windowVisible && inViewport
  }
}

final class SailingProgressNSView: NSView {
  let artwork = SailingProgressLayers()
  private var progress: Double?
  private var isRunning = false
  private var reduceMotion = false
  private var scene: SailingScene?
  private var observations: [NSObjectProtocol] = []

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.addSublayer(artwork.root)
    setAccessibilityElement(false)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  func update(
    progress: Double?, isRunning: Bool, reduceMotion: Bool, scene: SailingScene = .sailing
  ) {
    let arriving = self.scene == .sailing && scene == .docked
    let departureX = artwork.marker.presentation()?.position.x ?? artwork.marker.position.x
    self.progress = progress
    self.isRunning = isRunning
    self.reduceMotion = reduceMotion
    self.scene = scene
    artwork.setScene(scene)
    refreshMotion()
    artwork.layout(in: bounds, progress: progress, smooth: artwork.isFloating)
    if arriving && allowsVisibleMotion { artwork.animateDocking(from: departureX) }
  }

  override func layout() {
    super.layout()
    if artwork.root.frame != bounds {
      artwork.layout(in: bounds, progress: progress, smooth: false)
    }
    refreshMotion()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    stop()
    guard let window else { return }
    artwork.updateAppearance(effectiveAppearance, scale: window.backingScaleFactor)
    let center = NotificationCenter.default
    for name in [
      NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
    ] {
      observations.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.refreshMotion() }
        })
    }
    for name in [
      NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
      NSWindow.didDeminiaturizeNotification, NSWindow.didChangeBackingPropertiesNotification,
    ] {
      observations.append(
        center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated {
            guard let self else { return }
            self.artwork.updateAppearance(
              self.effectiveAppearance, scale: self.window?.backingScaleFactor ?? 2)
            self.refreshMotion()
          }
        })
    }
    var ancestor = superview
    while let view = ancestor {
      if let clip = view as? NSClipView {
        clip.postsBoundsChangedNotifications = true
        observations.append(
          center.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
          ) {
            [weak self] _ in MainActor.assumeIsolated { self?.refreshMotion() }
          })
      }
      ancestor = view.superview
    }
    refreshMotion()
  }

  override func viewDidHide() {
    super.viewDidHide()
    refreshMotion()
  }
  override func viewDidUnhide() {
    super.viewDidUnhide()
    refreshMotion()
  }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    artwork.updateAppearance(effectiveAppearance, scale: window?.backingScaleFactor ?? 2)
  }

  private var allowsVisibleMotion: Bool {
    SailingMotionConditions(
      isRunning: true, reduceMotion: reduceMotion, appActive: NSApp?.isActive == true,
      windowVisible: window.map {
        $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
      } ?? false,
      inViewport: !isHiddenOrHasHiddenAncestor && visibleRect.intersects(bounds)
        && bounds.width > 0 && bounds.height > 0
    ).allowsMotion
  }

  private func refreshMotion() {
    let visibleMotion = allowsVisibleMotion
    artwork.setFloating(scene == .sailing && isRunning && visibleMotion)
    if !visibleMotion { artwork.stopDocking() }
  }

  func stop() {
    for observation in observations { NotificationCenter.default.removeObserver(observation) }
    observations.removeAll()
    artwork.setFloating(false)
    artwork.stopDocking()
  }

  deinit {
    for observation in observations { NotificationCenter.default.removeObserver(observation) }
  }
}

/// Core Animation owns the three-second bob/roll cycle, independently of
/// progress delivery. Paths and the SF Symbol image are otherwise static.
final class SailingProgressLayers {
  static let horizontalInset: CGFloat = 14
  let root = CALayer()
  private let track = CAShapeLayer()
  private let fill = CAShapeLayer()
  let marker = CALayer()
  let boat = CALayer()
  private let ripples = CAShapeLayer()
  let harbor = CALayer()
  private let pier = CAShapeLayer()
  private var harborRightExtent: CGFloat = 0
  let flag = CAShapeLayer()
  let anchor = CAShapeLayer()
  let buoy = CAShapeLayer()
  private let warning = CAShapeLayer()
  private let buoyRipples = CAShapeLayer()
  private(set) var scene: SailingScene = .sailing
  private(set) var isFloating = false
  private var lastAppearance: NSAppearance.Name?
  private var lastScale: CGFloat = 0

  init() {
    root.addSublayer(track)
    root.addSublayer(fill)
    root.addSublayer(harbor)
    root.addSublayer(marker)
    harbor.addSublayer(pier)
    harbor.addSublayer(flag)
    marker.addSublayer(ripples)
    marker.addSublayer(boat)
    marker.addSublayer(anchor)
    marker.addSublayer(buoy)
    buoy.addSublayer(warning)
    buoy.addSublayer(buoyRipples)
    for line in [track, fill, ripples, pier, anchor, warning, buoyRipples] {
      line.fillColor = nil
      line.lineCap = .round
      line.lineJoin = .round
    }
    track.lineWidth = 3
    fill.lineWidth = 3
    ripples.lineWidth = 1.1
    boat.bounds = CGRect(x: 0, y: 0, width: 24, height: 24)
    boat.position = CGPoint(x: 0, y: 13)
    boat.contentsGravity = .resizeAspect
    let water = CGMutablePath()
    water.move(to: CGPoint(x: -13, y: 0))
    water.addCurve(
      to: CGPoint(x: 13, y: 0), control1: CGPoint(x: -4, y: 3), control2: CGPoint(x: 4, y: -3))
    water.move(to: CGPoint(x: -8, y: -4))
    water.addQuadCurve(to: CGPoint(x: 8, y: -4), control: CGPoint(x: 0, y: -1))
    ripples.path = water
    configureHarbor()
    configureAnchor()
    configureBuoy()
    harbor.isHidden = true
    anchor.isHidden = true
    buoy.isHidden = true
    updateAppearance(NSAppearance(named: .aqua)!, scale: 2)
  }

  private func configureHarbor() {
    let dock = CGMutablePath()
    dock.move(to: CGPoint(x: -9, y: 3))
    dock.addLine(to: CGPoint(x: 9, y: 3))
    for x in [-7.0, 7] {
      dock.move(to: CGPoint(x: x, y: -2))
      dock.addLine(to: CGPoint(x: x, y: 7))
    }
    dock.move(to: CGPoint(x: 0, y: 3))
    dock.addLine(to: CGPoint(x: 0, y: 24))
    pier.path = dock
    pier.lineWidth = 1.5
    let pennant = CGMutablePath()
    pennant.move(to: CGPoint(x: 0, y: 24))
    pennant.addLine(to: CGPoint(x: 10, y: 21))
    pennant.addLine(to: CGPoint(x: 0, y: 18))
    pennant.closeSubpath()
    flag.path = pennant
    // Align the artwork's visible right edge, including the pier stroke, with the endpoint.
    harborRightExtent = max(
      pennant.boundingBoxOfPath.maxX, dock.boundingBoxOfPath.maxX + pier.lineWidth / 2)
  }

  private func configureAnchor() {
    let path = CGMutablePath()
    path.addEllipse(in: CGRect(x: 6.5, y: 5.5, width: 3, height: 3))
    path.move(to: CGPoint(x: 8, y: 5.5))
    path.addLine(to: CGPoint(x: 8, y: -4))
    path.move(to: CGPoint(x: 4.5, y: 3))
    path.addLine(to: CGPoint(x: 11.5, y: 3))
    path.move(to: CGPoint(x: 3, y: 0))
    path.addCurve(
      to: CGPoint(x: 13, y: 0), control1: CGPoint(x: 4, y: -6), control2: CGPoint(x: 12, y: -6))
    anchor.path = path
    anchor.lineWidth = 1.3
  }

  private func configureBuoy() {
    let body = CGMutablePath()
    body.move(to: CGPoint(x: -7, y: 1))
    body.addLine(to: CGPoint(x: -4, y: 16))
    body.addQuadCurve(to: CGPoint(x: 4, y: 16), control: CGPoint(x: 0, y: 21))
    body.addLine(to: CGPoint(x: 7, y: 1))
    body.closeSubpath()
    buoy.path = body
    buoy.lineWidth = 1.5
    buoy.lineJoin = .round
    let symbol = CGMutablePath()
    symbol.move(to: CGPoint(x: 0, y: 8))
    symbol.addLine(to: CGPoint(x: 0, y: 14))
    symbol.move(to: CGPoint(x: 0, y: 4.5))
    symbol.addLine(to: CGPoint(x: 0, y: 4.7))
    warning.path = symbol
    warning.lineWidth = 1.8
    let waves = CGMutablePath()
    for y in [0.0, -3] {
      waves.move(to: CGPoint(x: -10, y: y))
      waves.addQuadCurve(to: CGPoint(x: 10, y: y), control: CGPoint(x: 0, y: y - 2))
    }
    buoyRipples.path = waves
    buoyRipples.lineWidth = 1
  }

  func setScene(_ value: SailingScene) {
    guard scene != value else { return }
    setFloating(false)
    stopDocking()
    marker.removeAnimation(forKey: "advance")
    fill.removeAnimation(forKey: "advance")
    scene = value
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    harbor.isHidden = value != .docked
    anchor.isHidden = value != .anchored
    buoy.isHidden = value != .distress
    boat.isHidden = value == .distress
    // Keep the final model transparent so interrupted animations and history
    // both show only the harbor. A live arrival temporarily animates opacity.
    boat.opacity = value == .docked ? 0 : 1
    ripples.isHidden = value != .sailing
    CATransaction.commit()
  }

  func animateDocking(from departureX: CGFloat? = nil) {
    guard scene == .docked else { return }
    let settle = CAKeyframeAnimation(keyPath: "transform")
    settle.values = [
      CATransform3DMakeTranslation(departureX.map { $0 - marker.position.x } ?? -6, 0, 0),
      CATransform3DRotate(CATransform3DMakeTranslation(0, 0.8, 0), 0.025, 0, 0, 1),
      CATransform3DIdentity,
    ].map { NSValue(caTransform3D: $0) }
    settle.keyTimes = [0, 0.6, 1]
    settle.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeOut), count: 2)
    settle.duration = 0.35
    boat.add(settle, forKey: "dock")
    let depart = CAKeyframeAnimation(keyPath: "opacity")
    depart.values = [1, 1, 0, 0]
    depart.keyTimes = [0, 0.25, 0.6, 1]
    depart.duration = 1.1
    boat.add(depart, forKey: "depart")
    let arrive = CAKeyframeAnimation(keyPath: "opacity")
    arrive.values = [0, 0, 1, 1]
    arrive.keyTimes = [0, 0.4, 0.85, 1]
    arrive.duration = 1.1
    harbor.add(arrive, forKey: "arrive")
    let raise = CAKeyframeAnimation(keyPath: "transform.translation.y")
    raise.values = [-7, -7, 0, 0]
    raise.keyTimes = [0, 0.5, 0.95, 1]
    raise.duration = 1.1
    raise.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 3)
    flag.add(raise, forKey: "raise")
  }

  func stopDocking() {
    boat.removeAnimation(forKey: "dock")
    boat.removeAnimation(forKey: "depart")
    harbor.removeAnimation(forKey: "arrive")
    flag.removeAnimation(forKey: "raise")
  }

  func updateAppearance(_ appearance: NSAppearance, scale: CGFloat) {
    let name = appearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua
    guard lastAppearance != name || lastScale != scale else { return }
    lastAppearance = name
    lastScale = scale
    appearance.performAsCurrentDrawingAppearance {
      let tint =
        name == .darkAqua
        ? NSColor(calibratedRed: 0.23, green: 0.72, blue: 0.65, alpha: 1) : NSColor(ferryAccent)
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      track.strokeColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
      fill.strokeColor = tint.cgColor
      ripples.strokeColor = tint.withAlphaComponent(0.65).cgColor
      pier.strokeColor = NSColor.secondaryLabelColor.cgColor
      flag.fillColor = tint.cgColor
      anchor.strokeColor = NSColor.secondaryLabelColor.cgColor
      buoy.strokeColor = NSColor.systemOrange.cgColor
      buoy.fillColor = NSColor.systemOrange.withAlphaComponent(0.12).cgColor
      warning.strokeColor = NSColor.systemOrange.cgColor
      buoyRipples.strokeColor = NSColor.systemOrange.withAlphaComponent(0.65).cgColor
      let configuration = NSImage.SymbolConfiguration(pointSize: 22, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
      let image = NSImage(systemSymbolName: "sailboat.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration)
      boat.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
      boat.contentsScale = scale
      CATransaction.commit()
    }
  }

  func layout(in bounds: CGRect, progress: Double?, smooth: Bool) {
    let fraction = progress.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil } ?? 0
    let inset = min(Self.horizontalInset, max(0, bounds.width / 2))
    let start = inset
    let end = max(start, bounds.width - inset)
    let x = start + (end - start) * fraction
    let waterline: CGFloat = 7
    let oldX = marker.presentation()?.position.x ?? marker.position.x
    let oldFraction = fill.presentation()?.strokeEnd ?? fill.strokeEnd
    let resized = root.frame != bounds
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if resized {
      let path = CGMutablePath()
      path.move(to: CGPoint(x: start, y: waterline))
      path.addLine(to: CGPoint(x: end, y: waterline))
      root.frame = bounds
      track.path = path
      fill.path = path
    }
    fill.strokeEnd = fraction
    marker.position = CGPoint(x: x, y: waterline)
    harbor.position = CGPoint(x: end - harborRightExtent, y: waterline)
    CATransaction.commit()
    if smooth && !resized && abs(oldX - x) > 0.1 {
      let advance = CABasicAnimation(keyPath: "position.x")
      advance.fromValue = oldX
      advance.toValue = x
      advance.duration = 0.22
      marker.add(advance, forKey: "advance")
      let progress = CABasicAnimation(keyPath: "strokeEnd")
      progress.fromValue = oldFraction
      progress.toValue = fraction
      progress.duration = 0.22
      fill.add(progress, forKey: "advance")
    } else if !smooth || resized {
      marker.removeAnimation(forKey: "advance")
      fill.removeAnimation(forKey: "advance")
    }
  }

  func setFloating(_ enabled: Bool) {
    let enabled = enabled && scene == .sailing
    guard enabled != isFloating else { return }
    isFloating = enabled
    if enabled {
      let float = CAKeyframeAnimation(keyPath: "transform")
      float.values = zip([0.0, 1.2, 0, -1.2, 0], [-0.035, 0, 0.035, 0, -0.035]).map {
        NSValue(
          caTransform3D: CATransform3DRotate(CATransform3DMakeTranslation(0, $0, 0), $1, 0, 0, 1))
      }
      float.keyTimes = [0, 0.25, 0.5, 0.75, 1]
      float.timingFunctions = Array(
        repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 4)
      float.duration = 3
      float.repeatCount = .infinity
      boat.add(float, forKey: "float")
    } else {
      boat.removeAnimation(forKey: "float")
      marker.removeAnimation(forKey: "advance")
      fill.removeAnimation(forKey: "advance")
    }
  }
}
