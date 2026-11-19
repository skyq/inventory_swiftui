import Foundation

/// Источник времени. Время хранится в UTC Unix milliseconds; отображается локально.
public protocol Clock: Sendable {
  /// Текущий момент в миллисекундах от Unix epoch (UTC).
  func nowMilliseconds() -> Int64
}
