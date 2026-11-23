import AppKit
import QuartzCore
import XCTest

@testable import FerryApp

@MainActor
final class SailingProgressTests: XCTestCase {
  func testMotionRequiresAnActiveVisibleRunningTaskAndRespectsReduceMotion() {
    let visible = SailingMotionConditions(
      isRunning: true, reduceMotion: false, appActive: true, windowVisible: true, inViewport: true)
    XCTAssertTrue(visible.allowsMotion)
    for keyPath in [
      \SailingMotionConditions.isRunning, \.appActive, \.windowVisible, \.inViewport,
    ] {
      var blocked = visible
      blocked[keyPath: keyPath] = false
      XCTAssertFalse(blocked.allowsMotion)
    }
    var reduced = visible
    reduced.reduceMotion = true
    XCTAssertFalse(reduced.allowsMotion)
  }

  func testProgressTracksRealBytesAndStopsWithoutLeavingAnimations() throws {
    let layers = SailingProgressLayers()
    let bounds = CGRect(x: 0, y: 0, width: 400, height: 34)
    layers.layout(in: bounds, progress: nil, smooth: false)
    let start = layers.marker.position.x
    layers.layout(in: bounds, progress: 1, smooth: false)
    let end = layers.marker.position.x
    XCTAssertGreaterThan(end, start)
    layers.layout(in: bounds, progress: 0.25, smooth: false)
    XCTAssertEqual(layers.marker.position.x, start + (end - start) / 4, accuracy: 0.01)
    layers.setFloating(true)
    XCTAssertNotNil(layers.boat.animation(forKey: "float"))
    layers.layout(in: bounds, progress: 0.5, smooth: true)
    XCTAssertNotNil(layers.marker.animation(forKey: "advance"))
    layers.setFloating(false)
    XCTAssertFalse(layers.isFloating)
    XCTAssertNil(layers.boat.animationKeys())
    XCTAssertNil(layers.marker.animationKeys())
    XCTAssertEqual(layers.marker.position.x, (start + end) / 2, accuracy: 0.01)
    layers.layout(in: bounds, progress: -1, smooth: false)
    XCTAssertEqual(layers.marker.position.x, start)
    layers.layout(in: bounds, progress: 2, smooth: false)
    XCTAssertEqual(layers.marker.position.x, end)
    layers.layout(in: bounds, progress: .nan, smooth: false)
    XCTAssertEqual(layers.marker.position.x, start)
    XCTAssertNotNil(layers.boat.contents)
  }

  func testDetachedHiddenAndReducedMotionViewsRemoveAnimation() {
    _ = NSApplication.shared
    let view = SailingProgressNSView()
    view.frame = CGRect(x: 0, y: 0, width: 400, height: 34)
    view.artwork.setFloating(true)
    view.update(progress: 0.5, isRunning: true, reduceMotion: false)
    XCTAssertFalse(view.artwork.isFloating, "Detached views must not animate")
    view.artwork.setFloating(true)
    view.update(progress: 0.5, isRunning: true, reduceMotion: true)
    XCTAssertNil(view.artwork.boat.animationKeys())
    view.artwork.setFloating(true)
    view.isHidden = true
    XCTAssertNil(view.artwork.boat.animationKeys())
    view.artwork.setFloating(true)
    view.stop()
    XCTAssertNil(view.artwork.boat.animationKeys())
  }

  func testTaskStatesChooseDistinctEndScenes() {
    XCTAssertEqual(SailingScene(.completed), .docked)
    XCTAssertEqual(SailingScene(.cancelled), .anchored)
    XCTAssertEqual(SailingScene(.interrupted), .anchored)
    XCTAssertEqual(SailingScene(.failed), .distress)
    for state in [DownloadTaskState.queued, .running, .waiting, .cancelling, .paused] {
      XCTAssertEqual(SailingScene(state), .sailing)
    }
  }

  func testEndScenesPreserveActualProgressAndRestoreSailingWhenContinued() throws {
    _ = NSApplication.shared
    let view = SailingProgressNSView()
    view.frame = CGRect(x: 0, y: 0, width: 400, height: 34)
    for (scene, progress) in [(SailingScene.docked, 1.0), (.anchored, 0.6), (.distress, 0.4)] {
      view.update(progress: progress, isRunning: true, reduceMotion: false)
      let position = view.artwork.marker.position
      view.artwork.setFloating(true)
      view.update(progress: progress, isRunning: false, reduceMotion: false, scene: scene)
      XCTAssertFalse(view.artwork.root.isHidden)
      XCTAssertFalse(view.artwork.marker.isHidden)
      XCTAssertEqual(view.artwork.harbor.isHidden, scene != .docked)
      XCTAssertEqual(view.artwork.anchor.isHidden, scene != .anchored)
      XCTAssertEqual(view.artwork.buoy.isHidden, scene != .distress)
      XCTAssertEqual(view.artwork.boat.isHidden, scene == .distress)
      XCTAssertEqual(view.artwork.boat.opacity, scene == .docked ? 0 : 1)
      let lines = try XCTUnwrap(view.artwork.root.sublayers).compactMap { $0 as? CAShapeLayer }
      XCTAssertEqual(lines.count, 2)
      XCTAssertTrue(lines.allSatisfy { !$0.isHidden && $0.path != nil })
      XCTAssertEqual(try XCTUnwrap(lines.last).strokeEnd, progress, accuracy: 0.001)
      XCTAssertEqual(view.artwork.marker.position, position)
      view.artwork.setFloating(true)
      XCTAssertFalse(view.artwork.isFloating, "End scenes must never float indefinitely")
      XCTAssertNil(view.artwork.boat.animationKeys())
      XCTAssertNil(view.artwork.marker.animationKeys())
      view.update(progress: progress, isRunning: false, reduceMotion: false)
      XCTAssertFalse(view.artwork.boat.isHidden)
      XCTAssertEqual(view.artwork.boat.opacity, 1, "Continued tasks must restore the boat")
      XCTAssertTrue(view.artwork.harbor.isHidden)
      XCTAssertTrue(view.artwork.anchor.isHidden)
      XCTAssertTrue(view.artwork.buoy.isHidden)
      XCTAssertEqual(view.artwork.marker.position, position)
      XCTAssertFalse(view.artwork.isFloating)
    }
  }

  func testDockingAnimationIsFiniteAndStopsAtTheStaticScene() throws {
    let layers = SailingProgressLayers()
    layers.setScene(.docked)
    XCTAssertNil(
      layers.boat.animationKeys(), "Historical scenes start without an arrival animation")
    layers.animateDocking()
    for (layer, key) in [
      (layers.boat, "dock"), (layers.boat, "depart"), (layers.harbor, "arrive"),
      (layers.flag, "raise"),
    ] {
      let animation = try XCTUnwrap(layer.animation(forKey: key))
      XCTAssertGreaterThan(animation.duration, 0)
      XCTAssertLessThanOrEqual(animation.duration, 1.1)
      XCTAssertEqual(animation.repeatCount, 0)
      XCTAssertTrue(animation.isRemovedOnCompletion)
    }
    let fade = try XCTUnwrap(layers.boat.animation(forKey: "depart") as? CAKeyframeAnimation)
    XCTAssertEqual(fade.values as? [Int], [1, 1, 0, 0])
    let reveal = try XCTUnwrap(layers.harbor.animation(forKey: "arrive") as? CAKeyframeAnimation)
    XCTAssertEqual(reveal.values as? [Int], [0, 0, 1, 1])
    XCTAssertEqual(reveal.duration, fade.duration)
    XCTAssertGreaterThan(
      try XCTUnwrap(reveal.keyTimes?[1]).doubleValue, try XCTUnwrap(fade.keyTimes?[1]).doubleValue)
    XCTAssertLessThan(
      try XCTUnwrap(reveal.keyTimes?[1]).doubleValue, try XCTUnwrap(fade.keyTimes?[2]).doubleValue)
    XCTAssertEqual(layers.boat.opacity, 0, "The final scene must not retain the boat")
    layers.setScene(.docked)
    XCTAssertNotNil(
      layers.boat.animation(forKey: "dock"), "Repeated state delivery does not reset arrival")
    layers.stopDocking()
    XCTAssertNil(layers.boat.animationKeys())
    XCTAssertNil(layers.harbor.animationKeys())
    XCTAssertNil(layers.flag.animationKeys())
    XCTAssertTrue(CATransform3DIsIdentity(layers.boat.transform))
    XCTAssertTrue(CATransform3DIsIdentity(layers.flag.transform))
    XCTAssertFalse(layers.harbor.isHidden)
    XCTAssertEqual(layers.boat.opacity, 0, "Stopping arrival must keep the boat invisible")
    layers.animateDocking()
    layers.setScene(.anchored)
    XCTAssertEqual(layers.boat.opacity, 1)
    XCTAssertNil(layers.boat.animationKeys())
    XCTAssertNil(layers.flag.animationKeys())
  }

  func testHistoricalReducedMotionAndHiddenScenesSkipArrivalAnimation() {
    _ = NSApplication.shared
    let view = SailingProgressNSView()
    view.frame = CGRect(x: 0, y: 0, width: 400, height: 34)
    view.update(progress: 1, isRunning: false, reduceMotion: false, scene: .docked)
    XCTAssertEqual(view.artwork.boat.opacity, 0)
    XCTAssertNil(view.artwork.boat.animationKeys())
    view.update(progress: 0.9, isRunning: true, reduceMotion: true)
    view.update(progress: 1, isRunning: false, reduceMotion: true, scene: .docked)
    XCTAssertEqual(view.artwork.boat.opacity, 0)
    XCTAssertNil(view.artwork.boat.animationKeys())
    XCTAssertNil(view.artwork.flag.animationKeys())
    view.artwork.animateDocking()
    view.isHidden = true
    XCTAssertNil(view.artwork.boat.animationKeys())
    XCTAssertNil(view.artwork.flag.animationKeys())
    view.isHidden = false
    view.update(progress: 1, isRunning: false, reduceMotion: false, scene: .docked)
    XCTAssertNil(
      view.artwork.boat.animationKeys(), "Returning to a completed task does not replay arrival")
  }

  func testCompletedHarborVisibleRightEdgeAlignsWithTrackAfterArrivalAndResize() throws {
    let layers = SailingProgressLayers()
    layers.layout(in: CGRect(x: 0, y: 0, width: 400, height: 34), progress: 0.9, smooth: false)
    layers.setScene(.docked)
    layers.animateDocking()
    for width in [300.0, 600, 940, 320.5] {
      layers.layout(in: CGRect(x: 0, y: 0, width: width, height: 34), progress: 1, smooth: false)
      let track = try XCTUnwrap(layers.root.sublayers?.first as? CAShapeLayer)
      let trackBounds = try XCTUnwrap(track.path).boundingBoxOfPath
      let flag = layers.flag.convert(
        try XCTUnwrap(layers.flag.path).boundingBoxOfPath, to: layers.root)
      XCTAssertEqual(flag.maxX, trackBounds.maxX, accuracy: 0.001)
      XCTAssertEqual(
        layers.marker.position.x, trackBounds.maxX, accuracy: 0.001,
        "Byte progress must still reach the same endpoint")
      for shape in try XCTUnwrap(layers.harbor.sublayers).compactMap({ $0 as? CAShapeLayer }) {
        var visible = try XCTUnwrap(shape.path).boundingBoxOfPath
        if shape.strokeColor != nil {
          visible = visible.insetBy(dx: -shape.lineWidth / 2, dy: -shape.lineWidth / 2)
        }
        let rect = shape.convert(visible, to: layers.root)
        XCTAssertLessThanOrEqual(
          rect.maxX, trackBounds.maxX + 0.001,
          "The pier and flag must not protrude beyond the track")
        XCTAssertGreaterThanOrEqual(rect.minX, trackBounds.minX)
      }
    }
    layers.stopDocking()
    XCTAssertNil(layers.harbor.animationKeys())
  }

  func testLightAndDarkProgressArtwork() throws {
    let layers = SailingProgressLayers()
    for name in [NSAppearance.Name.aqua, .darkAqua] {
      layers.updateAppearance(try XCTUnwrap(NSAppearance(named: name)), scale: 2)
      XCTAssertNotNil(layers.boat.contents)
      guard let directory = ProcessInfo.processInfo.environment["FERRY_SAILING_SNAPSHOT_DIRECTORY"]
      else { continue }
      let width = 600
      let height = 240
      let context = try XCTUnwrap(
        CGContext(
          data: nil, width: width * 2, height: height * 2, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.scaleBy(x: 2, y: 2)
      context.setFillColor(
        name == .aqua ? NSColor.white.cgColor : NSColor(calibratedWhite: 0.12, alpha: 1).cgColor)
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      let scenes: [(SailingScene, Double)] = [
        (.sailing, 0), (.sailing, 0.5), (.docked, 1), (.anchored, 0.6), (.distress, 0.4),
      ]
      for (index, value) in scenes.enumerated() {
        let (scene, progress) = value
        layers.setScene(scene)
        layers.layout(
          in: CGRect(x: 0, y: 0, width: 560, height: 34), progress: progress, smooth: false)
        context.saveGState()
        context.translateBy(x: 20, y: CGFloat(200 - index * 44))
        layers.root.render(in: context)
        context.restoreGState()
      }
      let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
      let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      let destination = URL(fileURLWithPath: directory)
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      try data.write(to: destination.appendingPathComponent("sailing-\(name.rawValue).png"))
    }
  }
}
