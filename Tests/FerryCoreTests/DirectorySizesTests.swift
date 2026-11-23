import Foundation
import XCTest

@testable import FerryCore

final class DirectorySizesTests: XCTestCase {
  private let entries = [
    RemoteEntry(id: 1, storageID: 1, name: "folder", isDirectory: true, size: 0, modified: 0),
    RemoteEntry(id: 2, storageID: 1, name: "file", isDirectory: false, size: -1, modified: 100),
  ]

  func testUnknownSizeAndValidatedMergeByID() throws {
    XCTAssertFalse(entries[1].hasKnownSize)
    XCTAssertEqual(entries[1].sizeDescription, L10n.text("未读取"))
    let merged = try DirectorySizes.applying(
      [
        RemoteObjectSize(id: 2, size: 8_589_934_592), RemoteObjectSize(id: 99, size: 10),
      ], to: entries)
    XCTAssertEqual(merged.map(\.id), [1, 2])
    XCTAssertEqual(merged[1].size, 8_589_934_592)
    XCTAssertEqual(merged[1].name, "file")
    XCTAssertEqual(merged[1].modified, 100)
    XCTAssertEqual(merged[0].size, 0)
    XCTAssertTrue(merged.allSatisfy(\.hasKnownSize))
    XCTAssertThrowsError(try DirectorySizes.applying([], to: entries))
    XCTAssertThrowsError(try DirectorySizes.applying([.init(id: 2, size: -1)], to: entries))
    XCTAssertThrowsError(
      try DirectorySizes.applying([.init(id: 2, size: 1), .init(id: 2, size: 2)], to: entries))
    XCTAssertThrowsError(
      try DirectorySizes.applying(
        [.init(id: 2, size: 10)], to: entries, checkCancellation: { throw CancellationError() }))
  }

  func testProtocolKeepsLegacyDefaultAndEncodesFastListing() throws {
    let legacy = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(EngineRequest(operation: "list")))
        as? [String: Any])
    XCTAssertNil(legacy["includeSizes"])
    for include in [false, true] {
      let request = EngineRequest(operation: "list", includeSizes: include)
      let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
      XCTAssertEqual(object["includeSizes"] as? Bool, include)
    }
    let event = try JSONDecoder().decode(
      EngineEvent.self,
      from: Data("{\"type\":\"sized\",\"sizes\":[{\"id\":2,\"size\":8589934592}]}".utf8))
    XCTAssertEqual(event.sizes?.first?.size, 8_589_934_592)
  }

  func testFramerRetainsPartialLineAfterCompleteEventsAcrossChunks() throws {
    var framer = EventFramer()
    let first = try framer.append(
      Data("\n{\"type\":\"status\"}\n{\"type\":\"listed\",\"message\":\"".utf8))
    XCTAssertEqual(first.map(\.type), ["status"])
    let text = String(repeating: "照片😀", count: 100_000)
    let payload = Data((text + "\"}\n{\"type\":\"ready\"}\n").utf8)
    var events: [EngineEvent] = []
    for offset in stride(from: 0, to: payload.count, by: 1023) {
      events += try framer.append(payload.subdata(in: offset..<min(offset + 1023, payload.count)))
    }
    try framer.finish()
    XCTAssertEqual(events.map(\.type), ["listed", "ready"])
    XCTAssertEqual(events[0].message, text)
  }
}
