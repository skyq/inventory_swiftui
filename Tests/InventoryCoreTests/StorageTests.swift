import Foundation
import GRDB
import InventoryCore
import Testing

@Suite("Хранилище и блокировка")
struct StorageTests {
  @Test("createNew создаёт структуру папки и БД")
  func createsStoreStructure() throws {
    let root = try TestSupport.temporaryDirectory()
    let session = try TestSupport.makeCoordinator().createNew(root.path)
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let layout = session.layout
    #expect(FileManager.default.fileExists(atPath: layout.databasePath))
    for url in [
      layout.photosURL, layout.thumbsURL, layout.logsURL, layout.safetyURL, layout.tmpURL,
    ] {
      var isDirectory: ObjCBool = false
      #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
      #expect(isDirectory.boolValue)
    }
  }

  @Test("openExisting не создаёт пустую базу для пропавшей папки")
  func refusesMissingStore() throws {
    let root = try TestSupport.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let missing = root.appendingPathComponent("missing", isDirectory: true)

    #expect(throws: AppException.self) {
      try TestSupport.makeCoordinator().openExisting(missing.path)
    }
    #expect(!FileManager.default.fileExists(atPath: missing.path))
  }

  @Test("Повреждённая база не превращается в пустую")
  func refusesCorruptDatabase() throws {
    let root = try TestSupport.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let databaseURL = root.appendingPathComponent("inventory.db")
    try Data("not a database at all".utf8).write(to: databaseURL)
    let coordinator = TestSupport.makeCoordinator()

    do {
      _ = try coordinator.openExisting(root.path)
      Issue.record("Ожидалась ошибка storageCorrupt")
    } catch let error as AppException {
      #expect(error.code == .storageCorrupt || error.code == .storageUnavailable)
    }
    #expect(FileManager.default.fileExists(atPath: databaseURL.path))

    // Неудачное открытие освобождает блокировку: повтор даёт ту же ошибку, а не storageBusy.
    do {
      _ = try coordinator.openExisting(root.path)
      Issue.record("Ожидалась повторная ошибка повреждения")
    } catch let error as AppException {
      #expect(error.code == .storageCorrupt || error.code == .storageUnavailable)
    }
  }

  @Test("База новее приложения отклоняется")
  func refusesNewerSchema() throws {
    let root = try TestSupport.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("inventory.db").path
    let queue = try DatabaseQueue(path: path)
    try queue.write { db in
      try db.execute(sql: "PRAGMA user_version = 99")
    }
    try queue.close()

    do {
      _ = try TestSupport.makeCoordinator().openExisting(root.path)
      Issue.record("Ожидалась ошибка storageNewerSchema")
    } catch let error as AppException {
      #expect(error.code == .storageNewerSchema)
      #expect(error.int("found") == 99)
      #expect(error.int("supported") == 2)
    }
  }

  @Test("Второй экземпляр не открывает то же хранилище; после close открытие возможно")
  func preventsConcurrentOpen() throws {
    let root = try TestSupport.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let preferences = InMemoryPreferencesStore()
    let coordinator = TestSupport.makeCoordinator(preferences: preferences)
    let first = try coordinator.createNew(root.path)

    do {
      _ = try coordinator.openExisting(root.path)
      Issue.record("Ожидалась ошибка storageBusy")
    } catch let error as AppException {
      #expect(error.code == .storageBusy)
    }

    first.close()
    let second = try coordinator.openExisting(root.path)
    second.close()
  }

  @Test("flock не отдаёт папку другому процессу")
  func lockIsCrossProcess() throws {
    let root = try TestSupport.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let layout = StoreLayout(rootURL: root)
    try layout.createDirectories()

    let lock = try StorageLock.acquire(layout: layout)
    #expect(try externalLockSucceeds(layout.lockURL.path) == false)
    lock.release()
    #expect(try externalLockSucceeds(layout.lockURL.path) == true)
  }

  @Test("Символическая ссылка на ту же папку не обходит блокировку")
  func symlinkCannotBypassLock() throws {
    let root = try TestSupport.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let real = root.appendingPathComponent("real", isDirectory: true)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    let link = root.appendingPathComponent("link", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

    let lock = try StorageLock.acquire(layout: StoreLayout(rootURL: real))
    do {
      _ = try StorageLock.acquire(layout: StoreLayout(rootURL: link))
      Issue.record("Ожидалась ошибка storageBusy через символическую ссылку")
    } catch let error as AppException {
      #expect(error.code == .storageBusy)
    }
    lock.release()
  }

  @Test("openOrCreateDefault открывает сохранённый путь и не создаёт пустую базу вместо пропавшего")
  func followsSavedPath() throws {
    let root = try TestSupport.temporaryDirectory()
    let preferences = InMemoryPreferencesStore()
    let coordinator = TestSupport.makeCoordinator(preferences: preferences)
    let created = try coordinator.createNew(root.path)
    created.close()
    preferences.setString(root.path, forKey: PreferenceKeys.activeStorePath)

    let opened = try coordinator.openOrCreateDefault()
    #expect(opened.layout.rootPath == root.path)
    opened.close()

    let missing = root.appendingPathComponent("gone", isDirectory: true)
    preferences.setString(missing.path, forKey: PreferenceKeys.activeStorePath)
    #expect(throws: AppException.self) {
      try coordinator.openOrCreateDefault()
    }
    #expect(!FileManager.default.fileExists(atPath: missing.path))

    try? FileManager.default.removeItem(at: root)
  }

  private func externalLockSucceeds(_ lockPath: String) throws -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    process.arguments = [
      "-e",
      "open(my $f, '<', $ARGV[0]) or exit 2; flock($f, 2 | 4) or exit 1; exit 0;",
      lockPath,
    ]
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus == 0
  }
}
