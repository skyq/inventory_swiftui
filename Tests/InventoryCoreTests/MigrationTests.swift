import Foundation
import GRDB
import InventoryCore
import Testing

@Suite("Копия перед миграцией и восстановление")
struct MigrationTests {
  private enum TestError: Error {
    case boom
  }

  @Test("Копия создаётся до миграции и содержит незачекпойнченный WAL")
  func snapshotBeforeMigrationIncludesWAL() throws {
    let root = try TestSupport.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("inventory.db").path

    let queue = try DatabaseQueue(path: path)
    try queue.write { db in
      try db.execute(sql: "PRAGMA journal_mode = WAL")
      try db.execute(sql: "PRAGMA wal_autocheckpoint = 0")
      try db.execute(sql: "CREATE TABLE legacy (value TEXT)")
      try db.execute(sql: "INSERT INTO legacy (value) VALUES ('до миграции')")
    }

    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1") { db in
      try db.execute(sql: "CREATE TABLE marker (id TEXT)")
    }

    let coordinator = MigrationCoordinator(targetVersion: 1, makeMigrator: { migrator })
    let migrated = try coordinator.migrateIfNeeded(
      layout: StoreLayout(rootURL: root), createBackup: true)
    #expect(migrated)
    try queue.close()

    let backupURL = root.appendingPathComponent("_safety/before-migration/inventory.db")
    #expect(FileManager.default.fileExists(atPath: backupURL.path))

    let backup = try DatabaseQueue(
      path: backupURL.path,
      configuration: {
        var config = Configuration()
        config.readonly = true
        return config
      }())
    let legacy = try backup.read { db in
      try String.fetchOne(db, sql: "SELECT value FROM legacy")
    }
    let tables = try backup.read { db in
      try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
    }
    #expect(legacy == "до миграции")
    #expect(!tables.contains("marker"))
    try backup.close()

    let migratedDB = try DatabaseQueue(path: path)
    let version = try migratedDB.read { db in
      try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
    }
    let markerExists = try migratedDB.read { db in
      try Bool.fetchOne(
        db, sql: "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'marker'") ?? false
    }
    #expect(version == 1)
    #expect(markerExists)
    try migratedDB.close()
  }

  @Test("Сбой миграции возвращает прежнюю базу и не оставляет частичную схему")
  func failedMigrationRestoresBackup() throws {
    let root = try TestSupport.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("inventory.db").path

    let queue = try DatabaseQueue(path: path)
    try queue.write { db in
      try db.execute(sql: "CREATE TABLE legacy (value TEXT)")
      try db.execute(sql: "INSERT INTO legacy (value) VALUES ('сохранено')")
    }
    try queue.close()

    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1") { db in
      try db.execute(sql: "CREATE TABLE marker (id TEXT)")
      throw TestError.boom
    }

    let coordinator = MigrationCoordinator(targetVersion: 1, makeMigrator: { migrator })
    do {
      _ = try coordinator.migrateIfNeeded(layout: StoreLayout(rootURL: root), createBackup: true)
      Issue.record("Ожидалась ошибка migrationFailed")
    } catch let error as AppException {
      #expect(error.code == .migrationFailed)
    }

    let restored = try DatabaseQueue(
      path: path,
      configuration: {
        var config = Configuration()
        config.readonly = true
        return config
      }())
    let value = try restored.read { db in
      try String.fetchOne(db, sql: "SELECT value FROM legacy")
    }
    let tables = try restored.read { db in
      try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
    }
    #expect(value == "сохранено")
    #expect(!tables.contains("marker"))
    try restored.close()

    #expect(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("_safety/before-migration/inventory.db").path
      ))
  }

  @Test("Сбой миграции новой базы не оставляет частичную БД")
  func failedFreshMigrationRemovesDatabase() throws {
    let root = try TestSupport.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1") { db in
      try db.execute(sql: "CREATE TABLE partial (id TEXT)")
      throw TestError.boom
    }

    let coordinator = MigrationCoordinator(targetVersion: 1, makeMigrator: { migrator })
    #expect(throws: AppException.self) {
      try coordinator.migrateIfNeeded(layout: StoreLayout(rootURL: root), createBackup: false)
    }
    #expect(
      !FileManager.default.fileExists(atPath: root.appendingPathComponent("inventory.db").path))
  }

  @Test("coordinator не запускает миграцию при актуальной версии")
  func skipsCurrentVersion() throws {
    let root = try TestSupport.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try TestSupport.makeCoordinator().createNew(root.path)
    session.close()

    let coordinator = MigrationCoordinator(targetVersion: Schema.version)
    let migrated = try coordinator.migrateIfNeeded(
      layout: StoreLayout(rootURL: root), createBackup: true)
    #expect(!migrated)
    #expect(
      !FileManager.default.fileExists(
        atPath: root.appendingPathComponent("_safety/before-migration/inventory.db").path
      ))
  }
}
