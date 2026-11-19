import Foundation
import GRDB

/// SQL-доступ к таблице `places`. Транзакцию открывает вызывающий сервис.
struct PlaceRepository {
  static func findOne(_ db: Database, id: String) throws -> Place? {
    try Row.fetchOne(db, sql: "SELECT * FROM places WHERE id = ?", arguments: [id])
      .map(decode)
  }

  static func all(_ db: Database) throws -> [Place] {
    try Row.fetchAll(db, sql: "SELECT * FROM places").map(decode)
  }

  static func children(_ db: Database, parentId: String?) throws -> [Place] {
    if let parentId {
      return try Row.fetchAll(
        db,
        sql: "SELECT * FROM places WHERE parent_id = ?",
        arguments: [parentId]
      ).map(decode)
    }
    return try Row.fetchAll(db, sql: "SELECT * FROM places WHERE parent_id IS NULL").map(decode)
  }

  static func duplicateExists(
    _ db: Database,
    nameKey: String,
    parentId: String?,
    excluding id: String?
  ) throws -> Bool {
    let rows = try Row.fetchAll(
      db,
      sql: "SELECT id, name FROM places WHERE parent_id IS ?",
      arguments: [parentId]
    )
    for row in rows {
      let rowId: String = row["id"]
      if rowId == id { continue }
      let name: String = row["name"]
      if NameKey.parseUnchecked(name) == nameKey { return true }
    }
    return false
  }

  static func insert(_ db: Database, place: Place) throws {
    try db.execute(
      sql: """
        INSERT INTO places
          (id, parent_id, name, description, photo_file, thumb_file, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        place.id,
        place.parentId,
        place.name,
        place.description,
        place.photoFile ?? "",
        place.thumbFile ?? "",
        place.createdAt,
        place.updatedAt,
      ]
    )
  }

  static func updateDetails(
    _ db: Database,
    id: String,
    name: String,
    description: String,
    photoFile: String?,
    thumbFile: String?,
    parentId: String?,
    updatedAt: Int64
  ) throws {
    try db.execute(
      sql: """
        UPDATE places
        SET name = ?, description = ?, photo_file = ?, thumb_file = ?, parent_id = ?, updated_at = ?
        WHERE id = ?
        """,
      arguments: [name, description, photoFile ?? "", thumbFile ?? "", parentId, updatedAt, id]
    )
  }

  static func updateParent(
    _ db: Database,
    id: String,
    parentId: String?,
    updatedAt: Int64
  ) throws {
    try db.execute(
      sql: "UPDATE places SET parent_id = ?, updated_at = ? WHERE id = ?",
      arguments: [parentId, updatedAt, id]
    )
  }

  static func delete(_ db: Database, id: String) throws {
    try db.execute(sql: "DELETE FROM places WHERE id = ?", arguments: [id])
  }

  static func countChildren(_ db: Database, id: String) throws -> Int {
    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM places WHERE parent_id = ?", arguments: [id])
      ?? 0
  }

  static func countItems(_ db: Database, id: String) throws -> Int {
    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items WHERE place_id = ?", arguments: [id]) ?? 0
  }

  private static func decode(_ row: Row) -> Place {
    let photo: String = row["photo_file"]
    let thumb: String = row["thumb_file"]
    return Place(
      id: row["id"],
      parentId: row["parent_id"],
      name: row["name"],
      description: row["description"],
      photoFile: photo.isEmpty ? nil : photo,
      thumbFile: thumb.isEmpty ? nil : thumb,
      createdAt: row["created_at"],
      updatedAt: row["updated_at"]
    )
  }
}

extension NameKey {
  /// Ключ без проверки длины: для сравнения уже сохранённых значений.
  static func parseUnchecked(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}
