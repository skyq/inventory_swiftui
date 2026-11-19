import Foundation
import GRDB
import InventoryCore
import Testing

@Suite("Схема БД и начальные данные")
struct SchemaTests {
  @Test("Создаются все таблицы схемы v1 и включаются foreign keys")
  func createsSchema() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let tables = try session.database.read { db in
      Set(
        try String.fetchAll(
          db,
          sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
        )
      )
    }
    let requiredTables: Set<String> = [
      "places", "statuses", "people", "items", "tags", "item_tags",
      "status_changes", "transfers", "settings",
    ]
    #expect(tables.isSuperset(of: requiredTables))
    // GRDB хранит служебный журнал миграций; в данных приложения его нет.
    #expect(tables.subtracting(requiredTables) == ["grdb_migrations"])

    let foreignKeys = try session.database.read { db in
      try Int.fetchOne(db, sql: "PRAGMA foreign_keys")
    }
    #expect(foreignKeys == 1)

    let version = try session.database.read { db in
      try Int.fetchOne(db, sql: "PRAGMA user_version")
    }
    #expect(version == 1)

    let placeColumns = try columns(of: "places", in: session.database)
    #expect(
      placeColumns == [
        "id", "parent_id", "name", "description", "photo_file", "thumb_file",
        "created_at", "updated_at",
      ]
    )
    let itemColumns = try columns(of: "items", in: session.database)
    #expect(itemColumns.contains("quantity"))
    #expect(itemColumns.contains("status_id"))
  }

  @Test("Внешний ключ parent_id отвергает несуществующего родителя")
  func rejectsMissingParent() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    #expect(throws: DatabaseError.self) {
      try session.database.write { db in
        try db.execute(
          sql: """
            INSERT INTO places (id, parent_id, name, description, photo_file, thumb_file, created_at, updated_at)
            VALUES ('p1', 'missing', 'Комната', '', 'photos/p1.jpg', 'thumbs/p1.jpg', 1, 1)
            """)
      }
    }
  }

  @Test("Сид создаёт статусы и настройки один раз")
  func seedsOnce() throws {
    let root = try TestSupport.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let preferences = InMemoryPreferencesStore()
    let coordinator = TestSupport.makeCoordinator(preferences: preferences)

    let first = try coordinator.createNew(root.path)
    let statuses = try first.database.read { db in
      try Row.fetchAll(db, sql: "SELECT id, name, sort_order FROM statuses ORDER BY sort_order")
        .map { (name: $0["name"] as String, order: $0["sort_order"] as Int) }
    }
    #expect(statuses.map(\.name) == SeedData.statusNames)
    #expect(statuses.map(\.order) == Array(0..<SeedData.statusNames.count))

    let settings = try first.database.read { db in
      try String.fetchAll(db, sql: "SELECT value FROM settings ORDER BY key")
    }
    #expect(settings.count == 3)
    #expect(Set(settings).count == 2)  // «В наличии» используется дважды.

    let defaults = try first.database.read { db in
      try Row.fetchAll(db, sql: "SELECT key, value FROM settings")
        .reduce(into: [String: String]()) { $0[$1["key"] as String] = $1["value"] as String }
    }
    #expect(defaults["default_status_id"] == defaults["return_status_id"])
    #expect(defaults["transfer_status_id"] != defaults["default_status_id"])

    let changedDefault = try #require(defaults["transfer_status_id"])
    try first.database.write { db in
      try db.execute(
        sql: "UPDATE settings SET value = ? WHERE key = 'default_status_id'",
        arguments: [changedDefault]
      )
    }
    first.close()

    let second = try coordinator.openExisting(root.path)
    defer { second.close() }
    #expect(
      try TestSupport.rowCount(second.database, table: "statuses") == SeedData.statusNames.count)
    #expect(try TestSupport.rowCount(second.database, table: "settings") == 3)
    let reopenedDefault = try second.database.read { db in
      try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = 'default_status_id'")
    }
    #expect(reopenedDefault == changedDefault)
  }

  @Test("Триггеры запрещают UPDATE и DELETE истории")
  func historyIsImmutable() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let statusId = try session.database.read { db in
      try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = 'default_status_id'")!
    }

    try session.database.write { db in
      try db.execute(
        sql: """
          INSERT INTO places (id, parent_id, name, description, photo_file, thumb_file, created_at, updated_at)
          VALUES ('p1', NULL, 'Шкаф', '', '', '', 1, 1)
          """)
      try db.execute(
        sql: """
          INSERT INTO items (id, name, description, notes, quantity, place_id, status_id,
                             photo_file, thumb_file, created_at, updated_at)
          VALUES ('i1', 'Куртка', '', '', 1, 'p1', ?, '', '', 1, 1)
          """,
        arguments: [statusId]
      )
      try db.execute(
        sql: """
          INSERT INTO status_changes (id, item_id, from_status_id, to_status_id, comment, created_at)
          VALUES ('sc1', 'i1', ?, ?, '', 1)
          """,
        arguments: [statusId, statusId]
      )
      try db.execute(
        sql: """
          INSERT INTO people (id, name, phone, notes, is_archived, created_at, updated_at)
          VALUES ('pe1', 'Анна', '', '', 0, 1, 1)
          """)
      try db.execute(
        sql: """
          INSERT INTO transfers (id, item_id, kind, person_id, comment, created_at)
          VALUES ('t1', 'i1', 'give', 'pe1', '', 1)
          """)
    }

    #expect(throws: DatabaseError.self) {
      try session.database.write { db in
        try db.execute(sql: "UPDATE status_changes SET comment = 'x' WHERE id = 'sc1'")
      }
    }
    #expect(throws: DatabaseError.self) {
      try session.database.write { db in
        try db.execute(sql: "DELETE FROM status_changes WHERE id = 'sc1'")
      }
    }
    #expect(throws: DatabaseError.self) {
      try session.database.write { db in
        try db.execute(sql: "UPDATE transfers SET comment = 'x' WHERE id = 't1'")
      }
    }
    #expect(throws: DatabaseError.self) {
      try session.database.write { db in
        try db.execute(sql: "DELETE FROM transfers WHERE id = 't1'")
      }
    }

    #expect(try TestSupport.rowCount(session.database, table: "status_changes") == 1)
    #expect(try TestSupport.rowCount(session.database, table: "transfers") == 1)
  }

  @Test("Индексы из ТЗ созданы")
  func createsIndexes() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let indexes = try session.database.read { db in
      Set(
        try String.fetchAll(
          db,
          sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%'"
        ))
    }
    #expect(
      indexes.isSuperset(of: [
        "items_place_id", "items_status_id", "places_parent_id", "item_tags_tag_id",
        "status_changes_item_created", "transfers_item_created", "transfers_person_id",
      ])
    )
  }

  @Test("Ограничения quantity, уникальности тегов и внешних ключей работают в SQLite")
  func enforcesConstraints() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let statusId = try session.database.read { db in
      try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = 'default_status_id'")!
    }

    try session.database.write { db in
      try db.execute(
        sql: """
          INSERT INTO places (id, parent_id, name, description, photo_file, thumb_file, created_at, updated_at)
          VALUES ('p1', NULL, 'Дом', '', '', '', 1, 1)
          """)
      try db.execute(
        sql: """
          INSERT INTO items (id, name, description, notes, quantity, place_id, status_id,
                             photo_file, thumb_file, created_at, updated_at)
          VALUES ('i1', 'Вещь', '', '', 1, 'p1', ?, '', '', 1, 1)
          """, arguments: [statusId])
      try db.execute(sql: "INSERT INTO tags (id, name, name_key) VALUES ('t1', 'Тег', 'тег')")
      try db.execute(sql: "INSERT INTO item_tags (item_id, tag_id) VALUES ('i1', 't1')")
      try db.execute(
        sql: """
          INSERT INTO people (id, name, phone, notes, is_archived, created_at, updated_at)
          VALUES ('pe1', 'Анна', '', '', 0, 1, 1)
          """)
    }

    #expect(throws: DatabaseError.self) {
      try session.database.write { db in
        try db.execute(sql: "UPDATE items SET quantity = 0 WHERE id = 'i1'")
      }
    }
    #expect(throws: DatabaseError.self) {
      try session.database.write { db in
        try db.execute(sql: "INSERT INTO item_tags (item_id, tag_id) VALUES ('i1', 't1')")
      }
    }
    #expect(throws: DatabaseError.self) {
      try session.database.write { db in
        try db.execute(sql: "INSERT INTO tags (id, name, name_key) VALUES ('t2', 'Тег 2', 'тег')")
      }
    }
    #expect(throws: DatabaseError.self) {
      try session.database.write { db in
        try db.execute(
          sql: """
            INSERT INTO items (id, name, description, notes, quantity, place_id, status_id,
                               photo_file, thumb_file, created_at, updated_at)
            VALUES ('i2', 'Без статуса', '', '', 1, 'p1', 'missing', '', '', 1, 1)
            """)
      }
    }
    #expect(throws: DatabaseError.self) {
      try session.database.write { db in
        try db.execute(
          sql: """
            INSERT INTO items (id, name, description, notes, quantity, place_id, status_id,
                               photo_file, thumb_file, created_at, updated_at)
            VALUES ('i3', 'Без места', '', '', 1, 'missing', ?, '', '', 1, 1)
            """, arguments: [statusId])
      }
    }
    #expect(throws: DatabaseError.self) {
      try session.database.write { db in
        try db.execute(sql: "INSERT INTO item_tags (item_id, tag_id) VALUES ('missing', 't1')")
      }
    }
    #expect(throws: DatabaseError.self) {
      try session.database.write { db in
        try db.execute(
          sql: """
            INSERT INTO transfers (id, item_id, kind, person_id, comment, created_at)
            VALUES ('tr1', 'i1', 'sell', 'pe1', '', 1)
            """)
      }
    }
    #expect(throws: DatabaseError.self) {
      try session.database.write { db in
        try db.execute(
          sql: """
            INSERT INTO transfers (id, item_id, kind, person_id, comment, created_at)
            VALUES ('tr2', 'i1', 'give', 'missing', '', 1)
            """)
      }
    }
  }

  @Test("После повторного открытия foreign_keys снова включены")
  func reopensWithForeignKeys() throws {
    let root = try TestSupport.temporaryDirectory()
    let coordinator = TestSupport.makeCoordinator()
    let first = try coordinator.createNew(root.path)
    first.close()

    let second = try coordinator.openExisting(root.path)
    defer {
      second.close()
      try? FileManager.default.removeItem(at: root)
    }

    let foreignKeys = try second.database.read { db in
      try Int.fetchOne(db, sql: "PRAGMA foreign_keys")
    }
    #expect(foreignKeys == 1)
    #expect(throws: DatabaseError.self) {
      try second.database.write { db in
        try db.execute(
          sql: """
            INSERT INTO places (id, parent_id, name, description, photo_file, thumb_file, created_at, updated_at)
            VALUES ('broken', 'missing', 'Место', '', '', '', 1, 1)
            """)
      }
    }
  }

  private func columns(of table: String, in database: InventoryDatabase) throws -> [String] {
    try database.read { db in
      try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map { $0["name"] as String }
    }
  }
}
