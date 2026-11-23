import XCTest

@testable import FerryCore

final class AutoConnectPolicyTests: XCTestCase {
  func testAlreadyAttachedAndArrivalConnectOnce() {
    var policy = AutoConnectPolicy()
    XCTAssertNil(policy.candidate(isBusy: false, hasConnection: false, isDemo: false))
    policy.update(devices: [42])
    XCTAssertEqual(policy.candidate(isBusy: false, hasConnection: false, isDemo: false), 42)
    XCTAssertTrue(policy.claim(42))
    policy.update(devices: [42])
    XCTAssertEqual(policy.attemptCount(for: 42), 1)
    XCTAssertNil(policy.candidate(isBusy: false, hasConnection: true, isDemo: false))
  }

  func testBusyAndDemoDoNotConsumeAttempts() {
    var policy = AutoConnectPolicy()
    policy.update(devices: [42])
    XCTAssertNil(policy.candidate(isBusy: true, hasConnection: false, isDemo: false))
    XCTAssertNil(policy.candidate(isBusy: false, hasConnection: false, isDemo: true))
    XCTAssertEqual(policy.attemptCount(for: 42), 0)
    XCTAssertEqual(policy.candidate(isBusy: false, hasConnection: false, isDemo: false), 42)
  }

  func testRetriesStopAndReplugResetsBudget() {
    var policy = AutoConnectPolicy()
    policy.update(devices: [42])
    for _ in 0..<3 { XCTAssertTrue(policy.claim(42)) }
    XCTAssertFalse(policy.claim(42))
    XCTAssertNil(policy.candidate(isBusy: false, hasConnection: false, isDemo: false))
    policy.update(devices: [])
    XCTAssertFalse(policy.claim(42))
    policy.update(devices: [43])
    XCTAssertEqual(policy.candidate(isBusy: false, hasConnection: false, isDemo: false), 43)
    XCTAssertEqual(policy.attemptCount(for: 43), 0)
  }

  func testManualActionSuppressesAutomaticRetries() {
    var policy = AutoConnectPolicy()
    policy.update(devices: [42])
    policy.suppressCurrentAttachment()
    policy.update(devices: [42])
    XCTAssertNil(policy.candidate(isBusy: false, hasConnection: false, isDemo: false))
    policy.update(devices: [])
    policy.update(devices: [42])
    XCTAssertEqual(policy.candidate(isBusy: false, hasConnection: false, isDemo: false), 42)
  }

  func testMultiplePhonesRequireUserResolution() {
    var policy = AutoConnectPolicy()
    policy.update(devices: [42, 43])
    XCTAssertNil(policy.candidate(isBusy: false, hasConnection: false, isDemo: false))
    XCTAssertFalse(policy.claim(42))
    policy.update(devices: [43])
    XCTAssertEqual(policy.candidate(isBusy: false, hasConnection: false, isDemo: false), 43)
  }

  func testOnlyMTPInterfacesAreCandidates() {
    XCTAssertTrue(
      USBInterfaceDescriptor(classCode: 6, subclassCode: 1, name: "MTP@0").isMTPCandidate)
    XCTAssertTrue(
      USBInterfaceDescriptor(classCode: 255, subclassCode: 0, name: "MTP").isMTPCandidate)
    XCTAssertFalse(
      USBInterfaceDescriptor(classCode: 3, subclassCode: 1, name: "Keyboard").isMTPCandidate)
    XCTAssertFalse(
      USBInterfaceDescriptor(classCode: 9, subclassCode: 0, name: "Hub").isMTPCandidate)
    XCTAssertFalse(
      USBInterfaceDescriptor(classCode: 255, subclassCode: 66, name: "ADB").isMTPCandidate)
  }
}
