import Foundation
import GRDB
import InventoryCore
import Testing

@Suite("Теги: нормализация и связи")
struct TagTests {
  @Test("Ключ схлопывает пробелы, регистр и различия е/ё")
  func normalizesKey() throws {
    let first = try TagKey.parse("  Ёлка   у  окна ")
    let second = try TagKey.parse("ЕЛКА У ОКНА")
    #expect(first.displayName == "Ёлка у окна")
    #expect(first.value == "елка у окна")
    #expect(second.value == first.value)

    let third = try TagKey.parse("моя\tполка\nверхняя")
    #expect(third.displayName == "моя полка верхняя")
  }

  @Test("Пустой и слишком длинный тег отклоняются")
  func rejectsInvalidKeys() {
    #expect(throws: AppException.self) { _ = try TagKey.parse("   ") }
    #expect(throws: AppException.self) {
      _ = try TagKey.parse(String(repeating: "я", count: TagKey.maxLength + 1))
    }
  }

  @Test("Ёлка, елка и ЕЛКА дают один тег с первым написанием")
  func createsSingleTag() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let item = try makeItem(session, name: "Лампа", tags: [" Ёлка ", "елка", "ЕЛКА"])
    #expect(item.tags.count == 1)
    #expect(item.tags.first?.name == "Ёлка")
    #expect(try TestSupport.rowCount(session.database, table: "tags") == 1)
  }

  @Test("Повторное прикрепление переиспользует id и исходное написание")
  func reusesExistingTag() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let first = try makeItem(session, name: "Лампа", tags: ["Ёлка"])
    let second = try makeItem(session, name: "Стол", tags: ["елка"])
    #expect(first.tags.first?.id == second.tags.first?.id)
    #expect(second.tags.first?.name == "Ёлка")
    #expect(try TestSupport.rowCount(session.database, table: "tags") == 1)
  }

  @Test("Снятие тега удаляет неиспользуемый тег")
  func removesUnusedTagAfterUpdate() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let created = try makeItem(session, name: "Лампа", tags: ["Ёлка", "Свет"])
    #expect(try TestSupport.rowCount(session.database, table: "tags") == 2)

    let updated = try session.items.updateDetails(
      ItemDetailsUpdate(
        id: created.item.id,
        name: created.item.name,
        description: "",
        notes: "",
        quantity: 1,
        placeId: nil,
        tags: ["Свет"],
        newPhoto: nil
      )
    )
    #expect(updated.tags.map(\.name) == ["Свет"])
    #expect(try TestSupport.rowCount(session.database, table: "tags") == 1)
  }

  @Test("Сбой связи тегов откатывает новые теги")
  func rollsBackNewTagsOnFailure() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let created = try makeItem(session, name: "Лампа")
    try session.database.write { db in
      try db.execute(
        sql: """
          CREATE TRIGGER fail_item_tags BEFORE INSERT ON item_tags
          WHEN NEW.item_id = '\(created.item.id)'
          BEGIN SELECT RAISE(ABORT, 'forced failure'); END;
          """)
    }

    #expect(throws: DatabaseError.self) {
      _ = try session.items.updateDetails(
        ItemDetailsUpdate(
          id: created.item.id,
          name: created.item.name,
          description: "",
          notes: "",
          quantity: 1,
          placeId: nil,
          tags: ["Новый"],
          newPhoto: nil
        )
      )
    }
    #expect(try TestSupport.rowCount(session.database, table: "tags") == 0)
  }

  @Test("Автодополнение идёт по префиксу и количеству использований")
  func suggestsByPrefixAndCount() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    _ = try makeItem(session, name: "Лампа", tags: ["Ёлка", "Ёлочные игрушки"])
    _ = try makeItem(session, name: "Стол", tags: ["Ёлка"])
    _ = try makeItem(session, name: "Стул", tags: ["Свет"])

    let suggestions = try session.tags.suggest("ел")
    #expect(suggestions.map(\.name) == ["Ёлка", "Ёлочные игрушки"])
    #expect(suggestions.first?.itemCount == 2)

    let all = try session.tags.suggest("")
    #expect(all.first?.name == "Ёлка")
  }

  private func makeItem(
    _ session: StorageSession,
    name: String,
    tags: [String] = []
  ) throws -> ItemDetails {
    try session.items.create(
      ItemCreate(
        name: name,
        placeId: nil,
        statusId: nil,
        tags: tags,
        photo: TestSupport.makePhoto()
      )
    )
  }
}
