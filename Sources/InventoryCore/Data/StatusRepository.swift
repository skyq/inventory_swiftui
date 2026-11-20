import Foundation
import GRDB

/// SQL-доступ к статусам. Транзакцию открывает вызывающий сервис.
struct StatusRepository {
  static func findOne(_ db: Database, id: String) throws -> Status? {
    try Row.fetchOne(db, sql: "SELECT * FROM statuses WHERE id = ?", arguments: [id]).map(decode)
  }

  static func list(_ db: Database, includeArchived: Bool) throws -> [Status] {
    let sql =
      includeArchived
      ? "SELECT * FROM statuses"
      : "SELECT * FROM statuses WHERE is_archived = 0"
    return sorted(try Row.fetchAll(db, sql: sql).map(decode))
  }

  static func defaultStatusId(_ db: Database) throws -> String? {
    try String.fetchOne(
      db,
      sql: "SELECT value FROM settings WHERE key = 'default_status_id'"
    )
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
      createdAt: row["created_at"]
    )
  }
}
