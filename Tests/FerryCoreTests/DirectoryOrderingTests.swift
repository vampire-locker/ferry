import Foundation
import XCTest

@testable import FerryCore

final class DirectoryOrderingTests: XCTestCase {
  func testLargeDirectoryNaturalOrderAndFolderFirst() throws {
    // Exercise the actual sorter with enough entries to expose accidental quadratic work.
    let rows = (1...50000).reversed().map { id in
      "{\"id\":\(id),\"storageID\":1,\"name\":\"照片\(id).jpg\",\"isDirectory\":\(id == 50000 ? "true" : "false"),\"size\":8589934592,\"modified\":0}"
    }
    let payload = Data(
      ("{\"type\":\"listed\",\"entries\":[" + rows.joined(separator: ",") + "]}\n").utf8)
    var framer = EventFramer()
    var events: [EngineEvent] = []
    for offset in stride(from: 0, to: payload.count, by: 65536) {
      events += try framer.append(payload.subdata(in: offset..<min(offset + 65536, payload.count)))
    }
    try framer.finish()
    XCTAssertEqual(events.count, 1)
    let entries = try XCTUnwrap(events.first?.entries)
    let result = DirectoryOrdering.sorted(entries)
    XCTAssertEqual(result.count, 50000)
    XCTAssertEqual(result.first?.id, 50000)
    XCTAssertEqual(result[1].id, 1)
    XCTAssertEqual(result[10].id, 10)
    XCTAssertEqual(result.last?.id, 49999)
  }
}
