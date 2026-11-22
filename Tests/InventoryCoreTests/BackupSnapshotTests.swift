import Foundation
import InventoryCore
import Testing

@Suite("Согласованный снимок для экспорта")
struct BackupSnapshotTests {
  @Test("Снимок содержит девять таблиц, WAL-данные и только связанные файлы")
  func snapshotContainsConsistentTablesAndFiles() throws {
    let snapshotRoot = try TestSupport.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: snapshotRoot) }

    let session = try TestSupport.makeSession().0
    let layout = session.layout
    defer {
      session.close()
      try? FileManager.default.removeItem(at: layout.rootURL)
    }

    let place = try TestSupport.createPlace(session, name: "Кладовая")
    let item = try TestSupport.createItem(
      session, name: "Фонарь", placeId: place.id)

    // Файл, на который нет ссылки в БД, не должен попасть в архив.
    let orphan = layout.photosURL.appendingPathComponent("orphan.jpg")
    try Data([0x01, 0x02]).write(to: orphan)

    let clock = FixedTestClock(value: 1_700_000_000_000)
    let service = BackupSnapshotService(
      database: session.database,
      layout: layout,
      gate: session.writeGate,
      clock: clock,
      temporaryRoot: snapshotRoot
    )
    let snapshot = try service.makeSnapshot()
    defer { snapshot.discard() }

    #expect(snapshot.createdAt == 1_700_000_000_000)
    #expect(snapshot.schemaVersion == Schema.version)
    #expect(snapshot.tables.map(\.name) == BackupFormat.tableNames)
    #expect(
      snapshot.counts == [
        "places": 1, "statuses": 7, "people": 0, "items": 1, "tags": 0,
        "item_tags": 0, "status_changes": 0, "transfers": 0, "settings": 3,
      ])

    let placeRow = try #require(snapshot.table(named: "places")?.rows.first)
    #expect(placeRow["id"] == .text(place.id))
    #expect(placeRow["name"] == .text("Кладовая"))
    #expect(placeRow["parent_id"] == .null)
    #expect(placeRow["created_at"] == .integer(1_700_000_000_000))

    let itemRow = try #require(snapshot.table(named: "items")?.rows.first)
    #expect(itemRow["id"] == .text(item.item.id))
    #expect(itemRow["name"] == .text("Фонарь"))
    #expect(itemRow["quantity"] == .integer(1))

    #expect(snapshot.filePaths.count == 4)
    for path in snapshot.filePaths {
      #expect(path.hasPrefix("photos/") || path.hasPrefix("thumbs/"))
      let source = try layout.fileURL(forRelativePath: path)
      let copy = snapshot.fileURL(for: path)
      #expect(FileManager.default.fileExists(atPath: copy.path))
      #expect(try Data(contentsOf: copy) == (try Data(contentsOf: source)))
    }
    #expect(!snapshot.filePaths.contains("photos/orphan.jpg"))

    let topLevel = try FileManager.default.contentsOfDirectory(
      atPath: snapshot.directoryURL.path
    ).sorted()
    #expect(topLevel == ["photos", "thumbs"])
    for forbidden in ["inventory.db", "_safety", "logs", "_tmp", ".inventory.lock"] {
      let forbiddenURL = snapshot.directoryURL.appendingPathComponent(forbidden)
      #expect(!FileManager.default.fileExists(atPath: forbiddenURL.path))
    }

    snapshot.discard()
    #expect(!FileManager.default.fileExists(atPath: snapshot.directoryURL.path))
  }

  @Test("Замена фото после снимка не портит уже снятую копию")
  func laterPhotoReplacementDoesNotAffectSnapshot() throws {
    let snapshotRoot = try TestSupport.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: snapshotRoot) }

    let session = try TestSupport.makeSession().0
    let layout = session.layout
    defer {
      session.close()
      try? FileManager.default.removeItem(at: layout.rootURL)
    }

    let item = try TestSupport.createItem(session, name: "Лампа")
    let oldPhotoFile = item.item.photoFile
    let oldThumbFile = item.item.thumbFile

    let service = BackupSnapshotService(
      database: session.database,
      layout: layout,
      gate: session.writeGate,
      temporaryRoot: snapshotRoot
    )
    let snapshot = try service.makeSnapshot()
    defer { snapshot.discard() }

    let oldPhotoBytes = try Data(contentsOf: snapshot.fileURL(for: oldPhotoFile))

    let newPhoto = ProcessedPhoto(
      photoBytes: Data([0xFF, 0xD8, 0xFF, 0xE0, 0xAA, 0xBB]),
      thumbBytes: Data([0xFF, 0xD8, 0xFF, 0xE0, 0xCC]),
      width: 100,
      height: 80,
      thumbWidth: 40,
      thumbHeight: 32,
      originalWidth: 200,
      originalHeight: 160
    )
    _ = try session.items.updateDetails(
      ItemDetailsUpdate(
        id: item.item.id,
        name: item.item.name,
        description: item.item.description,
        notes: item.item.notes,
        quantity: item.item.quantity,
        placeId: item.item.placeId,
        tags: [],
        newPhoto: newPhoto
      )
    )

    let oldPhotoURL = try layout.fileURL(forRelativePath: oldPhotoFile)
    let oldThumbURL = try layout.fileURL(forRelativePath: oldThumbFile)
    #expect(!FileManager.default.fileExists(atPath: oldPhotoURL.path))
    #expect(!FileManager.default.fileExists(atPath: oldThumbURL.path))
    #expect(try Data(contentsOf: snapshot.fileURL(for: oldPhotoFile)) == oldPhotoBytes)
    #expect(FileManager.default.fileExists(atPath: snapshot.fileURL(for: oldThumbFile).path))

    let updated = try session.items.get(item.item.id)
    #expect(updated.item.photoFile != oldPhotoFile)
    #expect(!snapshot.filePaths.contains(updated.item.photoFile))
  }

  @Test("Снимок блокирует пересекающуюся запись до своего завершения")
  func snapshotBlocksConcurrentWrite() throws {
    let snapshotRoot = try TestSupport.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: snapshotRoot) }

    let session = try TestSupport.makeSession().0
    let layout = session.layout
    defer {
      session.close()
      try? FileManager.default.removeItem(at: layout.rootURL)
    }
    let item = try TestSupport.createItem(session, name: "Фонарь")
    let oldPhotoFile = item.item.photoFile
    let oldPhotoURL = try layout.fileURL(forRelativePath: oldPhotoFile)
    let oldPhotoBytes = try Data(contentsOf: oldPhotoURL)

    let clock = BlockingSnapshotClock()
    let service = BackupSnapshotService(
      database: session.database,
      layout: layout,
      gate: session.writeGate,
      clock: clock,
      temporaryRoot: snapshotRoot
    )

    let snapshotDone = DispatchSemaphore(value: 0)
    let snapshotResult = ResultBox<BackupSnapshot>()
    DispatchQueue.global().async {
      snapshotResult.set(Result { try service.makeSnapshot() })
      snapshotDone.signal()
    }
    #expect(clock.waitUntilEntered())

    let writeStarted = DispatchSemaphore(value: 0)
    let writeDone = DispatchSemaphore(value: 0)
    let writeResult = ResultBox<ItemDetails>()
    DispatchQueue.global().async {
      writeStarted.signal()
      writeResult.set(
        Result {
          try session.items.updateDetails(
            ItemDetailsUpdate(
              id: item.item.id,
              name: item.item.name,
              description: item.item.description,
              notes: item.item.notes,
              quantity: item.item.quantity,
              placeId: item.item.placeId,
              tags: [],
              newPhoto: ProcessedPhoto(
                photoBytes: Data([0xFF, 0xD8, 0xFF, 0xE0, 0xAA, 0xBB]),
                thumbBytes: Data([0xFF, 0xD8, 0xFF, 0xE0, 0xCC]),
                width: 100,
                height: 80,
                thumbWidth: 40,
                thumbHeight: 32,
                originalWidth: 200,
                originalHeight: 160
              )
            )
          )
        })
      writeDone.signal()
    }
    #expect(writeStarted.wait(timeout: .now() + 2) == .success)
    #expect(writeDone.wait(timeout: .now() + 0.2) == .timedOut)

    clock.allowSnapshotToFinish()
    #expect(snapshotDone.wait(timeout: .now() + 3) == .success)
    #expect(writeDone.wait(timeout: .now() + 3) == .success)

    let snapshot = try snapshotResult.get()
    defer { snapshot.discard() }
    let updated = try writeResult.get()

    let itemRow = try #require(snapshot.table(named: "items")?.rows.first)
    #expect(itemRow["photo_file"] == .text(oldPhotoFile))
    #expect(try Data(contentsOf: snapshot.fileURL(for: oldPhotoFile)) == oldPhotoBytes)
    #expect(updated.item.photoFile != oldPhotoFile)
    #expect(!FileManager.default.fileExists(atPath: oldPhotoURL.path))
  }

  @Test("Ошибка снимка освобождает гейт и удаляет временную папку")
  func failedSnapshotCleansUpAndReleasesGate() throws {
    let snapshotRoot = try TestSupport.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: snapshotRoot) }

    let session = try TestSupport.makeSession().0
    let layout = session.layout
    defer {
      session.close()
      try? FileManager.default.removeItem(at: layout.rootURL)
    }

    let item = try TestSupport.createItem(session, name: "Лампа")
    try FileManager.default.removeItem(
      at: layout.fileURL(forRelativePath: item.item.photoFile))

    let service = BackupSnapshotService(
      database: session.database,
      layout: layout,
      gate: session.writeGate,
      temporaryRoot: snapshotRoot
    )

    do {
      _ = try service.makeSnapshot()
      Issue.record("Ожидалась ошибка backupIntegrityFailed")
    } catch let error as AppException {
      #expect(error.code == .backupIntegrityFailed)
    }

    let leftovers = try FileManager.default.contentsOfDirectory(atPath: snapshotRoot.path)
    #expect(leftovers.isEmpty)

    // Гейт свободен: обычная запись после ошибки проходит.
    try session.database.write { db in
      try db.execute(sql: "INSERT INTO settings (key, value) VALUES ('probe', 'ok')")
    }
    let probe = try session.database.read { db in
      try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = 'probe'")
    }
    #expect(probe == "ok")
  }

  @Test("Сбои снимка не оставляют временных папок при повторных попытках")
  func repeatedFailuresLeaveNoTemporaryDirectories() throws {
    let snapshotRoot = try TestSupport.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: snapshotRoot) }

    let session = try TestSupport.makeSession().0
    let layout = session.layout
    defer {
      session.close()
      try? FileManager.default.removeItem(at: layout.rootURL)
    }

    let item = try TestSupport.createItem(session, name: "Стол")
    try FileManager.default.removeItem(
      at: layout.fileURL(forRelativePath: item.item.thumbFile))

    let service = BackupSnapshotService(
      database: session.database,
      layout: layout,
      gate: session.writeGate,
      temporaryRoot: snapshotRoot
    )

    for _ in 0..<3 {
      #expect(throws: AppException.self) {
        _ = try service.makeSnapshot()
      }
      #expect(try FileManager.default.contentsOfDirectory(atPath: snapshotRoot.path).isEmpty)
    }
  }
}

private enum ResultBoxError: Error {
  case missingResult
}

/// Часы, которые останавливают сборку снимка в начале: тест успевает
/// запустить конкурирующую запись и убедиться, что гейт её не пропускает.
private final class BlockingSnapshotClock: Clock, @unchecked Sendable {
  private let entered = DispatchSemaphore(value: 0)
  private let release = DispatchSemaphore(value: 0)

  func nowMilliseconds() -> Int64 {
    entered.signal()
    release.wait()
    return 1_700_000_000_000
  }

  func waitUntilEntered() -> Bool {
    entered.wait(timeout: .now() + 2) == .success
  }

  func allowSnapshotToFinish() {
    release.signal()
  }
}

private final class ResultBox<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<Value, Error>?

  func set(_ value: Result<Value, Error>) {
    lock.lock()
    result = value
    lock.unlock()
  }

  func get() throws -> Value {
    lock.lock()
    let value = result
    lock.unlock()
    guard let value else { throw ResultBoxError.missingResult }
    return try value.get()
  }
}
