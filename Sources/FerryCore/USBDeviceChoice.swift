import Foundation

/// Physical USB route, independent of the address changed by macOS capture.
public struct USBDeviceTarget: Codable, Hashable, Sendable {
  public let busNumber: UInt8
  public let portNumbers: [UInt8]
  public let vendorID: UInt16
  public let productID: UInt16
  public let serialNumber: String

  public init?(locationID: UInt32, vendorID: UInt16, productID: UInt16, serialNumber: String) {
    let ports = stride(from: 20, through: 0, by: -4).map { UInt8((locationID >> $0) & 15) }
    let route = Array(ports.prefix { $0 != 0 })
    guard !route.isEmpty, ports.dropFirst(route.count).allSatisfy({ $0 == 0 }) else { return nil }
    self.busNumber = UInt8(locationID >> 24)
    self.portNumbers = route
    self.vendorID = vendorID
    self.productID = productID
    self.serialNumber = serialNumber
  }

  public var routeDescription: String {
    "\(busNumber)-" + portNumbers.map(String.init).joined(separator: ".")
  }
}

public struct USBDeviceChoice: Identifiable, Hashable, Sendable {
  public let id: UInt64
  public let name: String
  public let target: USBDeviceTarget?

  public init(id: UInt64, name: String, target: USBDeviceTarget?) {
    self.id = id
    self.name = name
    self.target = target
  }

  public var label: String {
    guard let target else { return name }
    return "\(name) · USB \(target.routeDescription)"
  }
}
