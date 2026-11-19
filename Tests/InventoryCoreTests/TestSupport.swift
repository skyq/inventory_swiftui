import Foundation
import GRDB
import InventoryCore

enum TestSupport {
  static func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("InventoryTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  static func makeCoordinator(
    preferences: InMemoryPreferencesStore = InMemoryPreferencesStore(),
    targetVersion: Int = Schema.version,
    makeMigrator: @escaping () -> DatabaseMigrator = Schema.makeMigrator
  ) -> StorageCoordinator {
    StorageCoordinator(
      preferences: preferences,
      logger: NullLogger(),
      clock: FixedTestClock(value: 1_700_000_000_000),
      ids: SequentialTestIds(prefix: "id"),
      targetVersion: targetVersion,
      makeMigrator: makeMigrator
    )
  }

  static func makeSession() throws -> (StorageSession, URL) {
    let root = try temporaryDirectory()
    let session = try makeCoordinator().createNew(root.path)
    return (session, root)
  }

  static func makePhoto() -> ProcessedPhoto {
    let photoBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02, 0x03])
    let thumbBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x04, 0x05])
    return ProcessedPhoto(
      photoBytes: photoBytes,
      thumbBytes: thumbBytes,
      width: 100,
      height: 80,
      thumbWidth: 40,
      thumbHeight: 32,
      originalWidth: 200,
      originalHeight: 160
    )
  }

  static func rowCount(_ database: InventoryDatabase, table: String) throws -> Int {
    try database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
    }
  }
}

struct FixedTestClock: Clock {
  let value: Int64
  func nowMilliseconds() -> Int64 { value }
}

final class SequentialTestIds: IdGenerator, @unchecked Sendable {
  private let lock = NSLock()
  private var counter = 0
  private let prefix: String

  init(prefix: String) {
    self.prefix = prefix
  }

  func next() -> String {
    lock.lock()
    defer { lock.unlock() }
    counter += 1
    return "\(prefix)-\(counter)"
  }
}
