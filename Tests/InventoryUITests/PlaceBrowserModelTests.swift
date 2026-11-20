import Foundation
import InventoryCore
import Testing

@testable import InventoryUI

@Suite("Режим «По местам»")
@MainActor
struct PlaceBrowserModelTests {
  @Test("Навигация по трём уровням и возврат к корню")
  func navigatesHierarchy() async {
    let a = makeTestPlace(id: "a", name: "Дом")
    let b = makeTestPlace(id: "b", parentId: "a", name: "Комната")
    let c = makeTestPlace(id: "c", parentId: "b", name: "Шкаф")
    let service = FakePlaceService(initial: [c, b, a])
    let browser = PlaceBrowserModel(
      places: service, photos: FakePhotoStore(), items: FakeItemService())

    await browser.start()
    #expect(browser.currentParentId == nil)
    #expect(browser.children.map(\.id) == ["a"])
    #expect(!browser.showsInspector)

    await browser.open(a)
    #expect(browser.currentParentId == "a")
    #expect(browser.currentPath.map(\.id) == ["a"])
    #expect(browser.children.map(\.id) == ["b"])
    #expect(browser.selectedPlace?.id == "a")
    #expect(browser.showsInspector)
    #expect(browser.selectedPath.map(\.id) == ["a"])

    await browser.navigate(to: b)
    #expect(browser.currentPath.map(\.id) == ["a", "b"])
    #expect(browser.children.map(\.id) == ["c"])

    await browser.openRoot()
    #expect(browser.currentParentId == nil)
    #expect(browser.currentPath.isEmpty)
    #expect(browser.showsInspector == false)
  }

  @Test("Дочерние места приходят в естественном порядке")
  func keepsNaturalOrder() async {
    let service = FakePlaceService(initial: [
      makeTestPlace(id: "10", name: "Полка 10"),
      makeTestPlace(id: "2", name: "Полка 2"),
      makeTestPlace(id: "1", name: "Полка 1"),
    ])
    let browser = PlaceBrowserModel(
      places: service, photos: FakePhotoStore(), items: FakeItemService())
    await browser.start()
    #expect(browser.children.map(\.name) == ["Полка 1", "Полка 2", "Полка 10"])
  }

  @Test("Непустое место не удаляется, показывается причина")
  func refusesToDeleteNonEmptyPlace() async {
    let a = makeTestPlace(id: "a", name: "Дом")
    let b = makeTestPlace(id: "b", parentId: "a", name: "Комната")
    let service = FakePlaceService(initial: [a, b])
    let browser = PlaceBrowserModel(
      places: service, photos: FakePhotoStore(), items: FakeItemService())

    await browser.open(a)
    browser.requestDeleteSelected()
    guard case .delete(let requested)? = browser.alert else {
      Issue.record("Ожидалось подтверждение удаления")
      return
    }
    #expect(requested.id == "a")

    await browser.confirmDelete(a)
    guard case .failure(let message)? = browser.alert else {
      Issue.record("Ожидалась ошибка удаления")
      return
    }
    #expect(!message.isEmpty)
    #expect(browser.currentParentId == "a")
    #expect(browser.children.map(\.id) == ["b"])
  }

  @Test("Ошибка чтения показывается и не очищает навигацию")
  func showsLoadError() async {
    let service = FakePlaceService(initial: [makeTestPlace(id: "a", name: "Дом")])
    service.childrenError = AppException(.storageCorrupt)
    let browser = PlaceBrowserModel(
      places: service, photos: FakePhotoStore(), items: FakeItemService())

    await browser.start()
    #expect(browser.children.isEmpty)
    #expect(browser.loadError?.code == .storageCorrupt)
    #expect(browser.currentParentId == nil)
  }

  @Test("Превью разрешается внутри папки данных")
  func resolvesThumbnailURL() async {
    let place = makeTestPlace(id: "a", name: "Дом")
    let browser = PlaceBrowserModel(
      places: FakePlaceService(initial: [place]),
      photos: FakePhotoStore(),
      items: FakeItemService()
    )
    await browser.start()
    #expect(browser.thumbnailURL(for: place)?.lastPathComponent == "a.jpg")
    #expect(
      browser.thumbnailURL(for: makeTestPlace(id: "x", name: "Без фото", photo: false)) == nil)
  }

  @Test("Уровень показывает только прямые вещи, корень — счётчик «Без места»")
  func showsDirectItemsAndNoPlaceCount() async {
    let a = makeTestPlace(id: "a", name: "Дом")
    let b = makeTestPlace(id: "b", parentId: "a", name: "Комната")
    let items = FakeItemService(initial: [
      makeTestItemDetails(id: "in-a", name: "Лампа", placeId: "a"),
      makeTestItemDetails(id: "in-b", name: "Книга", placeId: "b"),
      makeTestItemDetails(id: "none", name: "Ключи"),
    ])
    let browser = PlaceBrowserModel(
      places: FakePlaceService(initial: [a, b]),
      photos: FakePhotoStore(),
      items: items
    )

    await browser.start()
    #expect(browser.items.isEmpty)
    #expect(browser.noPlaceItemCount == 1)

    await browser.open(a)
    #expect(browser.items.map(\.item.id) == ["in-a"])
    #expect(browser.creationPlaceId == "a")

    await browser.navigate(to: b)
    #expect(browser.items.map(\.item.id) == ["in-b"])

    await browser.openNoPlace()
    #expect(browser.isNoPlaceLevel)
    #expect(browser.currentPath.isEmpty)
    #expect(browser.items.map(\.item.id) == ["none"])
    #expect(browser.creationPlaceId == nil)

    await browser.openRoot()
    #expect(!browser.isNoPlaceLevel)
    #expect(browser.noPlaceItemCount == 1)
  }

  @Test("Вещь открывается в карточке справа")
  func selectsItemInspector() async {
    let details = makeTestItemDetails(id: "i1", name: "Лампа", placeId: "a", tagNames: ["Свет"])
    let browser = PlaceBrowserModel(
      places: FakePlaceService(initial: [makeTestPlace(id: "a", name: "Дом")]),
      photos: FakePhotoStore(),
      items: FakeItemService(initial: [details])
    )
    await browser.open(makeTestPlace(id: "a", name: "Дом"))
    guard let first = browser.items.first else {
      Issue.record("Ожидалась вещь в месте")
      return
    }
    await browser.selectItem(first)

    #expect(browser.showsInspector)
    #expect(browser.selectedItem?.item.id == "i1")
    #expect(browser.selectedPlaceId == nil)
    #expect(browser.photoURL(for: details)?.lastPathComponent == "i1.jpg")

    browser.clearSelection()
    #expect(!browser.showsInspector)
  }
}
