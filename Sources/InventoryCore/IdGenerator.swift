import Foundation

/// Генератор идентификаторов. Идентификаторы — UUID v4 в виде строки.
public protocol IdGenerator: Sendable {
  func next() -> String
}
