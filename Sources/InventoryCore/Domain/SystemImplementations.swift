import Foundation

public struct SystemClock: Clock {
  public init() {}
  public func nowMilliseconds() -> Int64 {
    Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
  }
}

public struct UuidV4IdGenerator: IdGenerator {
  public init() {}
  public func next() -> String {
    UUID().uuidString.lowercased()
  }
}
