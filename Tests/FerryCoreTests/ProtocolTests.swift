import Foundation
import XCTest

@testable import FerryCore

final class ProtocolTests: XCTestCase {
  func testDurableRecoveryRequestAndConnectionIdentityRoundTrip() throws {
    var request = EngineRequest(operation: "download", downloadAction: "recover")
    request.durableRecovery = true
    request.recoveryPath = "/tmp/恢复记录.json"
    request.recoveryIdentity = "stable-phone"
    request.sourceDirectory = ["DCIM", "Camera"]
    let encoded = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(EngineRequest.self, from: encoded)
    XCTAssertEqual(decoded.recoveryPath, request.recoveryPath)
    XCTAssertEqual(decoded.sourceDirectory, request.sourceDirectory)
    XCTAssertEqual(decoded.recoveryIdentity, "stable-phone")
    XCTAssertEqual(decoded.durableRecovery, true)
    let event = try JSONDecoder().decode(
      EngineEvent.self,
      from: Data(
        """
        {"type":"connected","deviceKey":"phone","recoveryIdentity":"stable-phone","recoveryPath":"/tmp/恢复记录.json"}
        """.utf8))
    XCTAssertEqual(event.recoveryIdentity, "stable-phone")
    XCTAssertEqual(event.recoveryPath, request.recoveryPath)
  }
  func testVideoMonthArchiveProtocolIsIndependentAndDefaultsOff() throws {
    for photos in [false, true] {
      for videos in [false, true] {
        let request = EngineRequest(
          operation: "download", archivePhotosByMonth: photos, archiveVideosByMonth: videos)
        let object = try XCTUnwrap(
          JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(object["archiveVideosByMonth"] as? Bool, videos)
        XCTAssertEqual(object["archivePhotosByMonth"] as? Bool, photos)
        XCTAssertEqual(object["usePhotoCreationDate"] as? Bool, false)
      }
    }
    XCTAssertFalse(EngineRequest(operation: "download").archiveVideosByMonth)
  }
  func testCancelledDownloadRecoveryProtocol() throws {
    var request = EngineRequest(operation: "download", downloadID: "task", downloadAction: "resume")
    request.resumeToken = "opaque-token"
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    XCTAssertEqual(object["resumeToken"] as? String, "opaque-token")
    XCTAssertEqual(object["downloadAction"] as? String, "resume")
    let event = try JSONDecoder().decode(
      EngineEvent.self,
      from: Data(
        "{\"type\":\"completed\",\"state\":\"cancelled\",\"resumeToken\":\"opaque-token\",\"reusedBytes\":4294967296}"
          .utf8))
    XCTAssertEqual(event.resumeToken, "opaque-token")
    XCTAssertEqual(event.reusedBytes, 4_294_967_296)
    let oldEvent = try JSONDecoder().decode(
      EngineEvent.self, from: Data("{\"type\":\"completed\"}".utf8))
    XCTAssertNil(oldEvent.resumeToken)
    XCTAssertNil(oldEvent.reusedBytes)
  }
  func testConflictDecisionAndYieldedProtocol() throws {
    var request = EngineRequest(
      operation: "download", downloadID: "task", downloadAction: "resolve", promptConflicts: true)
    request.conflictDecision = DownloadConflictDecision(
      id: "question", choice: "replace", applyToAll: true)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    XCTAssertEqual(object["promptConflicts"] as? Bool, true)
    let decision = try XCTUnwrap(object["conflictDecision"] as? [String: Any])
    XCTAssertEqual(decision["id"] as? String, "question")
    XCTAssertEqual(decision["choice"] as? String, "replace")
    XCTAssertEqual(decision["applyToAll"] as? Bool, true)
    let event = try JSONDecoder().decode(
      EngineEvent.self,
      from: Data(
        """
        {"type":"yielded","state":"waiting","conflict":{"id":"question","kind":"file","targetPath":"/tmp/photo.jpg","name":"photo.jpg","existingSize":3,"existingModified":100,"incomingSize":4,"incomingModified":200,"canReplace":true}}
        """.utf8))
    XCTAssertEqual(event.type, "yielded")
    XCTAssertEqual(event.conflict?.targetPath, "/tmp/photo.jpg")
    XCTAssertEqual(event.conflict?.canReplace, true)
  }

  func testMonthArchiveRequestProtocol() throws {
    for enabled in [false, true] {
      let request = EngineRequest(operation: "download", archivePhotosByMonth: enabled)
      let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
      XCTAssertEqual(object["archivePhotosByMonth"] as? Bool, enabled)
      XCTAssertEqual(object["usePhotoCreationDate"] as? Bool, false)
    }
  }

  func testPhotoCreationDateRequestProtocol() throws {
    for enabled in [false, true] {
      let request = EngineRequest(operation: "download", usePhotoCreationDate: enabled)
      let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
      XCTAssertEqual(object["usePhotoCreationDate"] as? Bool, enabled)
    }
  }

  func testDownloadLayoutAndReportProtocol() throws {
    for layout in ["direct", "folder"] {
      let request = EngineRequest(
        operation: "download", destination: "/tmp/destination",
        downloadLayout: layout, reportDirectory: "/tmp/reports")
      let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
      XCTAssertEqual(object["downloadLayout"] as? String, layout)
      XCTAssertEqual(object["reportDirectory"] as? String, "/tmp/reports")
    }
    let legacy = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(EngineRequest(operation: "download")))
        as? [String: Any])
    XCTAssertNil(legacy["downloadLayout"])
    let event = try JSONDecoder().decode(
      EngineEvent.self,
      from: Data(
        "{\"type\":\"yielded\",\"output\":\"/tmp/destination\",\"reportPath\":\"/tmp/reports/report.json\"}"
          .utf8))
    XCTAssertEqual(event.reportPath, "/tmp/reports/report.json")
  }

  func testCooperativeDownloadRequestAndYieldedEventProtocol() throws {
    let request = EngineRequest(
      operation: "download", deviceKey: "phone", storageID: 1,
      objectIDs: [2, 3], destination: "/tmp/task", downloadID: "job", downloadAction: "begin")
    let encoded = try JSONEncoder().encode(request)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    XCTAssertEqual(object["downloadID"] as? String, "job")
    XCTAssertEqual(object["downloadAction"] as? String, "begin")
    var framer = EventFramer()
    let events = try framer.append(
      Data(
        "{\"type\":\"yielded\",\"state\":\"running\",\"output\":\"/tmp/task\"}\n{\"type\":\"ready\"}\n"
          .utf8))
    try framer.finish()
    XCTAssertEqual(events.map(\.type), ["yielded", "ready"])
    XCTAssertEqual(events.first?.output, "/tmp/task")
  }

  func testUSBTargetRouteAndRequestProtocol() throws {
    let target = try XCTUnwrap(
      USBDeviceTarget(
        locationID: 0x0213_0000, vendorID: 10, productID: 20, serialNumber: "phone"))
    XCTAssertEqual(target.busNumber, 2)
    XCTAssertEqual(target.portNumbers, [1, 3])
    XCTAssertNil(USBDeviceTarget(locationID: 0, vendorID: 10, productID: 20, serialNumber: ""))
    XCTAssertNil(
      USBDeviceTarget(locationID: 0x0210_3000, vendorID: 10, productID: 20, serialNumber: ""))
    let request = EngineRequest(operation: "connect", usbTarget: target)
    let data = try JSONEncoder().encode(request)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let route = try XCTUnwrap(object["usbTarget"] as? [String: Any])
    XCTAssertEqual(route["portNumbers"] as? [Int], [1, 3])
    XCTAssertEqual(route["busNumber"] as? Int, 2)
    XCTAssertEqual(route["vendorID"] as? Int, 10)
    XCTAssertEqual(route["serialNumber"] as? String, "phone")
  }

  func testSplitUTF8AndMultipleEvents() throws {
    let payload = Data(
      "{\"type\":\"status\",\"message\":\"正在传输照片\"}\n{\"type\":\"completed\"}\n".utf8)
    var framer = EventFramer()
    var events: [EngineEvent] = []
    for byte in payload { events += try framer.append(Data([byte])) }
    try framer.finish()
    XCTAssertEqual(events.count, 2)
    XCTAssertEqual(events.first?.message, "正在传输照片")
    XCTAssertEqual(events.last?.type, "completed")
  }

  func testTruncatedAndInvalidResponse() throws {
    var framer = EventFramer()
    _ = try framer.append(Data("{\"type\":\"listed\"}".utf8))
    XCTAssertThrowsError(try framer.finish())
    var invalid = EventFramer()
    XCTAssertThrowsError(try invalid.append(Data("not-json\n".utf8)))
  }

  func testPersistentSessionMarkersAndAuthorizationFailure() throws {
    var framer = EventFramer()
    let payload = Data(
      "{\"type\":\"diagnostic\",\"message\":\"directory property=dc0b elapsed=1s\"}\n{\"type\":\"connected\"}\n{\"type\":\"ready\"}\n{\"type\":\"error\",\"state\":\"authorization_denied\"}\n"
        .utf8)
    let events = try framer.append(payload)
    try framer.finish()
    XCTAssertEqual(events.map(\.type), ["diagnostic", "connected", "ready", "error"])
    XCTAssertEqual(events.last?.state, "authorization_denied")
  }

  func testLargeFileSizeSurvivesJSON() throws {
    let data = Data(
      "{\"type\":\"listed\",\"entries\":[{\"id\":1,\"storageID\":2,\"name\":\"视频.mp4\",\"isDirectory\":false,\"size\":8589934592,\"modified\":0}]}"
        .utf8)
    let event = try JSONDecoder().decode(EngineEvent.self, from: data)
    XCTAssertEqual(event.entries?.first?.size, 8_589_934_592)
    XCTAssertEqual(event.entries?.first?.kind, L10n.text("视频"))
  }

  func testRequestDoesNotShellEscapeOrCorruptPaths() throws {
    let path = "/tmp/中文 ' \" $(touch bad)"
    let data = try JSONEncoder().encode(EngineRequest(operation: "download", destination: path))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(object["destination"] as? String, path)
  }

  func testProgressAndSizes() {
    XCTAssertEqual(Display.progress(bytes: 0, total: 0), 0)
    XCTAssertEqual(Display.progress(bytes: 200, total: 100), 1)
    XCTAssertEqual(Display.progress(bytes: -1, total: 100), 0)
    XCTAssertEqual(Display.bytes(1 << 30), "1.0 GB")
  }

  func testDownloadRequestEncodesHiddenFilesSetting() throws {
    for enabled in [false, true] {
      var request = EngineRequest(operation: "download")
      if enabled { request.showHiddenFiles = true }
      let data = try JSONEncoder().encode(request)
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
      XCTAssertEqual(object["showHiddenFiles"] as? Bool, enabled)
    }
  }

  func testMediaRequestsAndThumbnailEvents() throws {
    for operation in ["preview", "thumbnails"] {
      let request = EngineRequest(
        operation: operation, deviceKey: "device", storageID: 2,
        objectIDs: [42], destination: "/tmp/预览", showHiddenFiles: true)
      let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
      XCTAssertEqual(object["operation"] as? String, operation)
      XCTAssertEqual(object["objectIDs"] as? [Int], [42])
    }
    let event = try JSONDecoder().decode(
      EngineEvent.self,
      from: Data(
        "{\"type\":\"thumbnail\",\"objectID\":42,\"output\":\"/tmp/预览.png\",\"state\":\"completed\"}"
          .utf8))
    XCTAssertEqual(event.objectID, 42)
    XCTAssertEqual(event.output, "/tmp/预览.png")
  }
}
