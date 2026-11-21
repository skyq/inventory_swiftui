import Foundation
import GRDB

/// SQL-доступ к тегам. Транзакцию открывает вызывающий сервис.
struct TagRepository {
  static func findOne(_ db: Database, nameKey: String) throws -> Tag? {
    try Row.fetchOne(db, sql: "SELECT * FROM tags WHERE name_key = ?", arguments: [nameKey])
      .map(decode)
  }

  static func findOne(_ db: Database, id: String) throws -> Tag? {
    try Row.fetchOne(db, sql: "SELECT * FROM tags WHERE id = ?", arguments: [id]).map(decode)
  }

  static func all(_ db: Database) throws -> [Tag] {
    try Row.fetchAll(db, sql: "SELECT * FROM tags").map(decode)
  }

  static func insert(_ db: Database, tag: Tag) throws {
    try db.execute(
      sql: "INSERT INTO tags (id, name, name_key) VALUES (?, ?, ?)",
      arguments: [tag.id, tag.name, tag.nameKey]
    )
  }

  static func tagIds(forItem db: Database, itemId: String) throws -> Set<String> {
    Set(
      try String.fetchAll(
        db,
        sql: "SELECT tag_id FROM item_tags WHERE item_id = ?",
        arguments: [itemId]
      )
    )
  }

  static func tags(forItem db: Database, itemId: String) throws -> [Tag] {
    let tags = try Row.fetchAll(
      db,
      sql: """
        SELECT t.* FROM tags t
        JOIN item_tags it ON it.tag_id = t.id
        WHERE it.item_id = ?
        """,
      arguments: [itemId]
    ).map(decode)
    return sorted(tags)
  }

  static func replaceLinks(_ db: Database, itemId: String, tagIds: Set<String>) throws {
    let current = try TagRepository.tagIds(forItem: db, itemId: itemId)
    for removed in current.subtracting(tagIds) {
      try db.execute(
        sql: "DELETE FROM item_tags WHERE item_id = ? AND tag_id = ?",
        arguments: [itemId, removed]
      )
    }
    for added in tagIds.subtracting(current) {
      try db.execute(
        sql: "INSERT INTO item_tags (item_id, tag_id) VALUES (?, ?)",
        arguments: [itemId, added]
      )
    }
  }

  static func itemIds(forTag db: Database, tagId: String) throws -> Set<String> {
    Set(
      try String.fetchAll(
        db,
        sql: "SELECT item_id FROM item_tags WHERE tag_id = ?",
        arguments: [tagId]
      )
    )
  }

  static func updateName(_ db: Database, id: String, name: String, nameKey: String) throws {
    try db.execute(
      sql: "UPDATE tags SET name = ?, name_key = ? WHERE id = ?",
      arguments: [name, nameKey, id]
    )
  }

  /// Переносит связи исходного тега на целевой без дублей на вещах.
  static func moveLinks(_ db: Database, from sourceId: String, to targetId: String) throws {
    try db.execute(
      sql: """
        INSERT OR IGNORE INTO item_tags (item_id, tag_id)
        SELECT item_id, ? FROM item_tags WHERE tag_id = ?
        """,
      arguments: [targetId, sourceId]
    )
    try db.execute(sql: "DELETE FROM item_tags WHERE tag_id = ?", arguments: [sourceId])
  }

  static func delete(_ db: Database, id: String) throws {
    try db.execute(sql: "DELETE FROM tags WHERE id = ?", arguments: [id])
  }

  /// Удаляет теги без связей; возвращает удалённые id.
  @discardableResult
  static func removeUnused(_ db: Database) throws -> Set<String> {
    let unused = Set(
      try String.fetchAll(
        db,
        sql: "SELECT id FROM tags WHERE id NOT IN (SELECT tag_id FROM item_tags)"
      )
    )
    guard !unused.isEmpty else { return [] }
    for id in unused {
      try db.execute(sql: "DELETE FROM tags WHERE id = ?", arguments: [id])
    }
    return unused
  }

  static func allTagIds(_ db: Database) throws -> Set<String> {
    Set(try String.fetchAll(db, sql: "SELECT id FROM tags"))
  }

  struct Suggestion {
    let tag: TagSuggestion
    let nameKey: String
  }

  /// Теги с количеством вещей. Сортировка и фильтр префикса — в сервисе.
  static func suggestions(_ db: Database) throws -> [Suggestion] {
    try Row.fetchAll(
      db,
      sql: """
        SELECT t.id, t.name, t.name_key, COUNT(it.item_id) AS item_count
        FROM tags t
        LEFT JOIN item_tags it ON it.tag_id = t.id
        GROUP BY t.id
        """
    ).map { row in
      Suggestion(
        tag: TagSuggestion(
          id: row["id"],
          name: row["name"],
          itemCount: row["item_count"]
        ),
        nameKey: row["name_key"]
      )
    }
  }

  static func sorted(_ tags: [Tag]) -> [Tag] {
    tags.sorted { left, right in
      let byName = NaturalSort.compare(left.name, right.name)
      return byName != 0 ? byName < 0 : left.id < right.id
    }
  }

  private static func decode(_ row: Row) -> Tag {
    Tag(id: row["id"], name: row["name"], nameKey: row["name_key"])
  }
}

/// Общий механизм прикрепления тегов внутри транзакции владельца.
struct TagLinker {
  struct Result {
    let oldTagIds: Set<String>
    let tagIds: Set<String>
    let createdTagIds: Set<String>
    let removedTagIds: Set<String>
  }

  /// Разбирает сырые имена, переиспользует существующие ключи и создаёт недостающие.
  static func replaceForItem(
    _ db: Database,
    itemId: String,
    rawNames: [String],
    ids: any IdGenerator
  ) throws -> Result {
    var keys: [String: TagKey] = [:]
    for raw in rawNames {
      let key = try TagKey.parse(raw)
      if keys[key.value] == nil {
        keys[key.value] = key
      }
    }

    var tagIds: Set<String> = []
    var created: Set<String> = []
    for key in keys.values {
      if let existing = try TagRepository.findOne(db, nameKey: key.value) {
        tagIds.insert(existing.id)
      } else {
        let tag = Tag(id: ids.next(), name: key.displayName, nameKey: key.value)
        try TagRepository.insert(db, tag: tag)
        tagIds.insert(tag.id)
        created.insert(tag.id)
      }
    }

    let oldTagIds = try TagRepository.tagIds(forItem: db, itemId: itemId)
    try TagRepository.replaceLinks(db, itemId: itemId, tagIds: tagIds)
    let removed = try TagRepository.removeUnused(db)
    return Result(
      oldTagIds: oldTagIds,
      tagIds: tagIds,
      createdTagIds: created,
      removedTagIds: removed
    )
  }
}
