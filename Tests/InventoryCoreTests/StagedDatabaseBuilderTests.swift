import Foundation
import GRDB
import InventoryCore
import Testing

@Suite("Staging-база из проверенного архива")
struct StagedDatabaseBuilderTests {
  @Test("Round-trip: данные, UUID и история совпадают с экспортом; seed не дублирует статусы")
  func roundTripPreservesData() throws {
    let fixture = try RoundTripFixture.make()
    defer { fixture.cleanUp() }

    let databaseURL = fixture.staging.appendingPathComponent("inventory.db")
    let built = try StagedDatabaseBuilder.build(from: fixture.validated, at: databaseURL)
    #expect(built == databaseURL)

    let queue = try DatabaseQueue(path: databaseURL.path, configuration: readOnly())
    defer { try? queue.close() }

    let counts = try queue.read { db -> [String: Int] in
      var result: [String: Int] = [:]
      for table in BackupFormat.tableNames {
        result[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
      }
      return result
    }
    #expect(counts == fixture.validated.counts)
    #expect(counts["statuses"] == 7)
    #expect(counts["settings"] == 3)
    #expect(counts["status_changes"] == 1)

    let itemIds = try queue.read { db in
      try String.fetchAll(db, sql: "SELECT id FROM items ORDER BY id")
    }
    #expect(itemIds == [fixture.itemId])

    let userVersion = try queue.read { db in
      try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
    }
    #expect(userVersion == Schema.version)
  }

  @Test("История неизменяема в построенной базе: UPDATE и DELETE отклоняются")
  func historyStaysImmutable() throws {
    let fixture = try RoundTripFixture.make()
    defer { fixture.cleanUp() }

    let databaseURL = fixture.staging.appendingPathComponent("inventory.db")
    _ = try StagedDatabaseBuilder.build(from: fixture.validated, at: databaseURL)

    let queue = try DatabaseQueue(
      path: databaseURL.path, configuration: InventoryDatabase.makeConfiguration())
    defer { try? queue.close() }

    #expect(throws: (any Error).self) {
      try queue.write { db in
        try db.execute(sql: "UPDATE status_changes SET comment = 'changed'")
      }
    }
    #expect(throws: (any Error).self) {
      try queue.write { db in
        try db.execute(sql: "DELETE FROM status_changes")
      }
    }
    let remaining = try queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM status_changes") ?? 0
    }
    #expect(remaining == 1)
  }

  @Test("Ошибка загрузки удаляет только собственный файл staging")
  func failedBuildRemovesOnlyStagingFile() throws {
    let fixture = try RoundTripFixture.make()
    defer { fixture.cleanUp() }

    let broken = fixture.validated.tables.map { table -> BackupTable in
      guard table.name == "items" else { return table }
      var row = table.rows[0]
      row["place_id"] = .text("00000000-0000-4000-8000-0000000000ff")
      return BackupTable(name: "items", rows: [row])
    }
    let invalid = ValidatedBackup(
      staged: fixture.validated.staged,
      manifest: fixture.validated.manifest,
      tables: broken
    )

    let sibling = fixture.staging.appendingPathComponent("unrelated.txt")
    try Data("не трогать".utf8).write(to: sibling)
    let databaseURL = fixture.staging.appendingPathComponent("inventory.db")

    do {
      _ = try StagedDatabaseBuilder.build(from: invalid, at: databaseURL)
      Issue.record("Ожидалась ошибка importFailed")
    } catch let error as AppException {
      #expect(error.code == .importFailed)
    }

    #expect(!FileManager.default.fileExists(atPath: databaseURL.path))
    #expect(FileManager.default.fileExists(atPath: sibling.path))
    #expect(try Data(contentsOf: sibling) == Data("не трогать".utf8))
  }

  @Test("Существующий файл не перезаписывается")
  func refusesExistingFile() throws {
    let fixture = try RoundTripFixture.make()
    defer { fixture.cleanUp() }

    let databaseURL = fixture.staging.appendingPathComponent("inventory.db")
    try Data("чужое".utf8).write(to: databaseURL)

    do {
      _ = try StagedDatabaseBuilder.build(from: fixture.validated, at: databaseURL)
      Issue.record("Ожидалась ошибка ioError")
    } catch let error as AppException {
      #expect(error.code == .ioError)
    }
    #expect(try Data(contentsOf: databaseURL) == Data("чужое".utf8))
  }

  private func readOnly() -> Configuration {
    var configuration = Configuration()
    configuration.readonly = true
    return configuration
  }
}

/// Реальная сессия с UUID-идентификаторами, экспорт и проверка архива.
private struct RoundTripFixture {
  let root: URL
  let staging: URL
  let validated: ValidatedBackup
  let itemId: String

  static func make() throws -> RoundTripFixture {
    let root = try TestSupport.temporaryDirectory()
    let work = try TestSupport.temporaryDirectory()
    let destination = try TestSupport.temporaryDirectory()
    let staging = try TestSupport.temporaryDirectory()

    let session = try StorageCoordinator(
      preferences: InMemoryPreferencesStore(),
      clock: FixedTestClock(value: 1_700_000_000_000),
      ids: UuidV4IdGenerator()
    ).createNew(root.appendingPathComponent("store").path)
    defer { session.close() }

    let place = try TestSupport.createPlace(session, name: "Кладовая")
    let child = try TestSupport.createPlace(session, name: "Верхняя полка", parentId: place.id)
    let item = try TestSupport.createItem(
      session, name: "Фонарь", placeId: child.id, tags: ["Свет"])
    let target = try TestSupport.statusId(session, named: "В ремонте")
    _ = try session.actions.changeStatus(
      ChangeStatusCommand(itemId: item.item.id, toStatusId: target, comment: "проверка")
    )

    let snapshot = try BackupSnapshotService(
      database: session.database,
      layout: session.layout,
      gate: session.writeGate,
      temporaryRoot: work
    ).makeSnapshot()
    defer { snapshot.discard() }

    let archiveURL = try BackupCodec.exportV1(
      snapshot: snapshot,
      to: destination,
      appVersion: "1.0",
      timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let staged = try BackupArchiveReader(temporaryRoot: work).stage(archiveAt: archiveURL)
    let validated = try BackupFormatRegistry.validate(staged)

    for url in [work, destination] { try? FileManager.default.removeItem(at: url) }
    return RoundTripFixture(
      root: root,
      staging: staging,
      validated: validated,
      itemId: item.item.id
    )
  }

  func cleanUp() {
    validated.discard()
    for url in [root, staging] { try? FileManager.default.removeItem(at: url) }
  }
}
