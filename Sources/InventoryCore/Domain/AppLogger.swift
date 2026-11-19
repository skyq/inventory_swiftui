import Foundation

public enum LogLevel: String, Sendable {
  case debug
  case info
  case warning
  case error
}

/// Порт логирования. Реализации не должны бросать ошибки наружу.
public protocol AppLogger: Sendable {
  func debug(_ message: String, data: [String: String]?)
  func info(_ message: String, data: [String: String]?)
  func warning(_ message: String, error: String?, data: [String: String]?)
  func error(_ message: String, error: String?, data: [String: String]?)
}

extension AppLogger {
  public func debug(_ message: String) { debug(message, data: nil) }
  public func info(_ message: String) { info(message, data: nil) }
}

public struct NullLogger: AppLogger {
  public init() {}
  public func debug(_ message: String, data: [String: String]?) {}
  public func info(_ message: String, data: [String: String]?) {}
  public func warning(_ message: String, error: String?, data: [String: String]?) {}
  public func error(_ message: String, error: String?, data: [String: String]?) {}
}
