import Foundation
import GRDB
import InventoryCore
import Testing

@Suite("Экспорт, импорт, откат, перенос и восстановление")
struct StorageMaintenanceTests {
  private let clockValue: Int64 = 1_700_000_000_000

  private struct Store {
    let coordinator: StorageCoordinator
    let preferences: InMemoryPreferencesStore
    let root: URL
    let work: URL
  }

  private func makeCoordinator(
    preferences: InMemoryPreferencesStore = InMemoryPreferencesStore()
  ) -> StorageCoordinator {
    StorageCoordinator(
      preferences: preferences,
      clock: FixedTestClock(value: clockValue),
      ids: UuidV4IdGenerator()
    )
  }

  private func makeStore(itemNames: [String]) throws -> (Store, StorageSession) {
    let preferences = InMemoryPreferencesStore()
    let base = try TestSupport.temporaryDirectory()
    let coordinator = makeCoordinator(preferences: preferences)
    let session = try coordinator.createNew(base.appendingPathComponent("store").path)
    let place = try TestSupport.createPlace(session, name: "Кладовая")
    for name in itemNames {
      try TestSupport.createItem(session, name: name, placeId: place.id)
    }
    let work = try TestSupport.temporaryDirectory()
    return (
      Store(coordinator: coordinator, preferences: preferences, root: base, work: work),
      session
    )
  }

  private func names(_ session: StorageSession) throws -> [String] {
    try session.items.list(GalleryQuery()).map { $0.item.name }.sorted()
  }

  private func exportArchive(_ session: StorageSession, store: Store) throws -> URL {
    let destination = try TestSupport.temporaryDirectory()
    let maintenance = store.coordinator.makeMaintenance(
      appVersion: "1.0", temporaryRoot: store.work)
    return try maintenance.export(session: session, to: destination)
  }

  private func cleanUp(_ store: Store) {
    try? FileManager.default.removeItem(at: store.root)
    try? FileManager.default.removeItem(at: store.work)
  }

  // MARK: - Экспорт

  @Test("Экспорт записывает дату только после успешной публикации архива")
  func exportUpdatesDateOnlyOnSuccess() throws {
    let (store, session) = try makeStore(itemNames: ["Лампа"])
    defer {
      session.close()
      cleanUp(store)
    }
    let maintenance = store.coordinator.makeMaintenance(
      appVersion: "1.0", temporaryRoot: store.work)

    #expect(store.preferences.int(forKey: PreferenceKeys.backupLastExportMs) == nil)

    let missing = store.work.appendingPathComponent("нет-такой-папки")
    #expect(throws: AppException.self) {
      try maintenance.export(session: session, to: missing)
    }
    #expect(store.preferences.int(forKey: PreferenceKeys.backupLastExportMs) == nil)

    let destination = try TestSupport.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: destination) }
    let url = try maintenance.export(session: session, to: destination)
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(store.preferences.int(forKey: PreferenceKeys.backupLastExportMs) == Int(clockValue))
  }

  // MARK: - Импорт

  @Test("Импорт заменяет данные и сохраняет прежнее состояние в before-import")
  func importReplacesDataAndKeepsSafetyCopy() throws {
    let (store, session) = try makeStore(itemNames: ["Лампа"])
    defer { cleanUp(store) }
    let archive = try exportArchive(session, store: store)
    _ = try TestSupport.createItem(session, name: "Новая вещь")
    #expect(try names(session).count == 2)

    let maintenance = store.coordinator.makeMaintenance(
      appVersion: "1.0", temporaryRoot: store.work)
    let validated = try maintenance.prepareImport(archive: archive)
    let outcome = maintenance.importBackup(
      validated, confirmedItemCount: validated.itemCount, session: session)

    let restored = try #require(outcome.session)
    defer { restored.close() }
    #expect(outcome.error == nil)
    #expect(try names(restored) == ["Лампа"])

    let safety = restored.layout.beforeImportURL.appendingPathComponent("inventory.db")
    #expect(FileManager.default.fileExists(atPath: safety.path))
    let safetyQueue = try DatabaseQueue(path: safety.path)
    let safetyItems = try safetyQueue.read {
      try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM items")
    }
    try safetyQueue.close()
    #expect(safetyItems == 2)

    #expect(
      !FileManager.default.fileExists(atPath: RecoveryJournal(layout: restored.layout).url.path))
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: restored.layout.tmpURL.path).isEmpty)
  }

  @Test("Неверное подтверждение числа вещей не меняет данные")
  func confirmationMismatchKeepsData() throws {
    let (store, session) = try makeStore(itemNames: ["Лампа"])
    defer { cleanUp(store) }
    let archive = try exportArchive(session, store: store)
    let maintenance = store.coordinator.makeMaintenance(
      appVersion: "1.0", temporaryRoot: store.work)
    let validated = try maintenance.prepareImport(archive: archive)

    let outcome = maintenance.importBackup(validated, confirmedItemCount: 5, session: session)
    let kept = try #require(outcome.session)
    defer { kept.close() }
    #expect(outcome.error?.code == .importFailed)
    #expect(try names(kept) == ["Лампа"])
    #expect(!FileManager.default.fileExists(atPath: kept.layout.beforeImportURL.path))
  }

  @Test("Сбой после замены откатывает данные из копии до импорта")
  func failedImportRestoresPreviousState() throws {
    let (store, session) = try makeStore(itemNames: ["Лампа"])
    defer { cleanUp(store) }
    let archive = try exportArchive(session, store: store)
    _ = try TestSupport.createItem(session, name: "Текущая")
    let layout = session.layout
    session.close()

    let failing = store.coordinator.makeMaintenance(
      appVersion: "1.0",
      temporaryRoot: store.work,
      checkpoint: { phase in
        if phase == .verifying { throw AppException(.storageCorrupt) }
      }
    )
    let reopened = try store.coordinator.openExisting(layout.rootPath)
    let validated = try failing.prepareImport(archive: archive)
    let outcome = failing.importBackup(
      validated, confirmedItemCount: validated.itemCount, session: reopened)

    let kept = try #require(outcome.session)
    defer { kept.close() }
    #expect(outcome.error != nil)
    #expect(try names(kept).count == 2)
    #expect(try names(kept).contains("Текущая"))
    #expect(!FileManager.default.fileExists(atPath: RecoveryJournal(layout: layout).url.path))
    #expect(!FileManager.default.fileExists(atPath: layout.beforeImportURL.path + ".new"))
  }

  @Test("Прерванный импорт восстанавливается при следующем открытии")
  func interruptedImportRecoversOnOpen() throws {
    let (store, session) = try makeStore(itemNames: ["Лампа", "Стол"])
    defer { cleanUp(store) }
    let layout = session.layout
    session.close()

    // Имитация аварии после замены: копия до импорта есть, живые файлы перенесены.
    let fileManager = FileManager.default
    let backup = layout.beforeImportURL
    try fileManager.createDirectory(at: backup, withIntermediateDirectories: true)
    let queue = try DatabaseQueue(path: layout.databasePath)
    try queue.inDatabase { db in
      let target = backup.appendingPathComponent("inventory.db").path
      try db.execute(sql: "VACUUM INTO '\(target)'")
    }
    try queue.close()
    try fileManager.copyItem(at: layout.photosURL, to: backup.appendingPathComponent("photos"))
    try fileManager.copyItem(at: layout.thumbsURL, to: backup.appendingPathComponent("thumbs"))

    let opId = "crash-1"
    let old = layout.tmpURL.appendingPathComponent("old-\(opId)")
    try fileManager.createDirectory(at: old, withIntermediateDirectories: true)
    try fileManager.moveItem(at: layout.databaseURL, to: old.appendingPathComponent("inventory.db"))
    try fileManager.removeItem(at: layout.photosURL)
    try RecoveryJournal(layout: layout).write(
      RecoveryRecord(
        operation: .importData, opId: opId, phase: .swapStarted,
        startedAt: clockValue, updatedAt: clockValue, root: layout.rootPath,
        backup: backup.path))

    let recovered = try store.coordinator.openExisting(layout.rootPath)
    defer { recovered.close() }
    #expect(try names(recovered) == ["Лампа", "Стол"])
    #expect(!fileManager.fileExists(atPath: RecoveryJournal(layout: layout).url.path))
    #expect(!fileManager.fileExists(atPath: old.path))
  }

  // MARK: - Откат

  @Test("Откат возвращает состояние до импорта и повторяется идемпотентно")
  func rollbackIsIdempotent() throws {
    let (store, session) = try makeStore(itemNames: ["Лампа"])
    defer { cleanUp(store) }
    let archive = try exportArchive(session, store: store)
    _ = try TestSupport.createItem(session, name: "Вторая")
    let maintenance = store.coordinator.makeMaintenance(
      appVersion: "1.0", temporaryRoot: store.work)
    let validated = try maintenance.prepareImport(archive: archive)
    let imported = maintenance.importBackup(
      validated, confirmedItemCount: validated.itemCount, session: session)
    let afterImport = try #require(imported.session)
    #expect(try names(afterImport) == ["Лампа"])

    let first = maintenance.rollbackImport(session: afterImport)
    let rolled = try #require(first.session)
    #expect(first.error == nil)
    #expect(try names(rolled) == ["Вторая", "Лампа"])

    let second = maintenance.rollbackImport(session: rolled)
    let again = try #require(second.session)
    defer { again.close() }
    #expect(second.error == nil)
    #expect(try names(again) == ["Вторая", "Лампа"])
  }

  @Test("Откат без копии до импорта отклоняется, данные не меняются")
  func rollbackWithoutCopyIsRejected() throws {
    let (store, session) = try makeStore(itemNames: ["Лампа"])
    defer {
      session.close()
      cleanUp(store)
    }
    let maintenance = store.coordinator.makeMaintenance(
      appVersion: "1.0", temporaryRoot: store.work)
    let outcome = maintenance.rollbackImport(session: session)
    #expect(outcome.error?.code == .validationNotFound)
    #expect(outcome.session === session)
  }

  // MARK: - Перенос

  @Test("Перенос копирует данные в пустую папку и переключает хранилище")
  func moveCopiesAndSwitches() throws {
    let (store, session) = try makeStore(itemNames: ["Лампа"])
    defer { cleanUp(store) }
    let target = store.work.appendingPathComponent("новая папка", isDirectory: true)
    let sourcePath = session.layout.rootPath
    let maintenance = store.coordinator.makeMaintenance(
      appVersion: "1.0", temporaryRoot: store.work)

    let outcome = maintenance.moveStore(session: session, to: target)
    let moved = try #require(outcome.session)
    defer { moved.close() }
    #expect(outcome.error == nil)
    #expect(moved.layout.rootPath == StoreLayout(rootURL: target).rootPath)
    #expect(try names(moved) == ["Лампа"])
    #expect(
      store.preferences.string(forKey: PreferenceKeys.activeStorePath) == moved.layout.rootPath)
    #expect(FileManager.default.fileExists(atPath: sourcePath + "/inventory.db"))
    #expect(!FileManager.default.fileExists(atPath: RecoveryJournal(layout: moved.layout).url.path))
    #expect(
      !FileManager.default.fileExists(
        atPath: moved.layout.tmpURL.appendingPathComponent("move-x").path))
  }

  @Test("Перенос отклоняет непустую папку, путь внутри хранилища и тот же путь")
  func moveRejectsUnsafeTargets() throws {
    let (store, session) = try makeStore(itemNames: ["Лампа"])
    defer {
      session.close()
      cleanUp(store)
    }
    let maintenance = store.coordinator.makeMaintenance(
      appVersion: "1.0", temporaryRoot: store.work)

    let nonEmpty = store.work.appendingPathComponent("занято", isDirectory: true)
    try FileManager.default.createDirectory(at: nonEmpty, withIntermediateDirectories: true)
    try Data("чужое".utf8).write(to: nonEmpty.appendingPathComponent("file.txt"))

    let inside = session.layout.rootURL.appendingPathComponent("внутри", isDirectory: true)
    let samePath = session.layout.rootURL

    for target in [nonEmpty, inside, samePath] {
      let outcome = maintenance.moveStore(session: session, to: target)
      #expect(outcome.error != nil, "\(target.lastPathComponent)")
      #expect(outcome.session === session)
    }
    #expect(try Data(contentsOf: nonEmpty.appendingPathComponent("file.txt")) == Data("чужое".utf8))
    #expect(try names(session) == ["Лампа"])
  }

  @Test("Сбой переноса удаляет следы в цели и возвращает прежнее хранилище")
  func failedMoveKeepsSource() throws {
    let (store, session) = try makeStore(itemNames: ["Лампа"])
    defer { cleanUp(store) }
    let target = store.work.appendingPathComponent("цель", isDirectory: true)
    let sourceRoot = session.layout.rootPath
    let failing = store.coordinator.makeMaintenance(
      appVersion: "1.0",
      temporaryRoot: store.work,
      checkpoint: { phase in
        if phase == .copied { throw AppException(.backupIntegrityFailed) }
      }
    )

    let outcome = failing.moveStore(session: session, to: target)
    let kept = try #require(outcome.session)
    defer { kept.close() }
    #expect(outcome.error != nil)
    #expect(kept.layout.rootPath == sourceRoot)
    #expect(try names(kept) == ["Лампа"])
    #expect(!FileManager.default.fileExists(atPath: target.path))
    #expect(store.preferences.string(forKey: PreferenceKeys.activeStorePath) == sourceRoot)
  }

  // MARK: - Переключение

  @Test("Переключение на несуществующую папку оставляет текущее хранилище")
  func switchToMissingKeepsCurrent() throws {
    let (store, session) = try makeStore(itemNames: ["Лампа"])
    defer {
      session.close()
      cleanUp(store)
    }
    let maintenance = store.coordinator.makeMaintenance(
      appVersion: "1.0", temporaryRoot: store.work)
    let missing = store.work.appendingPathComponent("нет").path

    let outcome = maintenance.switchStore(session: session, to: missing)
    #expect(outcome.error != nil)
    #expect(outcome.session === session)
    #expect(try names(session) == ["Лампа"])
  }

  @Test("Переключение на другое существующее хранилище закрывает прежнее")
  func switchToExistingStore() throws {
    let (store, session) = try makeStore(itemNames: ["Лампа"])
    defer { cleanUp(store) }
    let other = try store.coordinator.createNew(
      store.work.appendingPathComponent("другое").path)
    other.close()

    let maintenance = store.coordinator.makeMaintenance(
      appVersion: "1.0", temporaryRoot: store.work)
    let outcome = maintenance.switchStore(session: session, to: other.layout.rootPath)
    let opened = try #require(outcome.session)
    defer { opened.close() }
    #expect(outcome.error == nil)
    #expect(opened.layout.rootPath == other.layout.rootPath)
  }

  // MARK: - Копии безопасности

  @Test("Очистка копии блокируется активным журналом и не трогает данные")
  func clearingSafetyCopyRespectsJournal() throws {
    let (store, session) = try makeStore(itemNames: ["Лампа"])
    defer {
      session.close()
      cleanUp(store)
    }
    let layout = session.layout
    try FileManager.default.createDirectory(
      at: layout.beforeImportURL, withIntermediateDirectories: true)
    try RecoveryJournal(layout: layout).write(
      RecoveryRecord(
        operation: .importData, opId: "busy", phase: .validating,
        startedAt: clockValue, updatedAt: clockValue, root: layout.rootPath))

    let maintenance = store.coordinator.makeMaintenance(
      appVersion: "1.0", temporaryRoot: store.work)
    #expect(throws: AppException.self) {
      try maintenance.clearSafetyCopy(.beforeImport, session: session)
    }
    #expect(FileManager.default.fileExists(atPath: layout.beforeImportURL.path))

    try RecoveryJournal(layout: layout).remove()
    try maintenance.clearSafetyCopy(.beforeImport, session: session)
    #expect(!FileManager.default.fileExists(atPath: layout.beforeImportURL.path))
    #expect(try names(session) == ["Лампа"])
  }

  @Test("Журнал читается после записи и сообщает о повреждении")
  func journalRoundTripAndCorruption() throws {
    let (store, session) = try makeStore(itemNames: [])
    defer {
      session.close()
      cleanUp(store)
    }
    let layout = session.layout
    let journal = RecoveryJournal(layout: layout)
    let record = RecoveryRecord(
      operation: .move, opId: "op-1", phase: .copying,
      startedAt: clockValue, updatedAt: clockValue + 5, root: layout.rootPath,
      target: "/tmp/target", details: ["items_count": 3])
    try journal.write(record)
    #expect(try journal.read() == record)

    try Data("{ не json".utf8).write(to: journal.url)
    #expect(throws: AppException.self) { try journal.read() }
  }
}

@Suite("Напоминание о бэкапе и облачные папки")
struct BackupReminderTests {
  private let day: Int64 = 24 * 60 * 60 * 1000

  @Test("Без экспорта напоминание сразу; после экспорта — строго больше 30 суток")
  func reminderBoundary() {
    #expect(BackupReminder.isDue(enabled: true, lastExportMs: nil, now: 0))
    let last: Int64 = 1_000_000_000_000
    #expect(!BackupReminder.isDue(enabled: true, lastExportMs: last, now: last + 29 * day))
    #expect(!BackupReminder.isDue(enabled: true, lastExportMs: last, now: last + 30 * day))
    #expect(BackupReminder.isDue(enabled: true, lastExportMs: last, now: last + 30 * day + 1))
    #expect(BackupReminder.isDue(enabled: true, lastExportMs: last, now: last + 31 * day))
  }

  @Test("Отключённое напоминание не показывается и настройка сохраняется")
  func disabledReminderPersists() {
    let preferences = InMemoryPreferencesStore()
    #expect(BackupReminder.isEnabled(preferences))
    BackupReminder.setEnabled(false, in: preferences)
    #expect(!BackupReminder.isEnabled(preferences))
    #expect(!BackupReminder.isDue(enabled: false, lastExportMs: nil, now: 0))
  }

  @Test("Облачные папки распознаются, локальные — нет")
  func cloudWarning() {
    #expect(
      StorageLocationWarning.cloudProviderName(
        for: "/Users/a/Library/Mobile Documents/com~apple~CloudDocs/Inv") == "iCloud Drive")
    #expect(
      StorageLocationWarning.cloudProviderName(
        for: "/Users/a/Library/CloudStorage/GoogleDrive-a@b.c/My Drive/Inv") == "Google Drive")
    #expect(
      StorageLocationWarning.cloudProviderName(
        for: "/Users/a/Library/CloudStorage/OneDrive-Personal/Inv") == "OneDrive")
    #expect(StorageLocationWarning.cloudProviderName(for: "/Users/a/Dropbox/Inv") == "Dropbox")
    #expect(
      StorageLocationWarning.cloudProviderName(
        for: "/Users/a/Library/Application Support/Inventory") == nil)
  }
}
