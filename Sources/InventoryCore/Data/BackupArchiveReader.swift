import Foundation
import ZIPFoundation

/// Лимиты распаковки архива v1 (D11). Превышение — понятная ошибка до записи
/// в данные пользователя.
public struct BackupArchiveLimits: Sendable, Equatable {
  public let maxUnpackedBytes: UInt64
  public let maxEntries: Int
  public let maxCompressionRatio: UInt64
  public let maxDataJSONBytes: UInt64

  public init(
    maxUnpackedBytes: UInt64 = 2 * 1024 * 1024 * 1024,
    maxEntries: Int = 100_000,
    maxCompressionRatio: UInt64 = 100,
    maxDataJSONBytes: UInt64 = 512 * 1024 * 1024
  ) {
    self.maxUnpackedBytes = maxUnpackedBytes
    self.maxEntries = maxEntries
    self.maxCompressionRatio = maxCompressionRatio
    self.maxDataJSONBytes = maxDataJSONBytes
  }

  public static let v1 = BackupArchiveLimits()
}

/// Распакованная оболочка архива в отдельной staging-папке. Здесь ещё нет
/// проверки данных: только структура ZIP, manifest и файлы фото.
///
/// Активные данные, `_safety` и папка хранилища не затрагиваются. Вызывающий
/// обязан вызвать `discard()` после использования или отказа.
public struct StagedBackupArchive: Sendable {
  public let directoryURL: URL
  public let manifest: BackupManifest
  public let dataURL: URL
  /// Относительные пути `photos/…` и `thumbs/…`, отсортированные.
  public let filePaths: [String]

  public init(
    directoryURL: URL,
    manifest: BackupManifest,
    dataURL: URL,
    filePaths: [String]
  ) {
    self.directoryURL = directoryURL
    self.manifest = manifest
    self.dataURL = dataURL
    self.filePaths = filePaths
  }

  public func discard(fileManager: FileManager = .default) {
    try? fileManager.removeItem(at: directoryURL)
  }
}

/// Читает `.inventory.zip` в staging, отклоняя опасные и повреждённые записи
/// до того, как что-либо будет применено к хранилищу.
public final class BackupArchiveReader: @unchecked Sendable {
  private let limits: BackupArchiveLimits
  private let temporaryRoot: URL
  private let fileManager: FileManager

  public init(
    limits: BackupArchiveLimits = .v1,
    temporaryRoot: URL? = nil,
    fileManager: FileManager = .default
  ) {
    self.limits = limits
    self.temporaryRoot = temporaryRoot ?? fileManager.temporaryDirectory
    self.fileManager = fileManager
  }

  public func stage(archiveAt url: URL) throws -> StagedBackupArchive {
    let archive: Archive
    do {
      archive = try Archive(url: url, accessMode: .read)
    } catch {
      throw AppException(
        .backupInvalidZip,
        params: ["path": .string(url.path)],
        debugMessage: "cannot open zip: \(error)"
      )
    }

    let plan = try planEntries(of: archive)
    let directory = try makeStagingDirectory()
    do {
      try extract(plan, from: archive, into: directory)
      let manifest = try readManifest(at: directory.appendingPathComponent("manifest.json"))
      return StagedBackupArchive(
        directoryURL: directory,
        manifest: manifest,
        dataURL: directory.appendingPathComponent("data.json"),
        filePaths: plan.photoPaths
      )
    } catch {
      try? fileManager.removeItem(at: directory)
      throw error
    }
  }

  // MARK: - План без записи на диск

  private struct Plan {
    let manifest: Entry
    let data: Entry
    let photos: [Entry]
    let photoPaths: [String]
  }

  private func planEntries(of archive: Archive) throws -> Plan {
    var seen = Set<String>()
    var manifest: Entry?
    var data: Entry?
    var photos: [Entry] = []
    var totalUnpacked: UInt64 = 0
    var count = 0

    for entry in archive {
      if entry.type == .directory {
        try checkDirectoryEntry(entry.path)
        continue
      }
      count += 1
      guard count <= limits.maxEntries else {
        throw AppException(
          .backupLimitExceeded,
          params: ["limit": .int(limits.maxEntries)],
          debugMessage: "archive has more entries than allowed"
        )
      }
      guard entry.type == .file else {
        throw unsafe(entry.path, reason: "only regular files are allowed")
      }

      let path = entry.path
      try validatePath(path)
      let key = path.lowercased()
      guard seen.insert(key).inserted else {
        throw unsafe(path, reason: "duplicate or colliding path")
      }

      let unpacked = entry.uncompressedSize
      let packed = entry.compressedSize
      if unpacked > 0 && (packed == 0 || unpacked / packed > limits.maxCompressionRatio) {
        throw AppException(
          .backupLimitExceeded,
          params: ["path": .string(path)],
          debugMessage: "compression ratio exceeds \(limits.maxCompressionRatio)"
        )
      }
      totalUnpacked += unpacked
      guard totalUnpacked <= limits.maxUnpackedBytes else {
        throw AppException(
          .backupLimitExceeded,
          params: ["limit": .int(Int(limits.maxUnpackedBytes))],
          debugMessage: "unpacked size exceeds limit"
        )
      }

      switch path {
      case "manifest.json":
        manifest = entry
      case "data.json":
        guard unpacked <= limits.maxDataJSONBytes else {
          throw AppException(
            .backupLimitExceeded,
            params: ["path": .string(path)],
            debugMessage: "data.json exceeds limit"
          )
        }
        data = entry
      default:
        photos.append(entry)
      }
    }

    guard let manifest else {
      throw AppException(.backupManifestInvalid, debugMessage: "manifest.json is missing")
    }
    guard let data else {
      throw AppException(.backupInvalidZip, debugMessage: "data.json is missing")
    }
    let photoPaths = photos.map(\.path).sorted()
    return Plan(manifest: manifest, data: data, photos: photos, photoPaths: photoPaths)
  }

  private func validatePath(_ path: String) throws {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else {
      throw unsafe(path, reason: "absolute or malformed path")
    }
    if path == "manifest.json" || path == "data.json" { return }

    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2,
      parts[0] == "photos" || parts[0] == "thumbs",
      !parts[1].isEmpty,
      parts[1] != ".", parts[1] != ".."
    else {
      throw unsafe(path, reason: "path is outside the archive layout")
    }
  }

  private func checkDirectoryEntry(_ path: String) throws {
    guard path == "photos/" || path == "thumbs/" else {
      throw unsafe(path, reason: "unexpected directory entry")
    }
  }

  private func unsafe(_ path: String, reason: String) -> AppException {
    AppException(
      .backupInvalidZip,
      params: ["path": .string(path)],
      debugMessage: "unsafe archive entry: \(reason)"
    )
  }

  // MARK: - Распаковка

  private func extract(_ plan: Plan, from archive: Archive, into directory: URL) throws {
    try fileManager.createDirectory(
      at: directory.appendingPathComponent("photos", isDirectory: true),
      withIntermediateDirectories: true)
    try fileManager.createDirectory(
      at: directory.appendingPathComponent("thumbs", isDirectory: true),
      withIntermediateDirectories: true)

    var total: UInt64 = 0
    try writeEntry(plan.manifest, from: archive, to: directory, total: &total, limit: nil)
    try writeEntry(
      plan.data, from: archive, to: directory, total: &total, limit: limits.maxDataJSONBytes)
    for photo in plan.photos {
      try writeEntry(photo, from: archive, to: directory, total: &total, limit: nil)
    }
  }

  private func writeEntry(
    _ entry: Entry,
    from archive: Archive,
    to directory: URL,
    total: inout UInt64,
    limit: UInt64?
  ) throws {
    let destination = directory.appendingPathComponent(entry.path).standardizedFileURL
    let root = directory.standardizedFileURL.path + "/"
    guard destination.path.hasPrefix(root) else {
      throw unsafe(entry.path, reason: "destination escapes staging")
    }

    guard fileManager.createFile(atPath: destination.path, contents: nil) else {
      throw AppException(
        .ioError,
        params: ["path": .string(destination.path)],
        debugMessage: "cannot create staging file"
      )
    }
    let handle = try FileHandle(forWritingTo: destination)
    var written: UInt64 = 0
    do {
      _ = try archive.extract(entry) { chunk in
        written += UInt64(chunk.count)
        total += UInt64(chunk.count)
        if let limit, written > limit {
          throw AppException(
            .backupLimitExceeded,
            params: ["path": .string(entry.path)],
            debugMessage: "entry exceeds limit while extracting"
          )
        }
        guard total <= limits.maxUnpackedBytes else {
          throw AppException(
            .backupLimitExceeded,
            params: ["limit": .int(Int(limits.maxUnpackedBytes))],
            debugMessage: "unpacked size exceeds limit while extracting"
          )
        }
        try handle.write(contentsOf: chunk)
      }
      try handle.close()
    } catch let error as AppException {
      try? handle.close()
      throw error
    } catch {
      try? handle.close()
      throw AppException(
        .backupInvalidZip,
        params: ["path": .string(entry.path)],
        debugMessage: "cannot extract entry: \(error)"
      )
    }
  }

  // MARK: - Manifest

  private func readManifest(at url: URL) throws -> BackupManifest {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw AppException(.backupManifestInvalid, debugMessage: "cannot read manifest: \(error)")
    }

    struct Probe: Decodable {
      let formatVersion: Int
      enum CodingKeys: String, CodingKey { case formatVersion = "format_version" }
    }
    let probe: Probe
    do {
      probe = try JSONDecoder().decode(Probe.self, from: data)
    } catch {
      throw AppException(
        .backupManifestInvalid,
        debugMessage: "manifest has no integer format_version: \(error)"
      )
    }
    guard probe.formatVersion >= 1 else {
      throw AppException(
        .backupManifestInvalid,
        params: ["found": .int(probe.formatVersion)],
        debugMessage: "format_version must start from 1"
      )
    }
    guard probe.formatVersion <= BackupFormat.version else {
      throw AppException(
        .backupNewerFormat,
        params: ["found": .int(probe.formatVersion), "supported": .int(BackupFormat.version)]
      )
    }

    let manifest: BackupManifest
    do {
      manifest = try JSONDecoder().decode(BackupManifest.self, from: data)
    } catch {
      throw AppException(.backupManifestInvalid, debugMessage: "manifest is invalid: \(error)")
    }

    let keys = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).map {
      Set($0.keys)
    }
    guard keys == ["format_version", "app_version", "exported_at", "counts"] else {
      throw AppException(
        .backupManifestInvalid,
        debugMessage: "manifest has missing or unknown fields"
      )
    }
    return manifest
  }

  private func makeStagingDirectory() throws -> URL {
    let directory = temporaryRoot.appendingPathComponent(
      "InventoryStage-\(UUID().uuidString)", isDirectory: true)
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      throw AppException(
        .ioError,
        params: ["path": .string(directory.path)],
        debugMessage: "cannot create staging directory: \(error)"
      )
    }
    return directory
  }
}
