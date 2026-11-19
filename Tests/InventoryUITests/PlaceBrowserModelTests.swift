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
    let browser = PlaceBrowserModel(places: service, photos: FakePhotoStore())

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
    let browser = PlaceBrowserModel(places: service, photos: FakePhotoStore())
    await browser.start()
    #expect(browser.children.map(\.name) == ["Полка 1", "Полка 2", "Полка 10"])
  }

  @Test("Непустое место не удаляется, показывается причина")
  func refusesToDeleteNonEmptyPlace() async {
    let a = makeTestPlace(id: "a", name: "Дом")
    let b = makeTestPlace(id: "b", parentId: "a", name: "Комната")
    let service = FakePlaceService(initial: [a, b])
    let browser = PlaceBrowserModel(places: service, photos: FakePhotoStore())

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
    let browser = PlaceBrowserModel(places: service, photos: FakePhotoStore())

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
      photos: FakePhotoStore()
    )
    await browser.start()
    #expect(browser.thumbnailURL(for: place)?.lastPathComponent == "a.jpg")
    #expect(
      browser.thumbnailURL(for: makeTestPlace(id: "x", name: "Без фото", photo: false)) == nil)
  }
}
