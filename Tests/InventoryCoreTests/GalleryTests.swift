import Foundation
import InventoryCore
import Testing

@Suite("Галерея: фильтры и сортировка")
struct GalleryTests {
  @Test("Место с потомками включает вещи полок, placeOnly — только прямые")
  func placeFilters() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let home = try session.places.create(
      PlaceCreate(name: "Дом", description: "", parentId: nil, photo: TestSupport.makePhoto())
    )
    let shelf = try session.places.create(
      PlaceCreate(name: "Полка", description: "", parentId: home.id, photo: TestSupport.makePhoto())
    )
    let inHome = try makeItem(session, "Лампа", placeId: home.id)
    let inShelf = try makeItem(session, "Книга", placeId: shelf.id)
    _ = try makeItem(session, "Ключи", placeId: nil)

    let subtree = try session.items.list(
      GalleryQuery(place: .placeSubtree(home.id))
    )
    #expect(Set(subtree.map(\.item.id)) == [inHome.item.id, inShelf.item.id])

    let direct = try session.items.list(
      GalleryQuery(place: .placeOnly(home.id))
    )
    #expect(direct.map(\.item.id) == [inHome.item.id])
  }

  @Test("«Без места» не включает размещённые вещи")
  func noPlaceFilter() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let place = try session.places.create(
      PlaceCreate(name: "Дом", description: "", parentId: nil, photo: TestSupport.makePhoto())
    )
    let placed = try makeItem(session, "Лампа", placeId: place.id)
    let homeless = try makeItem(session, "Ключи", placeId: nil)

    let result = try session.items.list(GalleryQuery(place: .noPlace))
    #expect(result.map(\.item.id) == [homeless.item.id])
    #expect(!result.contains { $0.item.id == placed.item.id })
  }

  @Test("Статусы фильтруются множеством, включая архивные")
  func statusFilter() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let statuses = try session.statuses.list(includeArchived: true)
    let first = statuses[0]
    let archived = statuses[1]
    try session.database.write { db in
      try db.execute(
        sql: "UPDATE statuses SET is_archived = 1 WHERE id = ?",
        arguments: [archived.id]
      )
    }
    let activeItem = try makeItem(session, "Лампа", statusId: first.id)
    let archivedItem = try makeItem(session, "Книга", statusId: first.id)
    // Архивный статус нельзя назначить новой вещи; переносим существующую.
    try session.database.write { db in
      try db.execute(
        sql: "UPDATE items SET status_id = ? WHERE id = ?",
        arguments: [archived.id, archivedItem.item.id]
      )
    }

    let result = try session.items.list(
      GalleryQuery(statusIds: [archived.id])
    )
    #expect(result.map(\.item.id) == [archivedItem.item.id])
    #expect(!result.contains { $0.item.id == activeItem.item.id })
    #expect(result.first?.statusArchived == true)
  }

  @Test("Несколько тегов объединяются по AND")
  func tagsAreAnd() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let both = try makeItem(session, "Лампа", tags: ["Свет", "Дом"])
    _ = try makeItem(session, "Стол", tags: ["Дом"])
    _ = try makeItem(session, "Книга", tags: ["Свет"])

    let tagIds = Set(both.tags.map(\.id))
    let result = try session.items.list(GalleryQuery(tagIds: tagIds))
    #expect(result.map(\.item.id) == [both.item.id])
  }

  @Test("Сортировка по имени естественная, направление и id tie-break детерминированы")
  func nameSort() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let ten = try makeItem(session, "Полка 10")
    let two = try makeItem(session, "Полка 2")
    let one = try makeItem(session, "полка 1")

    let ascending = try session.items.list(
      GalleryQuery(sort: .name, direction: .asc)
    )
    #expect(ascending.map(\.item.id) == [one.item.id, two.item.id, ten.item.id])

    let descending = try session.items.list(
      GalleryQuery(sort: .name, direction: .desc)
    )
    #expect(descending.map(\.item.id) == [ten.item.id, two.item.id, one.item.id])
  }

  @Test("Дата добавления: направление по createdAt, затем id ASC")
  func createdAtSort() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let first = try makeItem(session, "Первая")
    let second = try makeItem(session, "Вторая")
    let third = try makeItem(session, "Третья")
    try session.database.write { db in
      try db.execute(
        sql: "UPDATE items SET created_at = 100 WHERE id = ?", arguments: [first.item.id])
      try db.execute(
        sql: "UPDATE items SET created_at = 200 WHERE id = ?", arguments: [second.item.id])
      try db.execute(
        sql: "UPDATE items SET created_at = 300 WHERE id = ?", arguments: [third.item.id])
    }

    let desc = try session.items.list(GalleryQuery(sort: .createdAt, direction: .desc))
    #expect(desc.map(\.item.id) == [third.item.id, second.item.id, first.item.id])

    let asc = try session.items.list(GalleryQuery(sort: .createdAt, direction: .asc))
    #expect(asc.map(\.item.id) == [first.item.id, second.item.id, third.item.id])
  }

  @Test("Ограничение searchItemIds: nil, пусто и пересечение")
  func searchConstraint() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let first = try makeItem(session, "Первая")
    let second = try makeItem(session, "Вторая")

    #expect(try session.items.list(GalleryQuery(searchItemIds: nil)).count == 2)
    #expect(try session.items.list(GalleryQuery(searchItemIds: [])).isEmpty)
    let limited = try session.items.list(
      GalleryQuery(searchItemIds: [second.item.id])
    )
    #expect(limited.map(\.item.id) == [second.item.id])
    #expect(!limited.contains { $0.item.id == first.item.id })
  }

  @Test("Несуществующее место в фильтре — validationNotFound")
  func missingPlaceFilter() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    do {
      _ = try session.items.list(GalleryQuery(place: .placeSubtree("missing")))
      Issue.record("Ожидалась ошибка validationNotFound")
    } catch let error as AppException {
      #expect(error.code == .validationNotFound)
      #expect(error.string("entity") == "place")
    }
  }

  private func makeItem(
    _ session: StorageSession,
    _ name: String,
    placeId: String? = nil,
    statusId: String? = nil,
    tags: [String] = []
  ) throws -> ItemDetails {
    try session.items.create(
      ItemCreate(
        name: name,
        placeId: placeId,
        statusId: statusId,
        tags: tags,
        photo: TestSupport.makePhoto()
      )
    )
  }
}
