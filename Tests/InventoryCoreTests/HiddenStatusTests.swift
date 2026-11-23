import Foundation
import InventoryCore
import Testing

@Suite("Скрытые статусы")
struct HiddenStatusTests {
  @Test("Скрытый статус не попадает в галерею и поиск, пока фильтр не включён")
  func hiddenStatusIsExcluded() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let lost = try session.statuses.create(name: "Утеряна")
    _ = try session.statuses.setHidden(lost.id, hidden: true)
    let visible = try makeItem(session, "Куртка")
    let hidden = try makeItem(session, "Ключи", statusId: lost.id)

    let defaultList = try session.items.list(GalleryQuery())
    #expect(defaultList.map(\.item.id) == [visible.item.id])

    let withHidden = try session.items.list(GalleryQuery(showHidden: true))
    #expect(Set(withHidden.map(\.item.id)) == [visible.item.id, hidden.item.id])

    let explicit = try session.items.list(GalleryQuery(statusIds: [lost.id]))
    #expect(explicit.map(\.item.id) == [hidden.item.id])

    let searched = try session.items.list(
      GalleryQuery(searchItemIds: [hidden.item.id])
    )
    #expect(searched.isEmpty)
  }

  @Test("Снятие скрытия возвращает вещи в галерею, данные не меняются")
  func unhideRestoresItems() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let lost = try session.statuses.create(name: "Утеряна")
    let item = try makeItem(session, "Ключи", statusId: lost.id)
    let before = try session.items.get(item.item.id)

    let hidden = try session.statuses.setHidden(lost.id, hidden: true)
    #expect(hidden.isHidden)
    #expect(try session.items.list(GalleryQuery()).isEmpty)

    let shown = try session.statuses.setHidden(lost.id, hidden: false)
    #expect(!shown.isHidden)
    #expect(try session.items.list(GalleryQuery()).map(\.item.id) == [item.item.id])
    #expect(try session.items.get(item.item.id).status.id == before.status.id)
  }

  @Test("Флаг скрытия сохраняется в базе и не трогает архив")
  func flagPersists() throws {
    let (session, root) = try TestSupport.makeSession()
    defer {
      session.close()
      try? FileManager.default.removeItem(at: root)
    }

    let lost = try session.statuses.create(name: "Утеряна")
    _ = try session.statuses.setHidden(lost.id, hidden: true)
    let stored = try session.statuses.get(lost.id)
    #expect(stored.isHidden)
    #expect(!stored.isArchived)
  }

  private func makeItem(
    _ session: StorageSession,
    _ name: String,
    statusId: String? = nil
  ) throws -> ItemDetails {
    try session.items.create(
      ItemCreate(
        name: name,
        placeId: nil,
        statusId: statusId,
        tags: [],
        photo: TestSupport.makePhoto()
      )
    )
  }
}
