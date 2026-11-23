import Foundation
import XCTest

@testable import FerryCore

final class EngineRunnerTests: XCTestCase {
  func testDemoVideoArchiveUsesSeparateOptionAndPreservesOtherMedia() async throws {
    guard let executable = ProcessInfo.processInfo.environment["FERRY_TEST_ENGINE"] else {
      throw XCTSkip("Run scripts/test.sh to provide the synthetic-device helper")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ferry-video-archive-\(UUID().uuidString)")
    let destination = root.appendingPathComponent("output")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = EngineRunner(executable: URL(fileURLWithPath: executable))
    defer { runner.shutdown() }
    var key: String?
    for try await event in runner.events(for: EngineRequest(operation: "connect"), demo: true) {
      if event.type == "connected" { key = event.deviceKey }
    }
    var request = EngineRequest(
      operation: "download", deviceKey: try XCTUnwrap(key), storageID: 1,
      objectIDs: [111, 112, 103],
      destination: destination.path, downloadID: UUID().uuidString, downloadAction: "begin",
      downloadLayout: "direct", reportDirectory: root.appendingPathComponent("reports").path,
      usePhotoCreationDate: true, archiveVideosByMonth: true)
    var reportURL: URL?
    var finished = false
    for _ in 0..<8 {
      for try await event in runner.events(for: request, demo: true) {
        XCTAssertNotEqual(event.type, "error", event.message ?? "")
        if let path = event.reportPath { reportURL = URL(fileURLWithPath: path) }
        if event.type == "completed" { finished = true }
      }
      if finished { break }
      request.downloadAction = "next"
    }
    XCTAssertTrue(finished)
    let report = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: try XCTUnwrap(reportURL)))
        as? [String: Any])
    let items = try XCTUnwrap(report["items"] as? [[String: Any]])
    XCTAssertEqual(items.count, 3)
    let video = try XCTUnwrap(items.first { ($0["entry"] as? [String: Any])?["id"] as? Int == 112 })
    // The bundled movie's valid container date differs from its phone modification date.
    XCTAssertEqual(video["archiveDateSource"] as? String, "container")
    XCTAssertEqual(video["sourcePath"] as? String, "演示视频.mp4")
    XCTAssertNil(video["photoCreationTime"])
    XCTAssertNil(video["creationDateWarning"])
    let date = try XCTUnwrap(
      ISO8601DateFormatter().date(from: try XCTUnwrap(video["archiveDate"] as? String)))
    let components = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: date)
    let expected = String(
      format: "%04d/%02d月/演示视频.mp4", try XCTUnwrap(components.year), try XCTUnwrap(components.month)
    )
    XCTAssertEqual(video["path"] as? String, expected)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: destination.appendingPathComponent(expected).path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: destination.appendingPathComponent("演示照片.png").path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: destination.appendingPathComponent("记录-103.txt").path))
    let attributes = try FileManager.default.attributesOfItem(
      atPath: destination.appendingPathComponent(expected).path)
    XCTAssertEqual((attributes[.modificationDate] as? Date)?.timeIntervalSince1970, 1_760_000_000)
  }
  func testRecoveryCannotLaunchANewHelper() async throws {
    let runner = EngineRunner(executable: URL(fileURLWithPath: "/nonexistent-ferry-resume-test"))
    defer { runner.shutdown() }
    for action in ["resume", "restart", "recover"] {
      do {
        for try await _ in runner.events(
          for: EngineRequest(operation: "download", downloadAction: action), demo: true)
        {}
        XCTFail("Recovery should reject a missing session")
      } catch {
        XCTAssertEqual(error.localizedDescription, L10n.text("恢复信息已失效，请在本次手机连接内继续，或重新选择未完成文件。"))
      }
    }
    XCTAssertNil(runner.sessionIdentifier)
  }
  func testSteppedDownloadAllowsBrowsingOnSameHelper() async throws {
    guard let path = ProcessInfo.processInfo.environment["FERRY_TEST_ENGINE"] else {
      throw XCTSkip("Run scripts/test.sh to include the helper integration test")
    }
    let runner = EngineRunner(executable: URL(fileURLWithPath: path))
    defer { runner.shutdown() }
    var key = ""
    for try await event in runner.events(for: EngineRequest(operation: "connect"), demo: true) {
      key = event.deviceKey ?? key
    }
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: destination) }
    var request = EngineRequest(
      operation: "download", deviceKey: key, storageID: 1,
      objectIDs: [30], destination: destination.path, downloadID: "swift-job",
      downloadAction: "begin")
    var output: String?
    var types: [String] = []
    for try await event in runner.events(for: request, demo: true) {
      types.append(event.type)
      output = event.output ?? output
    }
    XCTAssertEqual(types.last, "yielded")
    var listed = false
    for try await event in runner.events(
      for: EngineRequest(operation: "list", deviceKey: key, storageID: 1), demo: true)
    {
      listed = listed || event.type == "listed"
    }
    XCTAssertTrue(listed)
    request.downloadAction = "next"
    types = []
    for try await event in runner.events(for: request, demo: true) { types.append(event.type) }
    XCTAssertEqual(types.last, "completed")
    XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(output)))
  }

  func testChangingUSBTargetWaitsForPreviousHelperCleanup() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let helper = directory.appendingPathComponent("target-helper")
    let script = """
      #!/bin/sh
      trap '' TERM
      trap 'sleep 0.1; touch "$0.cleaned"' EXIT
      while read request; do
        case "$request" in
          *'"operation":"finish"'*) printf '%s\\n' '{"type":"completed"}'; exit 0 ;;
        esac
        state=pending
        if [ -e "$0.cleaned" ]; then state=cleaned; fi
        printf '{"type":"connected","deviceName":"%s","message":"%s"}\\n' "$$" "$state"
        printf '%s\\n' '{"type":"ready"}'
      done
      """
    try Data(script.utf8).write(to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    let runner = EngineRunner(executable: helper)
    defer { runner.shutdown() }
    let first = try XCTUnwrap(
      USBDeviceTarget(
        locationID: 0x0210_0000,
        vendorID: 10, productID: 20, serialNumber: "first"))
    let second = try XCTUnwrap(
      USBDeviceTarget(
        locationID: 0x0220_0000,
        vendorID: 10, productID: 20, serialNumber: "second"))
    var pids: [String] = []
    for target in [first, second] {
      for try await event in runner.events(
        for: EngineRequest(operation: "list", usbTarget: target), demo: true)
      {
        if let pid = event.deviceName { pids.append(pid) }
        if target == second { XCTAssertEqual(event.message, "cleaned") }
      }
    }
    XCTAssertEqual(pids.count, 2)
    XCTAssertNotEqual(pids.first, pids.last)
    for try await _ in runner.events(
      for: EngineRequest(operation: "finish", usbTarget: second), demo: true)
    {}
  }

  func testStatusArrivesBeforeProcessFinishes() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let helper = directory.appendingPathComponent("status-helper")
    let script =
      "#!/bin/sh\nread request\nprintf '%s\\n' '{\"type\":\"status\",\"message\":\"正在读取文件名\"}'\nsleep 2\nprintf '%s\\n' '{\"type\":\"listed\"}'\n"
    try Data(script.utf8).write(to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    let runner = EngineRunner(executable: helper)
    let start = Date()
    var receivedStatus = false
    for try await event in runner.events(for: EngineRequest(operation: "list"), demo: false) {
      if event.type == "status" {
        receivedStatus = true
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5, "状态提示必须在目录读取完成前到达")
      }
    }
    XCTAssertTrue(receivedStatus)
  }

  func testDiagnosticEventsDoNotCompleteOrLeakIntoUIRequests() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let helper = directory.appendingPathComponent("diagnostic-helper")
    let script = """
      #!/bin/sh
      while read request; do
        printf '%s\n' '{"type":"diagnostic","message":"directory property=dc0b elapsed=1s entries=50000"}'
        printf '%s\n' '{"type":"listed","entries":[]}'
        printf '%s\n' '{"type":"diagnostic","message":"directory bulk completed"}'
        printf '%s\n' '{"type":"ready"}'
      done
      """
    try Data(script.utf8).write(to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    let runner = EngineRunner(executable: helper)
    defer { runner.shutdown() }
    for _ in 0..<2 {
      var types: [String] = []
      for try await event in runner.events(for: EngineRequest(operation: "list"), demo: true) {
        types.append(event.type)
      }
      XCTAssertEqual(types, ["listed"])
    }
  }

  func testMissingHelperReportsFailure() async {
    let runner = EngineRunner(executable: URL(fileURLWithPath: "/no-such-ferry-helper"))
    do {
      for try await _ in runner.events(for: EngineRequest(operation: "connect"), demo: true) {}
      XCTFail("missing helper unexpectedly succeeded")
    } catch {
      XCTAssertEqual(
        error.localizedDescription, L10n.text("找不到传输引擎，请运行 scripts/build-app.sh 重新构建应用。"))
    }
  }

  func testRealHelperConnectAndList() async throws {
    guard let path = ProcessInfo.processInfo.environment["FERRY_TEST_ENGINE"] else {
      throw XCTSkip("Run scripts/test.sh to include the helper integration test")
    }
    let runner = EngineRunner(executable: URL(fileURLWithPath: path))
    var connected: EngineEvent?
    for try await event in runner.events(for: EngineRequest(operation: "connect"), demo: true) {
      if event.type == "connected" { connected = event }
    }
    let key = try XCTUnwrap(connected?.deviceKey)
    XCTAssertEqual(connected?.storages?.count, 1)
    var entries: [RemoteEntry] = []
    for try await event in runner.events(
      for: EngineRequest(operation: "list", deviceKey: key, storageID: 1), demo: true)
    {
      if event.type == "listed" { entries = event.entries ?? [] }
    }
    XCTAssertEqual(entries.count, 3)
    XCTAssertEqual(entries.filter(\.isDirectory).count, 2)
  }

  func testPersistentFastListingThenSizesAndAnotherRequest() async throws {
    guard let path = ProcessInfo.processInfo.environment["FERRY_TEST_ENGINE"] else {
      throw XCTSkip("Run scripts/test.sh to include the helper integration test")
    }
    let runner = EngineRunner(executable: URL(fileURLWithPath: path))
    defer { runner.shutdown() }
    var key = ""
    for try await event in runner.events(for: EngineRequest(operation: "connect"), demo: true) {
      key = event.deviceKey ?? key
    }
    var entries: [RemoteEntry] = []
    for try await event in runner.events(
      for: EngineRequest(
        operation: "list", deviceKey: key, storageID: 1, parentID: 10, includeSizes: false),
      demo: true)
    {
      if event.type == "listed" { entries = event.entries ?? [] }
    }
    XCTAssertEqual(entries.count, 12)
    XCTAssertTrue(entries.allSatisfy { !$0.hasKnownSize })
    var sizes: [RemoteObjectSize] = []
    for try await event in runner.events(
      for: EngineRequest(operation: "sizes", deviceKey: key, storageID: 1, parentID: 10), demo: true
    ) {
      if event.type == "sized" { sizes = event.sizes ?? [] }
    }
    XCTAssertEqual(sizes.count, 12)
    XCTAssertTrue(try DirectorySizes.applying(sizes, to: entries).allSatisfy(\.hasKnownSize))
    var complete = false
    for try await event in runner.events(
      for: EngineRequest(operation: "list", deviceKey: key, storageID: 1, includeSizes: true),
      demo: true)
    {
      if event.type == "listed" { complete = event.entries?.allSatisfy(\.hasKnownSize) == true }
    }
    XCTAssertTrue(complete, "sized must be followed by ready before session reuse")
  }

  func testCrashAfterTerminalEventStillFails() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let helper = directory.appendingPathComponent("crash-helper")
    let script = "#!/bin/sh\nread request\nprintf '%s\\n' '{\"type\":\"connected\"}'\nexit 7\n"
    try Data(script.utf8).write(to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    let runner = EngineRunner(executable: helper)
    do {
      for try await _ in runner.events(for: EngineRequest(operation: "connect"), demo: true) {}
      XCTFail("crashed process unexpectedly succeeded")
    } catch {
      XCTAssertEqual(error.localizedDescription, L10n.text("传输引擎意外退出（\(7)），请重新连接手机。"))
    }
  }
}
