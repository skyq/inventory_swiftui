import Foundation
import GRDB

/// Миграции схемы: копия базы создаётся до запуска мигратора, при сбое
/// рабочая база возвращается из копии и открытие прекращается.
public final class MigrationCoordinator {
  private let targetVersion: Int
  private let makeMigrator: () -> DatabaseMigrator
  private let logger: any AppLogger
  private let fileManager: FileManager

  public init(
    targetVersion: Int = Schema.version,
    makeMigrator: @escaping () -> DatabaseMigrator = Schema.makeMigrator,
    logger: any AppLogger = NullLogger(),
    fileManager: FileManager = .default
  ) {
    self.targetVersion = targetVersion
    self.makeMigrator = makeMigrator
    self.logger = logger
    self.fileManager = fileManager
  }

  /// - Parameter createBackup: `true` для существующей базы, `false` для новой.
  /// - Returns: `true`, если миграция выполнялась.
  @discardableResult
  public func migrateIfNeeded(layout: StoreLayout, createBackup: Bool) throws -> Bool {
    var configuration = InventoryDatabase.makeConfiguration()
    configuration.readonly = false
    let queue: DatabaseQueue
    do {
      queue = try DatabaseQueue(path: layout.databasePath, configuration: configuration)
    } catch {
      throw AppException(
        .storageCorrupt,
        params: ["path": .string(layout.databasePath)],
        debugMessage: "cannot open database for migration: \(error)"
      )
    }

    do {
      let current = try queue.read { database in
        try Int.fetchOne(database, sql: "PRAGMA user_version") ?? 0
      }
      if current > targetVersion {
        throw AppException(
          .storageNewerSchema,
          params: ["found": .int(current), "supported": .int(targetVersion)]
        )
      }
      if current == targetVersion {
        try queue.close()
        return false
      }

      var backupURL: URL?
      if createBackup {
        backupURL = try snapshotForMigration(queue: queue, layout: layout)
      }

      do {
        try makeMigrator().migrate(queue)
        try queue.inDatabase { database in
          // Версия схемы хранится в user_version — так её видит Flutter-редакция.
          // Служебная таблица GRDB остаётся: по ней будущие миграции понимают,
          // что v1 уже применена.
          try database.execute(sql: "PRAGMA user_version = \(targetVersion)")
        }
        let after = try queue.read { database in
          try Int.fetchOne(database, sql: "PRAGMA user_version") ?? 0
        }
        guard after == targetVersion else {
          throw AppException(
            .migrationFailed,
            params: ["path": .string(layout.databasePath)],
            debugMessage: "schema version \(after) after migration, expected \(targetVersion)"
          )
        }
      } catch {
        logger.error(
          "database migration failed",
          error: String(describing: error),
          data: ["path": layout.databasePath]
        )
        try? queue.close()
        if let backupURL {
          try restore(from: backupURL, layout: layout)
        } else {
          try removeDatabaseFiles(layout: layout)
        }
        throw AppException(
          .migrationFailed,
          params: ["path": .string(layout.databasePath)],
          debugMessage: "migration failed: \(error)"
        )
      }

      try queue.close()
      return true
    } catch {
      try? queue.close()
      if let appError = error as? AppException { throw appError }
      throw AppException(
        .storageCorrupt,
        params: ["path": .string(layout.databasePath)],
        debugMessage: "migration check failed: \(error)"
      )
    }
  }

  private func snapshotForMigration(queue: DatabaseQueue, layout: StoreLayout) throws -> URL {
    do {
      try fileManager.createDirectory(
        at: layout.beforeMigrationURL, withIntermediateDirectories: true)
    } catch {
      throw AppException(
        .storageUnavailable,
        params: ["path": .string(layout.beforeMigrationURL.path)],
        debugMessage: "cannot create migration backup directory: \(error)"
      )
    }

    let temporary = layout.beforeMigrationURL.appendingPathComponent("inventory.db.tmp")
    let final = layout.beforeMigrationURL.appendingPathComponent("inventory.db")
    try? fileManager.removeItem(at: temporary)
    try? fileManager.removeItem(at: final)

    // VACUUM INTO учитывает данные, уже зафиксированные в WAL.
    let escaped = temporary.path.replacingOccurrences(of: "'", with: "''")
    do {
      // VACUUM нельзя выполнять внутри транзакции, поэтому inDatabase, не write.
      try queue.inDatabase { database in
        try database.execute(sql: "VACUUM INTO '\(escaped)'")
      }
    } catch {
      throw AppException(
        .storageUnavailable,
        params: ["path": .string(temporary.path)],
        debugMessage: "cannot snapshot database before migration: \(error)"
      )
    }

    do {
      try fileManager.moveItem(at: temporary, to: final)
    } catch {
      throw AppException(
        .storageUnavailable,
        params: ["path": .string(final.path)],
        debugMessage: "cannot store migration backup: \(error)"
      )
    }
    return final
  }

  private func restore(from backup: URL, layout: StoreLayout) throws {
    do {
      try removeDatabaseFiles(layout: layout)
      try fileManager.copyItem(at: backup, to: layout.databaseURL)
      logger.warning(
        "database restored from before-migration backup",
        error: nil,
        data: ["path": layout.databasePath]
      )
    } catch {
      throw AppException(
        .migrationFailed,
        params: ["path": .string(layout.databasePath)],
        debugMessage: "cannot restore database from backup: \(error)"
      )
    }
  }

  private func removeDatabaseFiles(layout: StoreLayout) throws {
    for url in [
      layout.databaseURL,
      URL(fileURLWithPath: layout.databasePath + "-wal"),
      URL(fileURLWithPath: layout.databasePath + "-shm"),
      URL(fileURLWithPath: layout.databasePath + "-journal"),
    ] {
      if fileManager.fileExists(atPath: url.path) {
        try fileManager.removeItem(at: url)
      }
    }
  }
}
