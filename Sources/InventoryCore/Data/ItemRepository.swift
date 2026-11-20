import Foundation
import GRDB

struct ItemRow {
  let item: Item
  let statusName: String
  let statusArchived: Bool
}

/// SQL-доступ к вещам. Транзакцию открывает вызывающий сервис.
struct ItemRepository {
  static func findOne(_ db: Database, id: String) throws -> ItemRow? {
    try Row.fetchOne(
      db,
      sql: """
        SELECT i.*, s.name AS status_name, s.is_archived AS status_archived
        FROM items i
        JOIN statuses s ON s.id = i.status_id
        WHERE i.id = ?
        """,
      arguments: [id]
    ).map(decode)
  }

  static func all(_ db: Database) throws -> [ItemRow] {
    try Row.fetchAll(
      db,
      sql: """
        SELECT i.*, s.name AS status_name, s.is_archived AS status_archived
        FROM items i
        JOIN statuses s ON s.id = i.status_id
        """
    ).map(decode)
  }

  static func insert(_ db: Database, item: Item) throws {
    try db.execute(
      sql: """
        INSERT INTO items
          (id, name, description, notes, quantity, place_id, status_id,
           photo_file, thumb_file, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        item.id,
        item.name,
        item.description,
        item.notes,
        item.quantity,
        item.placeId,
        item.statusId,
        item.photoFile,
        item.thumbFile,
        item.createdAt,
        item.updatedAt,
      ]
    )
  }

  static func updateDetails(
    _ db: Database,
    id: String,
    name: String,
    description: String,
    notes: String,
    quantity: Int,
    placeId: String?,
    photoFile: String,
    thumbFile: String,
    updatedAt: Int64
  ) throws {
    try db.execute(
      sql: """
        UPDATE items
        SET name = ?, description = ?, notes = ?, quantity = ?, place_id = ?,
            photo_file = ?, thumb_file = ?, updated_at = ?
        WHERE id = ?
        """,
      arguments: [
        name, description, notes, quantity, placeId, photoFile, thumbFile, updatedAt, id,
      ]
    )
  }

  static func count(_ db: Database) throws -> Int {
    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items") ?? 0
  }

  /// Все связи item → tag одним запросом: теги нужны для AND-фильтра галереи.
  static func allItemTags(_ db: Database) throws -> [String: Set<String>] {
    var result: [String: Set<String>] = [:]
    for row in try Row.fetchAll(db, sql: "SELECT item_id, tag_id FROM item_tags") {
      let itemId: String = row["item_id"]
      let tagId: String = row["tag_id"]
      result[itemId, default: []].insert(tagId)
    }
    return result
  }

  private static func decode(_ row: Row) -> ItemRow {
    let item = Item(
      id: row["id"],
      name: row["name"],
      description: row["description"],
      notes: row["notes"],
      quantity: row["quantity"],
      placeId: row["place_id"],
      statusId: row["status_id"],
      photoFile: row["photo_file"],
      thumbFile: row["thumb_file"],
      createdAt: row["created_at"],
      updatedAt: row["updated_at"]
    )
    return ItemRow(
      item: item,
      statusName: row["status_name"],
      statusArchived: (row["status_archived"] as Int) != 0
    )
  }
}
