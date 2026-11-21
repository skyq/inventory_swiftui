import Foundation
import InventoryCore
import Testing

@Suite("Поиск: живой индекс")
struct SearchIndexIntegrationTests {
  private func ids(_ session: StorageSession, _ query: String) -> Set<String> {
    Set(session.search.search(query).map(\.itemId))
  }

  @Test("Создание вещи сразу попадает в индекс")
  func indexesCreatedItem() async throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let item = try TestSupport.createItem(session, name: "Куртка")
    await session.search.waitForIdle()

    #expect(ids(session, "куртка") == [item.item.id])
    #expect(ids(session, "куртку") == [item.item.id])
  }

  @Test("Переименование вещи убирает старое имя и добавляет новое")
  func updatesItemName() async throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let item = try TestSupport.createItem(session, name: "Куртка")
    await session.search.waitForIdle()

    _ = try session.items.updateDetails(
      ItemDetailsUpdate(
        id: item.item.id,
        name: "Пальто",
        description: "",
        notes: "",
        quantity: 1,
        placeId: nil,
        tags: [],
        newPhoto: nil
      )
    )
    await session.search.waitForIdle()

    #expect(ids(session, "куртка").isEmpty)
    #expect(ids(session, "пальто") == [item.item.id])
  }

  @Test("Переименование места обновляет путь у вложенных вещей")
  func updatesPlaceAncestors() async throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let home = try TestSupport.createPlace(session, name: "Дом")
    let wardrobe = try TestSupport.createPlace(session, name: "Шкаф", parentId: home.id)
    let item = try TestSupport.createItem(session, name: "Куртка", placeId: wardrobe.id)
    await session.search.waitForIdle()

    #expect(ids(session, "дом") == [item.item.id])

    _ = try session.places.updateDetails(
      PlaceDetailsUpdate(
        id: home.id,
        name: "Квартира",
        description: "",
        parentId: nil,
        newPhoto: nil
      )
    )
    await session.search.waitForIdle()

    #expect(ids(session, "дом").isEmpty)
    #expect(ids(session, "квартира") == [item.item.id])
    #expect(ids(session, "шкаф") == [item.item.id])
  }

  @Test("Объединение тегов обновляет документы обеих вещей")
  func updatesMergedTags() async throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let first = try TestSupport.createItem(session, name: "Лампа", tags: ["Свет"])
    let second = try TestSupport.createItem(session, name: "Стол", tags: ["Мебель"])
    await session.search.waitForIdle()

    let light = try #require(first.tags.first { $0.name == "Свет" })
    let furniture = try #require(second.tags.first { $0.name == "Мебель" })
    _ = try session.tags.merge(light.id, into: furniture.id, resultName: "Обстановка")
    await session.search.waitForIdle()

    #expect(ids(session, "свет").isEmpty)
    #expect(ids(session, "мебель").isEmpty)
    #expect(ids(session, "обстановка") == [first.item.id, second.item.id])
  }

  @Test("Имя человека из передачи попадает в индекс и обновляется")
  func updatesPersonNames() async throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let item = try TestSupport.createItem(session, name: "Дрель")
    let transferStatus = try session.statusSettings.settings().transferStatusId
    let given = try session.actions.give(
      GiveCommand(
        itemId: item.item.id,
        person: PersonChoice.new(name: "Антон", phone: "", notes: "", duplicateConfirmed: false),
        statusId: transferStatus
      )
    )
    await session.search.waitForIdle()

    #expect(ids(session, "антон") == [item.item.id])
    let person = try #require(try session.people.lastGivenPersonId(itemId: item.item.id))
    #expect(ids(session, "anton").isEmpty)

    _ = try session.people.update(
      PersonUpdate(id: person, name: "Борис", phone: "", notes: "")
    )
    await session.search.waitForIdle()

    #expect(ids(session, "антон").isEmpty)
    #expect(ids(session, "борис") == [given.item.id])
  }

  @Test("Архивный человек остаётся в индексе")
  func keepsArchivedPerson() async throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let item = try TestSupport.createItem(session, name: "Дрель")
    let transferStatus = try session.statusSettings.settings().transferStatusId
    _ = try session.actions.give(
      GiveCommand(
        itemId: item.item.id,
        person: PersonChoice.new(name: "Антон", phone: "", notes: "", duplicateConfirmed: false),
        statusId: transferStatus
      )
    )
    let personId = try #require(try session.people.lastGivenPersonId(itemId: item.item.id))
    _ = try session.people.archive(personId)
    await session.search.waitForIdle()

    #expect(ids(session, "антон") == [item.item.id])
  }

  @Test("Откат изменения не меняет индекс")
  func rollbackKeepsIndex() async throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let item = try TestSupport.createItem(session, name: "Дрель")
    await session.search.waitForIdle()
    try session.database.write { db in
      try db.execute(
        sql: """
          CREATE TRIGGER fail_item_update BEFORE UPDATE ON items
          WHEN OLD.id = '\(item.item.id)'
          BEGIN SELECT RAISE(ABORT, 'boom'); END;
          """)
    }

    do {
      _ = try session.items.updateDetails(
        ItemDetailsUpdate(
          id: item.item.id,
          name: "Перфоратор",
          description: "",
          notes: "",
          quantity: 1,
          placeId: nil,
          tags: [],
          newPhoto: nil
        )
      )
      Issue.record("Ожидалась ошибка записи")
    } catch {}
    await session.search.waitForIdle()

    #expect(ids(session, "дрель") == [item.item.id])
    #expect(ids(session, "перфоратор").isEmpty)
  }

  @Test("Полная пересборка подхватывает изменения в обход шины")
  func rebuildReflectsDirectChange() async throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let item = try TestSupport.createItem(session, name: "Куртка")
    await session.search.waitForIdle()
    try session.database.write { db in
      try db.execute(
        sql: "UPDATE items SET name = 'Пальто' WHERE id = ?",
        arguments: [item.item.id]
      )
    }

    #expect(ids(session, "пальто").isEmpty)
    await session.search.rebuild()
    #expect(ids(session, "пальто") == [item.item.id])
    #expect(ids(session, "куртка").isEmpty)
  }
}
