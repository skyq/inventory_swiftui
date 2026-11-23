import Darwin
import Foundation
import GRDB

/// Фазы операций протокола (RECOVERY_PROTOCOL §5–§7).
public enum RecoveryPhase: String, Codable, Sendable {
  case started
  case validating
  case snapshotDone = "snapshot_done"
  case stagingReady = "staging_ready"
  case swapStarted = "swap_started"
  case verifying
  case restoring
  case copying
  case copied
  case switching
  case done
  case rolledBack = "rolled_back"

  public var isTerminal: Bool { self == .done || self == .rolledBack }
}

public enum RecoveryOperation: String, Codable, Sendable {
  case migration
  case importData = "import"
  case importRollback = "import_rollback"
  case move
  case `switch`
}

/// Единственная активная операция. `phase` — источник истины о прогрессе.
public struct RecoveryRecord: Codable, Equatable, Sendable {
  public var protocolVersion: Int
  public var operation: RecoveryOperation
  public var opId: String
  public var phase: RecoveryPhase
  public var startedAt: Int64
  public var updatedAt: Int64
  public var root: String
  public var backup: String?
  public var staging: String?
  public var target: String?
  public var durability: String
  public var details: [String: Int]

  public init(
    operation: RecoveryOperation,
    opId: String,
    phase: RecoveryPhase,
    startedAt: Int64,
    updatedAt: Int64,
    root: String,
    backup: String? = nil,
    staging: String? = nil,
    target: String? = nil,
    durability: String = "fsync",
    details: [String: Int] = [:]
  ) {
    self.protocolVersion = 1
    self.operation = operation
    self.opId = opId
    self.phase = phase
    self.startedAt = startedAt
    self.updatedAt = updatedAt
    self.root = root
    self.backup = backup
    self.staging = staging
    self.target = target
    self.durability = durability
    self.details = details
  }

  private enum CodingKeys: String, CodingKey {
    case protocolVersion = "protocol_version"
    case operation
    case opId = "op_id"
    case phase
    case startedAt = "started_at"
    case updatedAt = "updated_at"
    case root, backup, staging, target, durability, details
  }
}

/// Durable-журнал `_safety/recovery.json`: запись через tmp + fsync + rename + sync.
public final class RecoveryJournal: @unchecked Sendable {
  public let url: URL
  private let fileManager: FileManager

  public init(layout: StoreLayout, fileManager: FileManager = .default) {
    self.url = layout.safetyURL.appendingPathComponent("recovery.json")
    self.fileManager = fileManager
  }

  public func read() throws -> RecoveryRecord? {
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    do {
      return try JSONDecoder().decode(RecoveryRecord.self, from: Data(contentsOf: url))
    } catch {
      throw AppException(
        .storageCorrupt,
        params: ["path": .string(url.path)],
        debugMessage: "recovery journal is unreadable: \(error)"
      )
    }
  }

  public func write(_ record: RecoveryRecord) throws {
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var stored = record
    stored.updatedAt = max(record.updatedAt, record.startedAt)

    let data: Data
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
      data = try encoder.encode(stored)
    } catch {
      throw AppException(.ioError, debugMessage: "cannot encode recovery journal: \(error)")
    }

    let temporary = url.appendingPathExtension("tmp")
    do {
      try? fileManager.removeItem(at: temporary)
      guard fileManager.createFile(atPath: temporary.path, contents: nil) else {
        throw CocoaError(.fileWriteUnknown)
      }
      let handle = try FileHandle(forWritingTo: temporary)
      try handle.write(contentsOf: data)
      try handle.synchronize()
      try handle.close()
      guard rename(temporary.path, url.path) == 0 else {
        throw CocoaError(.fileWriteUnknown)
      }
    } catch {
      try? fileManager.removeItem(at: temporary)
      throw AppException(
        .ioError,
        params: ["path": .string(url.path)],
        debugMessage: "cannot write recovery journal: \(error)"
      )
    }
    // Без sync() после rename каталог может потерять запись при сбое питания.
    sync()
  }

  public func remove() throws {
    guard fileManager.fileExists(atPath: url.path) else { return }
    do {
      try fileManager.removeItem(at: url)
    } catch {
      throw AppException(
        .ioError,
        params: ["path": .string(url.path)],
        debugMessage: "cannot remove recovery journal: \(error)"
      )
    }
    sync()
  }
}

/// Копии данных для протокола: согласованная копия SQLite и копирование фото.
enum RecoveryCopy {
  /// `VACUUM INTO` после `wal_checkpoint(FULL)` (RECOVERY_PROTOCOL §4).
  static func databaseCopy(from sourceDatabase: String, to target: URL) throws {
    let fileManager = FileManager.default
    try? fileManager.removeItem(at: target)
    var configuration = InventoryDatabase.makeConfiguration()
    configuration.busyMode = .timeout(5)
    do {
      let queue = try DatabaseQueue(path: sourceDatabase, configuration: configuration)
      try queue.inDatabase { db in
        _ = try Row.fetchOne(db, sql: "PRAGMA wal_checkpoint(FULL)")
        let escaped = target.path.replacingOccurrences(of: "'", with: "''")
        try db.execute(sql: "VACUUM INTO '\(escaped)'")
      }
      try queue.close()
    } catch {
      try? fileManager.removeItem(at: target)
      throw AppException(
        .storageUnavailable,
        params: ["path": .string(target.path)],
        debugMessage: "cannot create consistent database copy: \(error)"
      )
    }

    do {
      let copy = try DatabaseQueue(
        path: target.path, configuration: InventoryDatabase.makeConfiguration())
      let integrity = try copy.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") }
      try copy.close()
      guard integrity == "ok" else {
        throw AppException(
          .storageCorrupt, debugMessage: "copy integrity_check: \(integrity ?? "")")
      }
    } catch {
      try? fileManager.removeItem(at: target)
      throw AppException(
        .storageCorrupt,
        params: ["path": .string(target.path)],
        debugMessage: "copy failed integrity check: \(error)"
      )
    }
    try syncFile(target)
  }

  /// Копирует все файлы каталога фото/превью; фото неизменяемы после записи.
  static func copyFiles(from source: URL, to target: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
    guard fileManager.fileExists(atPath: source.path) else { return }
    for name in try fileManager.contentsOfDirectory(atPath: source.path) {
      try fileManager.copyItem(
        at: source.appendingPathComponent(name),
        to: target.appendingPathComponent(name))
    }
  }

  static func syncFile(_ url: URL) throws {
    let handle = try FileHandle(forUpdating: url)
    try handle.synchronize()
    try handle.close()
  }
}

/// Раскладка копий: что относится к данным, что — к safety.
enum RecoveryFiles {
  static let databaseNames = ["inventory.db", "inventory.db-wal", "inventory.db-shm"]

  /// Удаляет текущие файлы данных корня (БД и журналы SQLite, фото, превью).
  static func removeLiveData(in root: StoreLayout, fileManager: FileManager) throws {
    for name in databaseNames {
      let url = root.rootURL.appendingPathComponent(name)
      if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }
    for url in [root.photosURL, root.thumbsURL] where fileManager.fileExists(atPath: url.path) {
      try fileManager.removeItem(at: url)
    }
  }

  /// Копирует содержимое копии (БД, photos, thumbs) в корень. Копия не трогается.
  static func restore(from backup: URL, into root: StoreLayout, fileManager: FileManager) throws {
    try removeLiveData(in: root, fileManager: fileManager)
    try fileManager.copyItem(
      at: backup.appendingPathComponent("inventory.db"),
      to: root.databaseURL)
    try RecoveryCopy.copyFiles(from: backup.appendingPathComponent("photos"), to: root.photosURL)
    try RecoveryCopy.copyFiles(from: backup.appendingPathComponent("thumbs"), to: root.thumbsURL)
  }
}
