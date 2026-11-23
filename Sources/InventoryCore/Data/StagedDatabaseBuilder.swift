import Foundation
import GRDB

/// Строит отдельную базу из проверенного архива. Активное хранилище не
/// открывается и не меняется; результат — файл в пустой staging-папке.
///
/// Схема создаётся текущими миграциями, данные вставляются одной транзакцией
/// в порядке ссылок: родители мест раньше детей, статусы и люди раньше вещей,
/// вещи раньше истории. Триггеры неизменяемости истории остаются включёнными:
/// история вставляется INSERT, а не переносится через UPDATE/DELETE. Обычный
/// seed не запускается, поэтому статусы и настройки не дублируются.
public enum StagedDatabaseBuilder {
  /// - Parameter databaseURL: путь к новому файлу. Существующий файл не
  ///   перезаписывается. При ошибке удаляется только этот файл и его журналы.
  public static func build(from validated: ValidatedBackup, at databaseURL: URL) throws -> URL {
    let fileManager = FileManager.default
    guard !fileManager.fileExists(atPath: databaseURL.path) else {
      throw AppException(
        .ioError,
        params: ["path": .string(databaseURL.path)],
        debugMessage: "staging database path already exists"
      )
    }
    try? fileManager.createDirectory(
      at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)

    do {
      let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration())
      defer { try? queue.close() }

      try Schema.makeMigrator().migrate(queue)
      try queue.write { db in
        try insertAll(validated, into: db)
        try db.execute(sql: "PRAGMA user_version = \(BackupFormat.version)")
        try checkIntegrity(db)
      }
    } catch let error as AppException {
      removeDatabaseFiles(at: databaseURL)
      throw error
    } catch {
      removeDatabaseFiles(at: databaseURL)
      throw AppException(
        .importFailed,
        params: ["path": .string(databaseURL.path)],
        debugMessage: "cannot build staging database: \(error)"
      )
    }
    return databaseURL
  }

  // MARK: - Вставка

  private static func configuration() -> Configuration {
    var configuration = InventoryDatabase.makeConfiguration()
    configuration.foreignKeysEnabled = true
    return configuration
  }

  private static func insertAll(_ validated: ValidatedBackup, into db: Database) throws {
    for table in BackupFormat.tableNames {
      let rows = orderedRows(of: table, in: validated)
      for row in rows {
        try insert(row, into: table, db: db)
      }
    }
  }

  private static func orderedRows(of table: String, in validated: ValidatedBackup)
    -> [[String: BackupValue]]
  {
    let rows = validated.table(named: table)?.rows ?? []
    guard table == "places" else { return rows }
    return topologicalPlaces(rows)
  }

  /// Родители раньше детей: проверки циклов уже выполнены `BackupValidator`.
  private static func topologicalPlaces(_ rows: [[String: BackupValue]]) -> [[String: BackupValue]]
  {
    var remaining = rows
    var placed = Set<String>()
    var result: [[String: BackupValue]] = []
    while !remaining.isEmpty {
      let ready = remaining.filter { row in
        guard case .text(let parent) = row["parent_id"] ?? .null else { return true }
        return placed.contains(parent)
      }
      guard !ready.isEmpty else {
        result.append(contentsOf: remaining)
        break
      }
      for row in ready {
        if case .text(let id) = row["id"] ?? .null { placed.insert(id) }
      }
      result.append(contentsOf: ready)
      remaining.removeAll { row in ready.contains { $0 == row } }
    }
    return result
  }

  private static func insert(_ row: [String: BackupValue], into table: String, db: Database)
    throws
  {
    let columns = row.keys.sorted()
    let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
    let values: [(any DatabaseValueConvertible)?] = columns.map { column in
      switch row[column] ?? .null {
      case .null: return nil
      case .integer(let value): return value
      case .text(let value): return value
      }
    }
    try db.execute(
      sql: "INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(placeholders))",
      arguments: StatementArguments(values)
    )
  }

  // MARK: - Проверка

  private static func checkIntegrity(_ db: Database) throws {
    let integrity = try String.fetchOne(db, sql: "PRAGMA integrity_check")
    guard integrity == "ok" else {
      throw AppException(
        .importFailed,
        debugMessage: "staging integrity_check returned: \(integrity ?? "no result")"
      )
    }
    let violations = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
    guard violations.isEmpty else {
      throw AppException(
        .importFailed,
        debugMessage: "staging has \(violations.count) foreign key violations"
      )
    }
  }

  private static func removeDatabaseFiles(at url: URL) {
    let fileManager = FileManager.default
    for path in [url.path, url.path + "-wal", url.path + "-shm", url.path + "-journal"] {
      if fileManager.fileExists(atPath: path) {
        try? fileManager.removeItem(atPath: path)
      }
    }
  }
}
