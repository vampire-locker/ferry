import FerryCore
import Foundation
import XCTest

@testable import FerryApp

/// Opt-in only. Standard tests never open a real USB device.
@MainActor
final class LiveAutoConnectTests: XCTestCase {
  func testAlreadyAttachedPhoneConnectsWithoutButton() async throws {
    guard ProcessInfo.processInfo.environment["FERRY_VERIFY_USB"] == "1",
      let path = ProcessInfo.processInfo.environment["FERRY_LIVE_ENGINE"]
    else {
      throw XCTSkip("Requires explicit FERRY_VERIFY_USB=1 and an idle connected phone")
    }
    let runner = EngineRunner(executable: URL(fileURLWithPath: path))
    let model = AppModel(runner: runner)
    defer { model.shutdown() }
    model.activate()  // Same entry point as the window. Never call connect() here.
    let deadline = Date().addingTimeInterval(45)
    while Date() < deadline && (model.storages.isEmpty || model.busy || model.entries.isEmpty) {
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertFalse(model.busy, model.status)
    XCTAssertFalse(model.storages.isEmpty, model.error ?? model.status)
    XCTAssertFalse(model.entries.isEmpty, model.error ?? model.status)
    print(
      "LIVE AUTO CONNECT: \(model.deviceName), storages=\(model.storages.count), rootEntries=\(model.entries.count)"
    )
  }
}
