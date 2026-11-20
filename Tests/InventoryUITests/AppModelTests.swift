import Foundation
import InventoryCore
import Testing

@testable import InventoryUI

@Suite("Состояние приложения")
@MainActor
struct AppModelTests {
  @Test("Открывает сохранённое хранилище, переключает разделы и фокус поиска")
  func opensStoreAndNavigates() async throws {
    let root = try makeStoreDirectory()
    let preferences = InMemoryPreferencesStore()
    let coordinator = StorageCoordinator(preferences: preferences, logger: NullLogger())

    let session = try coordinator.createNew(root.path)
    let place = try session.places.create(
      PlaceCreate(name: "Дом", description: "", parentId: nil, photo: makeTestPhoto())
    )
    session.close()

    let model = AppModel(
      storage: coordinator,
      imageProcessor: FakeImageProcessor(),
      dialogs: FakeFileDialogs(),
      preferences: preferences
    )
    await model.start()
    defer {
      model.stop()
      try? FileManager.default.removeItem(at: root)
    }

    #expect(model.isReady)
    #expect(model.storePath == root.path)
    #expect(model.selectedSection == .gallery)
    #expect(!model.canCreatePlace)
    model.selectedSection = .places
    #expect(model.canCreatePlace)
    #expect(model.browser?.children.map(\.id) == [place.id])

    let token = model.searchFocusToken
    model.focusSearch()
    #expect(model.searchFocusToken == token + 1)

    model.selectedSection = .people
    #expect(!model.canCreatePlace)
    model.selectedSection = .places

    await model.browser?.open(place)
    model.presentCreatePlace()
    guard case .create(let parentId)? = model.placeForm?.mode else {
      Issue.record("Ожидалась форма создания с предзаполненным родителем")
      return
    }
    #expect(parentId == place.id)
    model.dismissPlaceForm()
    #expect(model.placeForm == nil)
  }

  @Test("Cmd+N создаёт вещь с местом текущего уровня")
  func createsItemWithCurrentPlace() async throws {
    let root = try makeStoreDirectory()
    let preferences = InMemoryPreferencesStore()
    let coordinator = StorageCoordinator(preferences: preferences, logger: NullLogger())

    let session = try coordinator.createNew(root.path)
    let place = try session.places.create(
      PlaceCreate(name: "Дом", description: "", parentId: nil, photo: makeTestPhoto())
    )
    session.close()

    let model = AppModel(
      storage: coordinator,
      imageProcessor: FakeImageProcessor(),
      dialogs: FakeFileDialogs(),
      preferences: preferences
    )
    await model.start()
    defer {
      model.stop()
      try? FileManager.default.removeItem(at: root)
    }

    #expect(model.canCreateItem)
    model.presentCreateItemFromCurrentContext()
    guard case .create(let galleryPlace)? = model.itemForm?.mode else {
      Issue.record("Ожидалась форма создания вещи")
      return
    }
    #expect(galleryPlace == nil)
    model.dismissItemForm()

    model.selectedSection = .places
    await model.browser?.open(place)
    model.presentCreateItemFromCurrentContext()
    guard case .create(let placeId)? = model.itemForm?.mode else {
      Issue.record("Ожидалась форма создания вещи в месте")
      return
    }
    #expect(placeId == place.id)
    model.dismissItemForm()
  }

  @Test("Режим «Галерея/По местам» восстанавливается и сохраняется")
  func persistsSectionMode() {
    let preferences = InMemoryPreferencesStore()
    preferences.setString(GalleryMode.places.rawValue, forKey: PreferenceKeys.galleryMode)
    let coordinator = StorageCoordinator(preferences: preferences, logger: NullLogger())
    let model = AppModel(
      storage: coordinator,
      imageProcessor: FakeImageProcessor(),
      dialogs: FakeFileDialogs(),
      preferences: preferences
    )

    #expect(model.selectedSection == .places)

    model.selectedSection = .gallery
    #expect(preferences.string(forKey: PreferenceKeys.galleryMode) == GalleryMode.grid.rawValue)

    model.selectedSection = .people
    #expect(preferences.string(forKey: PreferenceKeys.galleryMode) == GalleryMode.grid.rawValue)
  }

  @Test("Пропавшее хранилище показывает ошибку и не создаёт пустую базу")
  func reportsMissingStore() async throws {
    let root = try makeStoreDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let missing = root.appendingPathComponent("missing", isDirectory: true)
    let preferences = InMemoryPreferencesStore()
    preferences.setString(missing.path, forKey: PreferenceKeys.activeStorePath)
    let coordinator = StorageCoordinator(preferences: preferences, logger: NullLogger())

    let model = AppModel(
      storage: coordinator,
      imageProcessor: FakeImageProcessor(),
      dialogs: FakeFileDialogs(),
      preferences: preferences
    )
    await model.start()
    defer { model.stop() }

    #expect(!model.isReady)
    #expect(model.failure?.code == .storageUnavailable)
    #expect(!FileManager.default.fileExists(atPath: missing.path))
    #expect(model.browser == nil)
  }

  private func makeStoreDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("InventoryAppModel-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
