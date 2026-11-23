import Foundation
import GRDB

/// SQL-доступ к статусам. Транзакцию открывает вызывающий сервис.
struct StatusRepository {
  static func findOne(_ db: Database, id: String) throws -> Status? {
    try Row.fetchOne(db, sql: "SELECT * FROM statuses WHERE id = ?", arguments: [id]).map(decode)
  }

  /// Поиск по ключу NameKey: trim + Unicode lower без замены ё→е.
  static func findOne(_ db: Database, nameKey: String) throws -> Status? {
    try list(db, includeArchived: true).first { $0.name.lowercased() == nameKey }
  }

  static func list(_ db: Database, includeArchived: Bool) throws -> [Status] {
    let sql =
      includeArchived
      ? "SELECT * FROM statuses"
      : "SELECT * FROM statuses WHERE is_archived = 0"
    return sorted(try Row.fetchAll(db, sql: sql).map(decode))
  }

  static func defaultStatusId(_ db: Database) throws -> String? {
    try setting(db, key: "default_status_id")
  }

  static func setting(_ db: Database, key: String) throws -> String? {
    try String.fetchOne(
      db,
      sql: "SELECT value FROM settings WHERE key = ?",
      arguments: [key]
    )
  }

  static func settings(_ db: Database) throws -> StatusSettings {
    StatusSettings(
      defaultStatusId: try setting(db, key: "default_status_id") ?? "",
      transferStatusId: try setting(db, key: "transfer_status_id") ?? "",
      returnStatusId: try setting(db, key: "return_status_id") ?? ""
    )
  }

  static func setSetting(_ db: Database, key: String, value: String) throws {
    try db.execute(
      sql: """
        INSERT INTO settings (key, value) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """,
      arguments: [key, value]
    )
  }

  static func insert(_ db: Database, status: Status) throws {
    try db.execute(
      sql:
        "INSERT INTO statuses (id, name, is_archived, sort_order, created_at) VALUES (?, ?, ?, ?, ?)",
      arguments: [
        status.id, status.name, status.isArchived ? 1 : 0, status.sortOrder, status.createdAt,
      ]
    )
  }

  static func rename(_ db: Database, id: String, name: String) throws {
    try db.execute(sql: "UPDATE statuses SET name = ? WHERE id = ?", arguments: [name, id])
  }

  static func setArchived(_ db: Database, id: String, archived: Bool) throws {
    try db.execute(
      sql: "UPDATE statuses SET is_archived = ? WHERE id = ?",
      arguments: [archived ? 1 : 0, id]
    )
  }

  static func setHidden(_ db: Database, id: String, hidden: Bool) throws {
    try db.execute(
      sql: "UPDATE statuses SET is_hidden = ? WHERE id = ?",
      arguments: [hidden ? 1 : 0, id]
    )
  }

  static func nextSortOrder(_ db: Database) throws -> Int {
    (try Int.fetchOne(db, sql: "SELECT MAX(sort_order) FROM statuses") ?? -1) + 1
  }

  static func sorted(_ statuses: [Status]) -> [Status] {
    statuses.sorted { left, right in
      if left.sortOrder != right.sortOrder { return left.sortOrder < right.sortOrder }
      let byName = NaturalSort.compare(left.name, right.name)
      return byName != 0 ? byName < 0 : left.id < right.id
    }
  }

  private static func decode(_ row: Row) -> Status {
    Status(
      id: row["id"],
      name: row["name"],
      isArchived: (row["is_archived"] as Int) != 0,
      sortOrder: row["sort_order"],
      createdAt: row["created_at"],
      isHidden: (row["is_hidden"] as Int) != 0
    )
  }
}
