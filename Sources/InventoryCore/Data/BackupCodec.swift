import Foundation
import ZIPFoundation

/// Упаковка согласованного снимка в переносимый архив `format_version = 1`
/// (D11): `manifest.json`, `data.json`, `photos/`, `thumbs/`.
///
/// Файл сначала пишется во временное имя в папке назначения и только после
/// успешного закрытия архива публикуется под финальным именем. Сбой не
/// оставляет файл, который можно принять за успешный архив.
public enum BackupCodec {
  public static func fileName(
    for createdAt: Int64,
    timeZone: TimeZone = .current
  ) -> String {
    let date = Date(timeIntervalSince1970: Double(createdAt) / 1000)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return "Inventory-\(formatter.string(from: date)).inventory.zip"
  }

  @discardableResult
  public static func exportV1(
    snapshot: BackupSnapshot,
    to directory: URL,
    appVersion: String,
    timeZone: TimeZone = .current,
    fileManager: FileManager = .default,
    progress: (@Sendable (BackupExportProgress) -> Void)? = nil
  ) throws -> URL {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw AppException(
        .ioError,
        params: ["path": .string(directory.path)],
        debugMessage: "export destination must be an existing directory"
      )
    }

    let manifest = BackupManifest(
      appVersion: appVersion,
      exportedAt: snapshot.createdAt,
      counts: snapshot.counts
    )
    let manifestData = try encode(manifest, path: "manifest.json")
    let dataData = try encode(tables(for: snapshot), path: "data.json")

    let finalURL = directory.appendingPathComponent(
      fileName(for: snapshot.createdAt, timeZone: timeZone), isDirectory: false)
    let temporaryURL = directory.appendingPathComponent(
      ".Inventory-export-\(UUID().uuidString).tmp", isDirectory: false)
    defer { try? fileManager.removeItem(at: temporaryURL) }

    let totalSteps = 2 + snapshot.filePaths.count
    var completedSteps = 0
    progress?(BackupExportProgress(completedSteps: 0, totalSteps: totalSteps))

    do {
      let archive = try Archive(url: temporaryURL, accessMode: .create)
      try add(data: manifestData, as: "manifest.json", to: archive)
      completedSteps += 1
      progress?(BackupExportProgress(completedSteps: completedSteps, totalSteps: totalSteps))

      try add(data: dataData, as: "data.json", to: archive)
      completedSteps += 1
      progress?(BackupExportProgress(completedSteps: completedSteps, totalSteps: totalSteps))

      for path in snapshot.filePaths {
        try validate(relativePath: path)
        let source = snapshot.fileURL(for: path)
        guard fileManager.fileExists(atPath: source.path) else {
          throw AppException(
            .backupIntegrityFailed,
            params: ["path": .string(path)],
            debugMessage: "snapshot file disappeared before export"
          )
        }
        try archive.addEntry(with: path, fileURL: source, compressionMethod: .none)
        completedSteps += 1
        progress?(BackupExportProgress(completedSteps: completedSteps, totalSteps: totalSteps))
      }
    } catch let error as AppException {
      throw error
    } catch {
      throw AppException(
        .ioError,
        params: ["path": .string(temporaryURL.path)],
        debugMessage: "cannot write inventory archive: \(error)"
      )
    }

    do {
      if fileManager.fileExists(atPath: finalURL.path) {
        _ = try fileManager.replaceItemAt(finalURL, withItemAt: temporaryURL)
      } else {
        try fileManager.moveItem(at: temporaryURL, to: finalURL)
      }
    } catch {
      throw AppException(
        .ioError,
        params: ["path": .string(finalURL.path)],
        debugMessage: "cannot publish inventory archive: \(error)"
      )
    }

    return finalURL
  }

  // MARK: - Содержимое

  private static func tables(for snapshot: BackupSnapshot) throws
    -> [String: [[String: BackupValue]]]
  {
    guard snapshot.tables.map(\.name) == BackupFormat.tableNames else {
      throw AppException(
        .backupIntegrityFailed,
        params: ["path": .string(snapshot.directoryURL.path)],
        debugMessage: "snapshot must contain exactly the nine v1 tables in order"
      )
    }
    return Dictionary(uniqueKeysWithValues: snapshot.tables.map { ($0.name, $0.rows) })
  }

  private static func encode<T: Encodable>(_ value: T, path: String) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    do {
      return try encoder.encode(value)
    } catch {
      throw AppException(
        .backupIntegrityFailed,
        params: ["path": .string(path)],
        debugMessage: "cannot encode archive JSON: \(error)"
      )
    }
  }

  private static func add(data: Data, as path: String, to archive: Archive) throws {
    try archive.addEntry(
      with: path,
      type: .file,
      uncompressedSize: Int64(data.count),
      compressionMethod: .deflate
    ) { position, size in
      let start = Int(position)
      guard start < data.count else { return Data() }
      let end = min(start + size, data.count)
      return data.subdata(in: start..<end)
    }
  }

  private static func validate(relativePath: String) throws {
    guard relativePath.hasPrefix("photos/") || relativePath.hasPrefix("thumbs/"),
      !relativePath.hasPrefix("/"),
      !relativePath.split(separator: "/").contains("..")
    else {
      throw AppException(
        .backupIntegrityFailed,
        params: ["path": .string(relativePath)],
        debugMessage: "archive file must stay inside photos/ or thumbs/"
      )
    }
  }
}
