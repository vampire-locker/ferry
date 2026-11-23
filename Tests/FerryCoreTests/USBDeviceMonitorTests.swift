import XCTest

@testable import FerryCore

@MainActor
final class USBDeviceMonitorTests: XCTestCase {
  func testCaptureReenumerationKeepsSelectedPhoneWhileAnotherRemains() async throws {
    let monitor = USBDeviceMonitor()
    defer { monitor.stop() }
    let first = USBDeviceChoice(id: 1, name: "Phone", target: nil)
    let second = USBDeviceChoice(id: 2, name: "Phone", target: nil)
    var changes: [Set<UInt64>] = []
    monitor.onChange = { changes.append($0) }
    monitor.updateChoices([first, second])
    monitor.updateChoices([second])
    XCTAssertEqual(monitor.devices, [1, 2])
    monitor.updateChoices([first, second])
    try await Task.sleep(nanoseconds: 2_100_000_000)
    XCTAssertEqual(monitor.devices, [1, 2])
    XCTAssertEqual(changes, [[1, 2]], "Capture reenumeration must not look like a physical unplug")
  }

  func testRealRemovalPublishesRemainingPhonesAfterDebounce() async throws {
    let monitor = USBDeviceMonitor()
    defer { monitor.stop() }
    let first = USBDeviceChoice(id: 1, name: "Phone", target: nil)
    let second = USBDeviceChoice(id: 2, name: "Phone", target: nil)
    let third = USBDeviceChoice(id: 3, name: "Phone", target: nil)
    monitor.updateChoices([first, second])
    monitor.updateChoices([second, third])
    XCTAssertEqual(monitor.devices, [1, 2, 3], "New phones should appear immediately")
    try await Task.sleep(nanoseconds: 2_100_000_000)
    XCTAssertEqual(monitor.devices, [2, 3])
    XCTAssertEqual(Set(monitor.choices.map(\.id)), [2, 3])
  }
}
