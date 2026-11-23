import Foundation

/// Манифест архива v1. Ключи JSON фиксированы D11 и не зависят от
/// Swift-имён свойств.
public struct BackupManifest: Sendable, Equatable, Codable {
  public let formatVersion: Int
  public let appVersion: String
  public let exportedAt: Int64
  public let counts: [String: Int]

  public init(
    formatVersion: Int = BackupFormat.version,
    appVersion: String,
    exportedAt: Int64,
    counts: [String: Int]
  ) {
    self.formatVersion = formatVersion
    self.appVersion = appVersion
    self.exportedAt = exportedAt
    self.counts = counts
  }

  private enum CodingKeys: String, CodingKey {
    case formatVersion = "format_version"
    case appVersion = "app_version"
    case exportedAt = "exported_at"
    case counts
  }
}

/// Прогресс упаковки архива. `completedSteps` включает manifest и data.json,
/// поэтому после успеха всегда равен `totalSteps`.
public struct BackupExportProgress: Sendable, Equatable {
  public let completedSteps: Int
  public let totalSteps: Int

  public init(completedSteps: Int, totalSteps: Int) {
    self.completedSteps = completedSteps
    self.totalSteps = totalSteps
  }

  public var fraction: Double {
    guard totalSteps > 0 else { return 1 }
    return Double(completedSteps) / Double(totalSteps)
  }
}

/// Константы формата архива v1 (D11). Имена таблиц идут в порядке,
/// зафиксированном для `data.json` и `manifest.json`.
public enum BackupFormat {
  public static let version = 1

  public static let tableNames: [String] = [
    "places",
    "statuses",
    "people",
    "items",
    "tags",
    "item_tags",
    "status_changes",
    "transfers",
    "settings",
  ]
}

/// Значение ячейки архива. Формат v1 допускает только TEXT, INTEGER и NULL
/// (D11); другие типы считаются ошибкой схемы.
public enum BackupValue: Sendable, Equatable, Hashable {
  case null
  case integer(Int64)
  case text(String)
}

extension BackupValue: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Int64.self) {
      self = .integer(value)
    } else {
      self = .text(try container.decode(String.self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null:
      try container.encodeNil()
    case .integer(let value):
      try container.encode(value)
    case .text(let value):
      try container.encode(value)
    }
  }
}

/// Одна таблица архива: имя как в SQL и строки в детерминированном порядке.
public struct BackupTable: Sendable, Equatable, Codable {
  public let name: String
  public let rows: [[String: BackupValue]]

  public init(name: String, rows: [[String: BackupValue]]) {
    self.name = name
    self.rows = rows
  }
}

/// Согласованный снимок хранилища для упаковки в архив.
///
/// `directoryURL` — временная область, которой владеет вызывающий: после
/// успешной упаковки её нужно удалить. Внутри только `photos/` и `thumbs/`
/// с файлами, на которые ссылается снимок; БД, preferences, логи и `_safety`
/// не копируются.
public struct BackupSnapshot: Sendable {
  public let directoryURL: URL
  public let createdAt: Int64
  public let schemaVersion: Int
  public let tables: [BackupTable]
  /// Относительные пути фото и превью, отсортированные.
  public let filePaths: [String]

  public init(
    directoryURL: URL,
    createdAt: Int64,
    schemaVersion: Int,
    tables: [BackupTable],
    filePaths: [String]
  ) {
    self.directoryURL = directoryURL
    self.createdAt = createdAt
    self.schemaVersion = schemaVersion
    self.tables = tables
    self.filePaths = filePaths
  }

  public var counts: [String: Int] {
    Dictionary(uniqueKeysWithValues: tables.map { ($0.name, $0.rows.count) })
  }

  public func table(named name: String) -> BackupTable? {
    tables.first { $0.name == name }
  }

  public func fileURL(for relativePath: String) -> URL {
    directoryURL.appendingPathComponent(relativePath)
  }

  /// Удаляет временную область снимка. Вызывающий делает это после упаковки
  /// или после отказа; ошибка удаления не влияет на доменный результат.
  public func discard(fileManager: FileManager = .default) {
    try? fileManager.removeItem(at: directoryURL)
  }
}
