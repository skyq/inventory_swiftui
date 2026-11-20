import Foundation
import InventoryCore
import Testing

@Suite("Настройки вида галереи")
struct GalleryStateTests {
  @Test("Сохранение и загрузка восстанавливают вид")
  func roundTrip() {
    let store = InMemoryPreferencesStore()
    let state = GalleryState(
      mode: .places,
      tileSize: .large,
      sort: .name,
      direction: .asc,
      placeId: "place-1",
      noPlace: false,
      statusIds: ["s2", "s1"],
      tagIds: ["t1"]
    )
    GalleryStateCodec.save(state, to: store)
    #expect(GalleryStateCodec.load(from: store) == state)
  }

  @Test("Повреждённые значения заменяются настройками по умолчанию")
  func corruptValues() {
    let store = InMemoryPreferencesStore()
    store.setString("unknown", forKey: PreferenceKeys.galleryMode)
    store.setString("huge", forKey: PreferenceKeys.galleryTileSize)
    store.setString("random", forKey: PreferenceKeys.gallerySort)
    store.setString("sideways", forKey: PreferenceKeys.gallerySortDirection)
    store.setString("not-json", forKey: PreferenceKeys.galleryFilterStatusIds)
    store.setString("{}", forKey: PreferenceKeys.galleryFilterTagIds)

    let loaded = GalleryStateCodec.load(from: store)
    #expect(loaded.mode == GalleryState.defaults.mode)
    #expect(loaded.tileSize == GalleryState.defaults.tileSize)
    #expect(loaded.sort == GalleryState.defaults.sort)
    #expect(loaded.direction == GalleryState.defaults.direction)
    #expect(loaded.statusIds.isEmpty)
    #expect(loaded.tagIds.isEmpty)
  }

  @Test("Sanitize убирает исчезнувшие id и сохраняет допустимые")
  func sanitizeRemovesMissingIds() {
    let state = GalleryState(
      placeId: "gone",
      statusIds: ["keep", "gone"],
      tagIds: ["tag-gone"]
    )
    let sanitized = GalleryStateCodec.sanitize(
      state,
      placeIds: ["keep-place"],
      statusIds: ["keep"],
      tagIds: []
    )
    #expect(sanitized.placeId == nil)
    #expect(sanitized.statusIds == ["keep"])
    #expect(sanitized.tagIds.isEmpty)
  }

  @Test("«Без места» имеет приоритет и обнуляет placeId")
  func noPlaceWins() {
    var state = GalleryState(placeId: "place-1", noPlace: true)
    state = GalleryStateCodec.sanitize(
      state,
      placeIds: ["place-1"],
      statusIds: [],
      tagIds: []
    )
    #expect(state.placeId == nil)
    #expect(state.noPlace)

    let store = InMemoryPreferencesStore()
    store.setString("place-1", forKey: PreferenceKeys.galleryFilterPlaceId)
    store.setBool(true, forKey: PreferenceKeys.galleryFilterNoPlace)
    #expect(GalleryStateCodec.load(from: store).placeId == nil)
  }

  @Test("Сброс очищает только фильтры, сохраняя сортировку и размер")
  func resetKeepsViewSettings() {
    var state = GalleryState(
      tileSize: .small,
      sort: .name,
      direction: .asc,
      placeId: "p",
      noPlace: false,
      statusIds: ["s"],
      tagIds: ["t"]
    )
    state.resetFilters()
    #expect(state.placeId == nil)
    #expect(!state.noPlace)
    #expect(state.statusIds.isEmpty)
    #expect(state.tagIds.isEmpty)
    #expect(state.tileSize == .small)
    #expect(state.sort == .name)
    #expect(state.direction == .asc)
  }
}
