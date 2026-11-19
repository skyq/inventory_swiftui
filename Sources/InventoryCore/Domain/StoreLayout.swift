import Foundation

/// Раскладка папки данных. Пути вычисляются от канонического корня.
public struct StoreLayout: Sendable, Equatable {
  public let rootURL: URL

  public init(rootURL: URL) {
    self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
  }

  public var rootPath: String { rootURL.path }
  public var databaseURL: URL { rootURL.appendingPathComponent("inventory.db") }
  public var databasePath: String { databaseURL.path }
  public var photosURL: URL { rootURL.appendingPathComponent("photos", isDirectory: true) }
  public var thumbsURL: URL { rootURL.appendingPathComponent("thumbs", isDirectory: true) }
  public var logsURL: URL { rootURL.appendingPathComponent("logs", isDirectory: true) }
  public var safetyURL: URL { rootURL.appendingPathComponent("_safety", isDirectory: true) }
  public var tmpURL: URL { rootURL.appendingPathComponent("_tmp", isDirectory: true) }
  public var lockURL: URL { rootURL.appendingPathComponent(".inventory.lock") }

  public var beforeMigrationURL: URL {
    safetyURL.appendingPathComponent("before-migration", isDirectory: true)
  }

  public var beforeImportURL: URL {
    safetyURL.appendingPathComponent("before-import", isDirectory: true)
  }

  /// Создаёт только каталоги папки данных, без файлов БД.
  public func createDirectories(fileManager: FileManager = .default) throws {
    for url in [rootURL, photosURL, thumbsURL, logsURL, safetyURL, tmpURL] {
      try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }
  }

  /// Разрешает относительный путь фото, не выпуская его за пределы корня.
  public func fileURL(forRelativePath relativePath: String) throws -> URL {
    guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
      throw AppException(
        .photoReadFailed,
        params: ["path": .string(relativePath)],
        debugMessage: "photo path must be relative and non-empty"
      )
    }
    let candidate = rootURL.appendingPathComponent(relativePath).standardizedFileURL
    let root = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
    guard candidate.path.hasPrefix(root) else {
      throw AppException(
        .photoReadFailed,
        params: ["path": .string(relativePath)],
        debugMessage: "photo path escapes the store root"
      )
    }
    return candidate
  }
}
