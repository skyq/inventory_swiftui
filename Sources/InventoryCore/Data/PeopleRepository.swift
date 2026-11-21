import Foundation
import GRDB

/// SQL-доступ к людям. Транзакцию открывает вызывающий сервис.
struct PeopleRepository {
  static func findOne(_ db: Database, id: String) throws -> Person? {
    try Row.fetchOne(db, sql: "SELECT * FROM people WHERE id = ?", arguments: [id]).map(decode)
  }

  static func findOne(_ db: Database, nameKey: String, excluding: String? = nil) throws -> Person? {
    try all(db).first {
      $0.id != excluding && $0.name.lowercased() == nameKey
    }
  }

  static func all(_ db: Database, includeArchived: Bool = true) throws -> [Person] {
    let sql =
      includeArchived
      ? "SELECT * FROM people"
      : "SELECT * FROM people WHERE is_archived = 0"
    return sorted(try Row.fetchAll(db, sql: sql).map(decode))
  }

  static func insert(_ db: Database, person: Person) throws {
    try db.execute(
      sql: """
        INSERT INTO people (id, name, phone, notes, is_archived, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        person.id, person.name, person.phone, person.notes, person.isArchived ? 1 : 0,
        person.createdAt, person.updatedAt,
      ]
    )
  }

  static func update(
    _ db: Database,
    id: String,
    name: String,
    phone: String,
    notes: String,
    updatedAt: Int64
  ) throws {
    try db.execute(
      sql: "UPDATE people SET name = ?, phone = ?, notes = ?, updated_at = ? WHERE id = ?",
      arguments: [name, phone, notes, updatedAt, id]
    )
  }

  static func setArchived(_ db: Database, id: String, archived: Bool, updatedAt: Int64) throws {
    try db.execute(
      sql: "UPDATE people SET is_archived = ?, updated_at = ? WHERE id = ?",
      arguments: [archived ? 1 : 0, updatedAt, id]
    )
  }

  /// Последний получатель по give; tie-break по id ASC (D12).
  static func lastGivenPersonId(_ db: Database, itemId: String) throws -> String? {
    try String.fetchOne(
      db,
      sql: """
        SELECT person_id FROM transfers
        WHERE item_id = ? AND kind = 'give'
        ORDER BY created_at DESC, id ASC
        LIMIT 1
        """,
      arguments: [itemId]
    )
  }

  static func hasTransfer(_ db: Database, itemId: String, personId: String) throws -> Bool {
    try Bool.fetchOne(
      db,
      sql: "SELECT 1 FROM transfers WHERE item_id = ? AND person_id = ? LIMIT 1",
      arguments: [itemId, personId]
    ) ?? false
  }

  static func sorted(_ people: [Person]) -> [Person] {
    people.sorted { left, right in
      let byName = NaturalSort.compare(left.name, right.name)
      return byName != 0 ? byName < 0 : left.id < right.id
    }
  }

  private static func decode(_ row: Row) -> Person {
    Person(
      id: row["id"],
      name: row["name"],
      phone: row["phone"],
      notes: row["notes"],
      isArchived: (row["is_archived"] as Int) != 0,
      createdAt: row["created_at"],
      updatedAt: row["updated_at"]
    )
  }
}
