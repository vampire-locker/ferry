import Foundation

/// Fakes are read by tests on MainActor and invoked by the download driver on
/// its own executor. In-place collection mutations must hold the same lock as
/// reads, rather than copying a value out and racing a later write-back.
@propertyWrapper
final class ThreadSafeTestValue<Value>: @unchecked Sendable {
  private let lock = NSRecursiveLock()
  private var value: Value

  init(wrappedValue: Value) { value = wrappedValue }

  var wrappedValue: Value {
    get {
      lock.lock()
      defer { lock.unlock() }
      return value
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      value = newValue
    }
    _modify {
      lock.lock()
      defer { lock.unlock() }
      yield &value
    }
  }
}
