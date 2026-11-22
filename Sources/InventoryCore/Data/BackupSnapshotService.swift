import Foundation
import GRDB

/// Снимает одну согласованную версию всех девяти таблиц и относящихся к ним
/// файлов фото/превью для последующей упаковки в архив.
///
/// Пока снимок собирается, `StoreWriteGate` не пропускает операции записи:
/// нельзя получить базу одной версии и файлы другой. После ошибки гейт
/// освобождается, а временная папка удаляется.
public final class BackupSnapshotService: @unchecked Sendable {
  private let database: InventoryDatabase
  private let layout: StoreLayout
  private let gate: StoreWriteGate
  private let clock: any Clock
  private let fileManager: FileManager
  private let temporaryRoot: URL

  public init(
    database: InventoryDatabase,
    layout: StoreLayout,
    gate: StoreWriteGate,
    clock: any Clock = SystemClock(),
    fileManager: FileManager = .default,
    temporaryRoot: URL? = nil
  ) {
    self.database = database
    self.layout = layout
    self.gate = gate
    self.clock = clock
    self.fileManager = fileManager
    self.temporaryRoot = temporaryRoot ?? fileManager.temporaryDirectory
  }

  public func makeSnapshot() throws -> BackupSnapshot {
    try gate.performSnapshot {
      let directory = try makeTemporaryDirectory()
      do {
        return try buildSnapshot(in: directory)
      } catch {
        try? fileManager.removeItem(at: directory)
        if let appError = error as? AppException {
          throw appError
        }
        throw AppException(
          .backupIntegrityFailed,
          params: ["path": .string(layout.rootPath)],
          debugMessage: "cannot build backup snapshot: \(error)"
        )
      }
    }
  }

  // MARK: - Снимок

  private func buildSnapshot(in directory: URL) throws -> BackupSnapshot {
    let createdAt = clock.nowMilliseconds()

    let (tables, schemaVersion, filePaths) = try database.read { db in
      let tables = try BackupFormat.tableNames.map { name in
        try readTable(named: name, from: db)
      }
      let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
      let files = try referencedFiles(in: db)
      return (tables, version, files)
    }

    for path in filePaths {
      try copyFile(relativePath: path, into: directory)
    }

    return BackupSnapshot(
      directoryURL: directory,
      createdAt: createdAt,
      schemaVersion: schemaVersion,
      tables: tables,
      filePaths: filePaths
    )
  }

  private func makeTemporaryDirectory() throws -> URL {
    do {
      try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
      let directory = temporaryRoot.appendingPathComponent(
        "InventorySnapshot-\(UUID().uuidString)", isDirectory: true)
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
      return directory
    } catch {
      throw AppException(
        .ioError,
        params: ["path": .string(temporaryRoot.path)],
        debugMessage: "cannot create snapshot temporary directory: \(error)"
      )
    }
  }

  private func readTable(named name: String, from db: Database) throws -> BackupTable {
    guard try db.tableExists(name) else {
      throw AppException(
        .backupIntegrityFailed,
        params: ["table": .string(name)],
        debugMessage: "required table is missing"
      )
    }

    let columns = try db.columns(in: name).map(\.name)
    let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(name) ORDER BY rowid")
    let values: [[String: BackupValue]] = try rows.map { row in
      var cells: [String: BackupValue] = [:]
      cells.reserveCapacity(columns.count)
      for column in columns {
        cells[column] = try backupValue(row[column], table: name, column: column)
      }
      return cells
    }
    return BackupTable(name: name, rows: values)
  }

  private func backupValue(
    _ value: DatabaseValue,
    table: String,
    column: String
  ) throws -> BackupValue {
    switch value.storage {
    case .null:
      return .null
    case .int64(let number):
      return .integer(number)
    case .string(let text):
      return .text(text)
    case .double, .blob:
      throw AppException(
        .backupIntegrityFailed,
        params: ["table": .string(table), "column": .string(column)],
        debugMessage: "v1 archive supports only TEXT, INTEGER and NULL values"
      )
    }
  }

  private func referencedFiles(in db: Database) throws -> [String] {
    var paths = Set<String>()
    for table in ["places", "items"] {
      let rows = try Row.fetchAll(
        db, sql: "SELECT photo_file, thumb_file FROM \(table)")
      for row in rows {
        for column in ["photo_file", "thumb_file"] {
          guard let path = String.fromDatabaseValue(row[column]) else {
            throw AppException(
              .backupIntegrityFailed,
              params: ["table": .string(table), "column": .string(column)],
              debugMessage: "photo reference must be TEXT"
            )
          }
          paths.insert(path)
        }
      }
    }
    return paths.sorted()
  }

  private func copyFile(relativePath: String, into directory: URL) throws {
    guard relativePath.hasPrefix("photos/") || relativePath.hasPrefix("thumbs/"),
      !relativePath.hasPrefix("/"),
      !relativePath.split(separator: "/").contains("..")
    else {
      throw AppException(
        .backupIntegrityFailed,
        params: ["path": .string(relativePath)],
        debugMessage: "photo reference must stay inside photos/ or thumbs/"
      )
    }

    let source: URL
    do {
      source = try layout.fileURL(forRelativePath: relativePath)
    } catch {
      throw AppException(
        .backupIntegrityFailed,
        params: ["path": .string(relativePath)],
        debugMessage: "invalid photo reference: \(error)"
      )
    }

    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else {
      throw AppException(
        .backupIntegrityFailed,
        params: ["path": .string(relativePath)],
        debugMessage: "referenced photo file is missing"
      )
    }

    let destination = directory.appendingPathComponent(relativePath).standardizedFileURL
    let root = directory.standardizedFileURL.path
    let prefix = root.hasSuffix("/") ? root : root + "/"
    guard destination.path.hasPrefix(prefix) else {
      throw AppException(
        .backupIntegrityFailed,
        params: ["path": .string(relativePath)],
        debugMessage: "photo destination escapes the snapshot directory"
      )
    }

    do {
      try fileManager.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try fileManager.copyItem(at: source, to: destination)
    } catch {
      throw AppException(
        .backupIntegrityFailed,
        params: ["path": .string(relativePath)],
        debugMessage: "cannot copy photo into snapshot: \(error)"
      )
    }
  }
}
