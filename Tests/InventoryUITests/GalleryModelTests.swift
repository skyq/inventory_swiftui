import Foundation
import InventoryCore
import Testing

@testable import InventoryUI

@Suite("Модель галереи")
@MainActor
struct GalleryModelTests {
  @Test("Загружает вещи, архивные статусы и фильтры")
  func loadsInitialData() async {
    let items = FakeItemService(initial: [
      makeTestItemDetails(id: "i1", name: "Лампа", placeId: "p1", tagNames: ["Свет"]),
      makeTestItemDetails(id: "i2", name: "Книга", tagNames: ["Бумага"]),
    ])
    let statuses = FakeStatusService(statuses: [
      makeTestStatus(id: "status-1", name: "В наличии"),
      makeTestStatus(id: "status-2", name: "Архивный", archived: true),
    ])
    let tags = FakeTagService(suggestions: [
      TagSuggestion(id: "tag-Свет", name: "Свет", itemCount: 1),
      TagSuggestion(id: "tag-Бумага", name: "Бумага", itemCount: 1),
    ])
    let model = makeModel(
      items: items,
      statuses: statuses,
      tags: tags,
      places: FakePlaceService(initial: [makeTestPlace(id: "p1", name: "Дом")])
    )

    await model.start()
    #expect(model.entries.map(\.item.id).sorted() == ["i1", "i2"])
    #expect(model.availableStatuses.contains { $0.isArchived })
    #expect(model.availableTags.map(\.name) == ["Бумага", "Свет"])
    #expect(model.placeChoices.map(\.path) == ["Дом"])
    #expect(!model.hasActiveFilters)
  }

  @Test("Фильтры уходят в запрос и сохраняются в настройках")
  func passesFiltersAndPersists() async {
    let preferences = InMemoryPreferencesStore()
    let items = FakeItemService(initial: [
      makeTestItemDetails(id: "i1", name: "Лампа", placeId: "p1", tagNames: ["Свет"]),
      makeTestItemDetails(id: "i2", name: "Книга", tagNames: ["Бумага"]),
    ])
    let model = makeModel(
      items: items,
      preferences: preferences,
      places: FakePlaceService(initial: [makeTestPlace(id: "p1", name: "Дом")])
    )
    await model.start()

    await model.setPlaceSelection(placeId: "p1", noPlace: false)
    await model.toggleStatus("status-1")
    await model.toggleTag("tag-Свет")

    let query = items.lastQuery
    #expect(query?.place == .placeSubtree("p1"))
    #expect(query?.statusIds == ["status-1"])
    #expect(query?.tagIds == ["tag-Свет"])
    #expect(model.entries.map(\.item.id) == ["i1"])

    let restored = GalleryStateCodec.load(from: preferences)
    #expect(restored.placeId == "p1")
    #expect(restored.statusIds == ["status-1"])
    #expect(restored.tagIds == ["tag-Свет"])
  }

  @Test("«Без места» и место взаимоисключающие")
  func noPlaceWins() async {
    let items = FakeItemService(initial: [
      makeTestItemDetails(id: "i1", name: "Ключи"),
      makeTestItemDetails(id: "i2", name: "Лампа", placeId: "p1"),
    ])
    let model = makeModel(items: items)
    await model.start()

    await model.setPlaceSelection(placeId: "p1", noPlace: false)
    await model.setPlaceSelection(placeId: "p1", noPlace: true)

    #expect(model.state.noPlace)
    #expect(model.state.placeId == nil)
    #expect(items.lastQuery?.place == .noPlace)
    #expect(model.entries.map(\.item.id) == ["i1"])
  }

  @Test("Размер плитки и сортировка переживают перезапуск")
  func persistsViewSettings() async {
    let preferences = InMemoryPreferencesStore()
    let model = makeModel(items: FakeItemService(), preferences: preferences)
    await model.start()

    model.setTileSize(.large)
    await model.setSort(.name)
    await model.setDirection(.asc)

    let restored = GalleryStateCodec.load(from: preferences)
    #expect(restored.tileSize == .large)
    #expect(restored.sort == .name)
    #expect(restored.direction == .asc)
  }

  @Test("Сброс очищает фильтры, но не вид и сортировку")
  func resetKeepsViewSettings() async {
    let model = makeModel(items: FakeItemService())
    await model.start()
    model.setTileSize(.small)
    await model.setSort(.name)
    await model.setPlaceSelection(placeId: "p1", noPlace: false)

    await model.resetFilters()
    #expect(!model.hasActiveFilters)
    #expect(model.state.tileSize == .small)
    #expect(model.state.sort == .name)
  }

  @Test("Сохранение вида не сбрасывает выбранный режим")
  func keepsSavedMode() async {
    let preferences = InMemoryPreferencesStore()
    preferences.setString(GalleryMode.places.rawValue, forKey: PreferenceKeys.galleryMode)
    let model = makeModel(items: FakeItemService(), preferences: preferences)
    await model.start()

    model.setTileSize(.large)

    let restored = GalleryStateCodec.load(from: preferences)
    #expect(restored.mode == .places)
    #expect(restored.tileSize == .large)
  }

  @Test("Исчезнувшие id фильтров очищаются при открытии")
  func sanitizesStaleIds() async {
    let preferences = InMemoryPreferencesStore()
    preferences.setString("missing-place", forKey: PreferenceKeys.galleryFilterPlaceId)
    preferences.setString("[\"missing-status\"]", forKey: PreferenceKeys.galleryFilterStatusIds)
    preferences.setString("[\"missing-tag\"]", forKey: PreferenceKeys.galleryFilterTagIds)

    let model = makeModel(items: FakeItemService(), preferences: preferences)
    await model.start()

    #expect(model.state.placeId == nil)
    #expect(model.state.statusIds.isEmpty)
    #expect(model.state.tagIds.isEmpty)
  }

  @Test("Выбранная вещь загружается в карточку и закрывается по Esc")
  func selectsAndClosesInspector() async {
    let details = makeTestItemDetails(id: "i1", name: "Лампа", tagNames: ["Свет"])
    let model = makeModel(items: FakeItemService(initial: [details]))
    await model.start()

    await model.select(model.entries[0])
    #expect(model.showsInspector)
    #expect(model.selected?.item.id == "i1")
    #expect(model.selected?.tags.map(\.name) == ["Свет"])

    model.clearSelection()
    #expect(!model.showsInspector)
    #expect(model.selectedItemId == "i1")
  }

  private func makeModel(
    items: FakeItemService,
    preferences: InMemoryPreferencesStore = InMemoryPreferencesStore(),
    statuses: FakeStatusService = FakeStatusService(),
    tags: FakeTagService = FakeTagService(),
    places: FakePlaceService = FakePlaceService()
  ) -> GalleryModel {
    GalleryModel(
      items: items,
      tags: tags,
      statuses: statuses,
      places: places,
      photos: FakePhotoStore(),
      preferences: preferences
    )
  }
}
