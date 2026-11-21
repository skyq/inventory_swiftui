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
    clock: any Clock = FixedTestClock(value: 1_700_000_000_000),
    makeMigrator: @escaping () -> DatabaseMigrator = Schema.makeMigrator
  ) -> StorageCoordinator {
    StorageCoordinator(
      preferences: preferences,
      logger: NullLogger(),
      clock: clock,
      ids: SequentialTestIds(prefix: "id"),
      targetVersion: targetVersion,
      makeMigrator: makeMigrator
    )
  }

  static func makeSession(
    clock: any Clock = FixedTestClock(value: 1_700_000_000_000)
  ) throws -> (StorageSession, URL) {
    let root = try temporaryDirectory()
    let session = try makeCoordinator(clock: clock).createNew(root.path)
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

  @discardableResult
  static func createPlace(
    _ session: StorageSession,
    name: String,
    parentId: String? = nil
  ) throws -> Place {
    try session.places.create(
      PlaceCreate(name: name, description: "", parentId: parentId, photo: makePhoto())
    )
  }

  @discardableResult
  static func createItem(
    _ session: StorageSession,
    name: String,
    statusId: String? = nil,
    placeId: String? = nil,
    tags: [String] = []
  ) throws -> ItemDetails {
    try session.items.create(
      ItemCreate(
        name: name,
        placeId: placeId,
        statusId: statusId,
        tags: tags,
        photo: makePhoto()
      )
    )
  }

  static func statusId(_ session: StorageSession, named name: String) throws -> String {
    let statuses = try session.statuses.list(includeArchived: true)
    guard let status = statuses.first(where: { $0.name == name }) else {
      throw AppException(.validationNotFound, params: ["entity": .string("status")])
    }
    return status.id
  }
}

struct FixedTestClock: Clock {
  let value: Int64
  func nowMilliseconds() -> Int64 { value }
}

final class MutableTestClock: Clock, @unchecked Sendable {
  private let lock = NSLock()
  private var value: Int64

  init(value: Int64 = 1_700_000_000_000) {
    self.value = value
  }

  func nowMilliseconds() -> Int64 {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func advance(by milliseconds: Int64) {
    lock.lock()
    value += milliseconds
    lock.unlock()
  }

  func set(_ newValue: Int64) {
    lock.lock()
    value = newValue
    lock.unlock()
  }
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
