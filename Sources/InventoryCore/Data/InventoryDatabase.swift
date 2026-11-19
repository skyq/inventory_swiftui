import Foundation
import GRDB

/// Тонкая обёртка над GRDB `DatabasePool`: WAL, foreign keys и единая точка
/// доступа к базе для сервисов ядра.
public final class InventoryDatabase: @unchecked Sendable {
  public let pool: DatabasePool
  public let path: String

  public init(path: String, configuration: Configuration = InventoryDatabase.makeConfiguration())
    throws
  {
    self.path = path
    self.pool = try DatabasePool(path: path, configuration: configuration)
  }

  public static func makeConfiguration(readOnly: Bool = false) -> Configuration {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    configuration.readonly = readOnly
    // Приложение однопользовательское; один писатель и один читатель достаточны.
    configuration.maximumReaderCount = 2
    return configuration
  }

  public func read<T>(_ block: (Database) throws -> T) throws -> T {
    try pool.read(block)
  }

  public func write<T>(_ block: (Database) throws -> T) throws -> T {
    try pool.write(block)
  }

  public func close() {
    try? pool.close()
  }
}
