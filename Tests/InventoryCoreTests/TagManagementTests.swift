import Foundation
import GRDB
import InventoryCore
import Testing

@Suite("Теги: управление справочником")
struct TagManagementTests {
  @Test("Список с количеством вещей")
  func listsCounts() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    _ = try TestSupport.createItem(session, name: "Лампа", tags: ["Свет", "Дом"])
    _ = try TestSupport.createItem(session, name: "Стол", tags: ["дом"])

    let tags = try session.tags.listWithCounts()
    #expect(tags.map(\.name) == ["Дом", "Свет"])
    #expect(tags.first { $0.name == "Дом" }?.itemCount == 2)
    #expect(tags.first { $0.name == "Свет" }?.itemCount == 1)
  }

  @Test("Переименование и конфликт ключа без автоматического слияния")
  func renamesAndConflicts() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let item = try TestSupport.createItem(session, name: "Лампа", tags: ["Ёлка", "Свет"])
    let tree = try #require(item.tags.first { $0.name == "Ёлка" })
    let light = try #require(item.tags.first { $0.name == "Свет" })

    let renamed = try session.tags.rename(tree.id, to: "Новогодняя")
    #expect(renamed.name == "Новогодняя")
    #expect(try session.tags.tagsForItem(item.item.id).map(\.name) == ["Новогодняя", "Свет"])

    do {
      _ = try session.tags.rename(tree.id, to: "свет")
      Issue.record("Конфликт ключа должен требовать объединения")
    } catch let error as AppException {
      #expect(error.code == .tagNameConflict)
      #expect(error.string("tagId") == light.id)
    }
  }

  @Test("Объединение переносит связи без дублей")
  func mergesWithoutDuplicates() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let first = try TestSupport.createItem(session, name: "Лампа", tags: ["Свет", "Дом"])
    let second = try TestSupport.createItem(session, name: "Стол", tags: ["Дом"])
    let light = try #require(first.tags.first { $0.name == "Свет" })
    let home = try #require(first.tags.first { $0.name == "Дом" })

    let merged = try session.tags.merge(light.id, into: home.id)
    #expect(merged.id == home.id)
    #expect(merged.name == "Дом")

    let remaining = try session.tags.listWithCounts()
    #expect(remaining.count == 1)
    #expect(remaining.first?.itemCount == 2)

    #expect(try session.tags.tagsForItem(first.item.id).map(\.name) == ["Дом"])
    #expect(try session.tags.tagsForItem(second.item.id).map(\.name) == ["Дом"])
    #expect(try TestSupport.rowCount(session.database, table: "item_tags") == 2)
  }

  @Test("Слияние с именем третьего тега отклоняется (D07)")
  func mergeRejectsThirdName() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let item = try TestSupport.createItem(session, name: "Лампа", tags: ["А", "Б", "В"])
    let a = try #require(item.tags.first { $0.name == "А" })
    let b = try #require(item.tags.first { $0.name == "Б" })
    let v = try #require(item.tags.first { $0.name == "В" })

    do {
      _ = try session.tags.merge(a.id, into: b.id, resultName: "в")
      Issue.record("Итоговое имя не должно молча сливаться с третьим тегом")
    } catch let error as AppException {
      #expect(error.code == .tagNameConflict)
      #expect(error.string("tagId") == v.id)
    }

    // Исходные теги не тронуты.
    #expect(try session.tags.listWithCounts().count == 3)
  }

  @Test("Сбой объединения возвращает оба тега и связи")
  func mergeRollsBack() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let item = try TestSupport.createItem(session, name: "Лампа", tags: ["Свет", "Дом"])
    let light = try #require(item.tags.first { $0.name == "Свет" })
    let home = try #require(item.tags.first { $0.name == "Дом" })
    try session.database.write { db in
      try db.execute(
        sql: """
          CREATE TRIGGER fail_tag_delete BEFORE DELETE ON tags
          WHEN OLD.id = '\(light.id)'
          BEGIN SELECT RAISE(ABORT, 'boom'); END;
          """)
    }

    do {
      _ = try session.tags.merge(light.id, into: home.id)
      Issue.record("Ожидалась ошибка записи")
    } catch {}

    #expect(try session.tags.listWithCounts().map(\.name) == ["Дом", "Свет"])
    #expect(Set(try session.tags.tagsForItem(item.item.id).map(\.name)) == ["Свет", "Дом"])
  }

  @Test("Сбой удаления оставляет тег и связи")
  func deleteRollsBack() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let item = try TestSupport.createItem(session, name: "Лампа", tags: ["Свет"])
    let light = try #require(item.tags.first)
    try session.database.write { db in
      try db.execute(
        sql: """
          CREATE TRIGGER fail_item_tag_delete BEFORE DELETE ON item_tags
          BEGIN SELECT RAISE(ABORT, 'boom'); END;
          """)
    }

    do {
      _ = try session.tags.delete(light.id)
      Issue.record("Ожидалась ошибка записи")
    } catch {}

    #expect(try session.tags.listWithCounts().map(\.name) == ["Свет"])
    #expect(try session.tags.tagsForItem(item.item.id).map(\.name) == ["Свет"])
  }

  @Test("Удаление снимает тег со всех вещей и возвращает количество")
  func deletesFromAllItems() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let first = try TestSupport.createItem(session, name: "Лампа", tags: ["Свет", "Дом"])
    _ = try TestSupport.createItem(session, name: "Стол", tags: ["Свет"])
    let light = try #require(first.tags.first { $0.name == "Свет" })

    let affected = try session.tags.delete(light.id)
    #expect(affected.itemCount == 2)
    #expect(affected.itemIds.count == 2)
    #expect(try session.tags.listWithCounts().map(\.name) == ["Дом"])
    #expect(try session.tags.tagsForItem(first.item.id).map(\.name) == ["Дом"])
    #expect(try TestSupport.rowCount(session.database, table: "items") == 2)
  }
}
