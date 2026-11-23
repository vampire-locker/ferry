import XCTest

@testable import FerryCore

final class TransferTimingTests: XCTestCase {
  func testTransferSpeedFormatting() {
    XCTAssertEqual(Display.bytesPerSecond(12.5), "12.5 B/s")
    XCTAssertEqual(Display.bytesPerSecond(1024), "1.0 KB/s")
    XCTAssertEqual(Display.bytesPerSecond(1.5 * 1024 * 1024), "1.5 MB/s")
    XCTAssertEqual(Display.bytesPerSecond(1024 * 1024 * 1024), "1.0 GB/s")
    XCTAssertTrue(Display.bytesPerSecond(Double(Int64.max)).hasSuffix(" TB/s"))
    for value in [0.0, -1, .infinity, .nan] {
      XCTAssertEqual(Display.bytesPerSecond(value), "—")
    }
  }

  func testPreparationCountsAsElapsedButDoesNotDistortTransferRate() {
    var timing = TransferTiming()
    XCTAssertNil(timing.elapsed(at: 100))
    timing.start(at: 100)
    XCTAssertEqual(timing.elapsed(at: 120), 20)
    XCTAssertNil(timing.estimatedRemaining(at: 120))
    timing.recordProgress(bytes: 0, totalBytes: 1000, at: 120)
    timing.recordProgress(bytes: 250, totalBytes: 1000, at: 125)
    XCTAssertEqual(timing.elapsed(at: 125), 25)
    XCTAssertEqual(timing.estimatedRemaining(at: 125), 15)
    XCTAssertEqual(
      timing.estimatedRemaining(at: 130), 30, "A stall must reduce the observed average rate")
    timing.recordProgress(bytes: 500, totalBytes: 1000, at: 130)
    XCTAssertEqual(
      timing.estimatedRemaining(at: 130), 10, "File boundaries must preserve the average")
  }

  func testInsufficientProgressAndFinalizationDoNotGiveMisleadingETA() {
    var timing = TransferTiming()
    timing.start(at: 0)
    timing.recordProgress(bytes: 0, totalBytes: 0, at: 1)
    XCTAssertNil(timing.estimatedRemaining(at: 2))
    timing.recordProgress(bytes: 0, totalBytes: 100, at: 2)
    XCTAssertNil(timing.estimatedRemaining(at: 10))
    timing.recordProgress(bytes: 50, totalBytes: 100, at: 2.1)
    XCTAssertNil(timing.estimatedRemaining(at: 2.1))
    timing.recordProgress(bytes: 100, totalBytes: 100, at: 4)
    XCTAssertTrue(timing.hasTransferredAllBytes)
    XCTAssertNil(timing.estimatedRemaining(at: 5))
  }

  func testTerminalStatesFreezeElapsedAndNewDownloadResetsEverything() {
    var timing = TransferTiming()
    timing.start(at: 10)
    timing.recordProgress(bytes: 0, totalBytes: 100, at: 10)
    timing.recordProgress(bytes: 20, totalBytes: 100, at: 12)
    timing.finish(at: 15)
    timing.finish(at: 20)
    timing.recordProgress(bytes: 100, totalBytes: 100, at: 30)
    XCTAssertEqual(timing.elapsed(at: 100), 5)
    XCTAssertNil(timing.estimatedRemaining(at: 100))
    XCTAssertFalse(timing.hasTransferredAllBytes)
    timing.start(at: 200)
    XCTAssertEqual(timing.elapsed(at: 200), 0)
    XCTAssertNil(timing.estimatedRemaining(at: 201))
  }

  func testProgressRegressionRestartsRateSamplingAndFormatsLongDurations() {
    var timing = TransferTiming()
    timing.start(at: 10)
    timing.recordProgress(bytes: 100, totalBytes: 1000, at: 10)
    timing.recordProgress(bytes: 200, totalBytes: 1000, at: 12)
    XCTAssertEqual(timing.estimatedRemaining(at: 12), 16)
    timing.recordProgress(bytes: 50, totalBytes: 1000, at: 13)
    XCTAssertNil(timing.estimatedRemaining(at: 15))
    XCTAssertEqual(Display.duration(0), "00:00")
    XCTAssertEqual(Display.duration(65.9), "01:05")
    XCTAssertEqual(Display.duration(3600), "01:00:00")
    XCTAssertEqual(Display.duration(90061), "25:01:01")
    XCTAssertEqual(Display.duration(-1), "00:00")
    XCTAssertEqual(Display.duration(.infinity), "—")
    XCTAssertEqual(Display.duration(.nan), "—")
  }
}
