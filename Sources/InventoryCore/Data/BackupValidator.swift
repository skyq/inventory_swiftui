import Foundation

/// Проверенный архив: все таблицы согласованы и все файлы фото на месте.
/// Создаётся только `BackupValidator`; данные живого хранилища не затрагиваются.
/// Папка staging остаётся у вызывающего, который обязан вызвать `discard()`.
public struct ValidatedBackup: Sendable {
  public let staged: StagedBackupArchive
  public let manifest: BackupManifest
  /// Проверенные строки в порядке `BackupFormat.tableNames`.
  public let tables: [BackupTable]

  public init(staged: StagedBackupArchive, manifest: BackupManifest, tables: [BackupTable]) {
    self.staged = staged
    self.manifest = manifest
    self.tables = tables
  }

  public var itemCount: Int { tables.first { $0.name == "items" }?.rows.count ?? 0 }

  public var counts: [String: Int] {
    Dictionary(uniqueKeysWithValues: tables.map { ($0.name, $0.rows.count) })
  }

  public func table(named name: String) -> BackupTable? {
    tables.first { $0.name == name }
  }

  public func discard(fileManager: FileManager = .default) {
    staged.discard(fileManager: fileManager)
  }
}

/// Реестр читателей по `format_version`. Поддержаны форматы 1 и 2 (v2 добавляет
/// `statuses.is_hidden`; архивы v1 читаются, скрытие по умолчанию выключено).
public enum BackupFormatRegistry {
  public static let supportedVersions: Set<Int> = [1, 2]

  public static func validate(_ staged: StagedBackupArchive) throws -> ValidatedBackup {
    let version = staged.manifest.formatVersion
    guard supportedVersions.contains(version) else {
      throw AppException(
        version > BackupFormat.version ? .backupNewerFormat : .backupManifestInvalid,
        params: ["found": .int(version), "supported": .int(BackupFormat.version)]
      )
    }
    return try BackupValidatorV1.validate(staged, formatVersion: version)
  }
}

/// Проверка формата v1: структура `data.json`, типы, ключи, ссылки, циклы
/// мест, активные статусы по умолчанию, счётчики манифеста и файлы фото.
enum BackupValidatorV1 {
  private enum ColumnType {
    case text
    case integer
  }

  private struct Column {
    let name: String
    let type: ColumnType
    let nullable: Bool
    let isUUIDKey: Bool

    init(_ name: String, _ type: ColumnType, nullable: Bool = false, uuid: Bool = false) {
      self.name = name
      self.type = type
      self.nullable = nullable
      self.isUUIDKey = uuid
    }
  }

  private static func schema(for formatVersion: Int) -> [(table: String, columns: [Column])] {
    baseSchema.map { spec in
      guard spec.table == "statuses", formatVersion >= 2 else { return spec }
      return (spec.table, spec.columns + [Column("is_hidden", .integer)])
    }
  }

  private static let baseSchema: [(table: String, columns: [Column])] = [
    (
      "places",
      [
        Column("id", .text, uuid: true),
        Column("parent_id", .text, nullable: true),
        Column("name", .text),
        Column("description", .text),
        Column("photo_file", .text),
        Column("thumb_file", .text),
        Column("created_at", .integer),
        Column("updated_at", .integer),
      ]
    ),
    (
      "statuses",
      [
        Column("id", .text, uuid: true),
        Column("name", .text),
        Column("is_archived", .integer),
        Column("sort_order", .integer),
        Column("created_at", .integer),
      ]
    ),
    (
      "people",
      [
        Column("id", .text, uuid: true),
        Column("name", .text),
        Column("phone", .text),
        Column("notes", .text),
        Column("is_archived", .integer),
        Column("created_at", .integer),
        Column("updated_at", .integer),
      ]
    ),
    (
      "items",
      [
        Column("id", .text, uuid: true),
        Column("name", .text),
        Column("description", .text),
        Column("notes", .text),
        Column("quantity", .integer),
        Column("place_id", .text, nullable: true),
        Column("status_id", .text),
        Column("photo_file", .text),
        Column("thumb_file", .text),
        Column("created_at", .integer),
        Column("updated_at", .integer),
      ]
    ),
    (
      "tags",
      [
        Column("id", .text, uuid: true),
        Column("name", .text),
        Column("name_key", .text),
      ]
    ),
    (
      "item_tags",
      [
        Column("item_id", .text),
        Column("tag_id", .text),
      ]
    ),
    (
      "status_changes",
      [
        Column("id", .text, uuid: true),
        Column("item_id", .text),
        Column("from_status_id", .text),
        Column("to_status_id", .text),
        Column("comment", .text),
        Column("created_at", .integer),
      ]
    ),
    (
      "transfers",
      [
        Column("id", .text, uuid: true),
        Column("item_id", .text),
        Column("kind", .text),
        Column("person_id", .text),
        Column("comment", .text),
        Column("created_at", .integer),
      ]
    ),
    (
      "settings",
      [
        Column("key", .text),
        Column("value", .text),
      ]
    ),
  ]

  private static let defaultSettingKeys = [
    "default_status_id",
    "transfer_status_id",
    "return_status_id",
  ]

  static func validate(
    _ staged: StagedBackupArchive,
    formatVersion: Int
  ) throws -> ValidatedBackup {
    let raw = try decodeTables(at: staged.dataURL)
    let tables = try schema(for: formatVersion).map { spec in
      try validateTable(spec.table, columns: spec.columns, rows: raw[spec.table] ?? [])
    }
    let byName = Dictionary(uniqueKeysWithValues: tables.map { ($0.name, $0.rows) })

    try checkCounts(staged.manifest.counts, tables: byName)
    try checkReferences(byName)
    try checkPlaceCycles(byName["places"] ?? [])
    try checkStatusNames(byName["statuses"] ?? [])
    try checkDefaultSettings(byName)
    try checkFiles(byName, available: Set(staged.filePaths))

    return ValidatedBackup(staged: staged, manifest: staged.manifest, tables: tables)
  }

  // MARK: - Структура

  private static func decodeTables(at url: URL) throws -> [String: [[String: BackupValue]]] {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw integrity("data.json", "cannot read data.json: \(error)")
    }
    let decoded: [String: [[String: BackupValue]]]
    do {
      decoded = try JSONDecoder().decode([String: [[String: BackupValue]]].self, from: data)
    } catch {
      throw integrity("data.json", "data.json must be an object of row arrays: \(error)")
    }
    let expected = Set(BackupFormat.tableNames)
    guard Set(decoded.keys) == expected else {
      throw integrity("data.json", "data.json must contain exactly the nine v1 tables")
    }
    return decoded
  }

  private static func validateTable(
    _ table: String,
    columns: [Column],
    rows: [[String: BackupValue]]
  ) throws -> BackupTable {
    let names = Set(columns.map(\.name))
    var seenKeys = Set<String>()
    for (index, row) in rows.enumerated() {
      guard Set(row.keys) == names else {
        throw integrity(table, "row \(index) must have exactly the expected columns")
      }
      for column in columns {
        let value = row[column.name] ?? .null
        try checkValue(value, column: column, table: table, row: index)
      }
      if let keyColumn = columns.first(where: \.isUUIDKey) {
        guard case .text(let key) = row[keyColumn.name] ?? .null else {
          throw integrity(table, "row \(index) has no text id")
        }
        guard UUID(uuidString: key) != nil else {
          throw integrity(table, "row \(index) id is not a UUID")
        }
        guard seenKeys.insert(key).inserted else {
          throw integrity(table, "duplicate id in row \(index)")
        }
      }
    }
    return BackupTable(name: table, rows: rows)
  }

  private static func checkValue(
    _ value: BackupValue,
    column: Column,
    table: String,
    row: Int
  ) throws {
    switch (value, column.type) {
    case (.null, _):
      guard column.nullable else {
        throw integrity(table, "row \(row) column \(column.name) must not be NULL")
      }
    case (.integer, .integer), (.text, .text):
      return
    default:
      throw integrity(table, "row \(row) column \(column.name) has wrong type")
    }
  }

  // MARK: - Счётчики и ссылки

  private static func checkCounts(
    _ counts: [String: Int],
    tables: [String: [[String: BackupValue]]]
  ) throws {
    guard Set(counts.keys) == Set(BackupFormat.tableNames) else {
      throw AppException(
        .backupManifestInvalid,
        debugMessage: "manifest counts must list exactly the nine tables"
      )
    }
    for name in BackupFormat.tableNames where counts[name] != tables[name]?.count {
      throw AppException(
        .backupIntegrityFailed,
        params: ["table": .string(name)],
        debugMessage: "row count does not match manifest"
      )
    }
  }

  private static func checkReferences(_ tables: [String: [[String: BackupValue]]]) throws {
    let places = ids(in: tables["places"] ?? [])
    let statuses = ids(in: tables["statuses"] ?? [])
    let people = ids(in: tables["people"] ?? [])
    let items = ids(in: tables["items"] ?? [])
    let tags = ids(in: tables["tags"] ?? [])

    for row in tables["places"] ?? [] {
      try requireOptional(row, "parent_id", in: places, table: "places")
    }
    for row in tables["items"] ?? [] {
      try requireOptional(row, "place_id", in: places, table: "items")
      try require(row, "status_id", in: statuses, table: "items")
    }
    for row in tables["item_tags"] ?? [] {
      try require(row, "item_id", in: items, table: "item_tags")
      try require(row, "tag_id", in: tags, table: "item_tags")
    }
    for row in tables["status_changes"] ?? [] {
      try require(row, "item_id", in: items, table: "status_changes")
      try require(row, "from_status_id", in: statuses, table: "status_changes")
      try require(row, "to_status_id", in: statuses, table: "status_changes")
    }
    for row in tables["transfers"] ?? [] {
      try require(row, "item_id", in: items, table: "transfers")
      try require(row, "person_id", in: people, table: "transfers")
      let kind = text(row, "kind")
      guard kind == "give" || kind == "return" else {
        throw integrity("transfers", "kind must be give or return")
      }
    }

    var nameKeys = Set<String>()
    for row in tables["tags"] ?? [] {
      let key = text(row, "name_key")
      guard nameKeys.insert(key).inserted else {
        throw integrity("tags", "duplicate name_key")
      }
    }

    var pairs = Set<String>()
    for row in tables["item_tags"] ?? [] {
      let pair = text(row, "item_id") + "|" + text(row, "tag_id")
      guard pairs.insert(pair).inserted else {
        throw integrity("item_tags", "duplicate item/tag pair")
      }
    }

    for row in tables["items"] ?? [] {
      guard integer(row, "quantity") >= 1 else {
        throw integrity("items", "quantity must be at least 1")
      }
    }
  }

  private static func checkPlaceCycles(_ rows: [[String: BackupValue]]) throws {
    var parent: [String: String] = [:]
    for row in rows {
      if case .text(let value) = row["parent_id"] ?? .null {
        parent[text(row, "id")] = value
      }
    }
    for start in parent.keys {
      var seen: Set<String> = [start]
      var current = parent[start]
      while let node = current {
        guard seen.insert(node).inserted else {
          throw integrity("places", "place hierarchy contains a cycle")
        }
        current = parent[node]
      }
    }
  }

  private static func checkStatusNames(_ rows: [[String: BackupValue]]) throws {
    var keys = Set<String>()
    for row in rows {
      let raw = text(row, "name").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !raw.isEmpty, raw.count <= NameKey.maxLength else {
        throw integrity("statuses", "status name must be non-empty and at most 200 characters")
      }
      guard keys.insert(raw.lowercased()).inserted else {
        throw integrity("statuses", "duplicate status name ignoring case")
      }
    }
  }

  private static func checkDefaultSettings(
    _ tables: [String: [[String: BackupValue]]]
  ) throws {
    let settings = tables["settings"] ?? []
    var values: [String: String] = [:]
    for row in settings {
      values[text(row, "key")] = text(row, "value")
    }
    guard Set(values.keys) == Set(defaultSettingKeys) else {
      throw integrity("settings", "settings must contain exactly the three default status keys")
    }

    let active = Set(
      (tables["statuses"] ?? [])
        .filter { integer($0, "is_archived") == 0 }
        .map { text($0, "id") })
    for key in defaultSettingKeys {
      guard let value = values[key], active.contains(value) else {
        throw integrity("settings", "\(key) must point to an active status")
      }
    }
  }

  // MARK: - Файлы

  private static func checkFiles(
    _ tables: [String: [[String: BackupValue]]],
    available: Set<String>
  ) throws {
    for table in ["places", "items"] {
      for row in tables[table] ?? [] {
        try checkPhotoPath(text(row, "photo_file"), prefix: "photos/", table: table)
        try checkPhotoPath(text(row, "thumb_file"), prefix: "thumbs/", table: table)
        for column in ["photo_file", "thumb_file"] {
          guard available.contains(text(row, column)) else {
            throw AppException(
              .backupIntegrityFailed,
              params: ["path": .string(text(row, column))],
              debugMessage: "referenced photo file is missing from the archive"
            )
          }
        }
      }
    }
  }

  private static func checkPhotoPath(_ path: String, prefix: String, table: String) throws {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard path.hasPrefix(prefix), parts.count == 2, !parts[1].isEmpty,
      parts[1] != ".", parts[1] != ".."
    else {
      throw integrity(table, "photo path must stay inside \(prefix)")
    }
  }

  // MARK: - Помощники

  private static func ids(in rows: [[String: BackupValue]]) -> Set<String> {
    Set(rows.map { text($0, "id") })
  }

  private static func require(
    _ row: [String: BackupValue],
    _ column: String,
    in known: Set<String>,
    table: String
  ) throws {
    let value = text(row, column)
    guard known.contains(value) else {
      throw integrity(table, "\(column) references a missing row")
    }
  }

  private static func requireOptional(
    _ row: [String: BackupValue],
    _ column: String,
    in known: Set<String>,
    table: String
  ) throws {
    if case .null = row[column] ?? .null { return }
    try require(row, column, in: known, table: table)
  }

  private static func text(_ row: [String: BackupValue], _ column: String) -> String {
    if case .text(let value) = row[column] ?? .null { return value }
    return ""
  }

  private static func integer(_ row: [String: BackupValue], _ column: String) -> Int64 {
    if case .integer(let value) = row[column] ?? .null { return value }
    return 0
  }

  private static func integrity(_ table: String, _ message: String) -> AppException {
    AppException(
      .backupIntegrityFailed,
      params: ["table": .string(table)],
      debugMessage: message
    )
  }
}
