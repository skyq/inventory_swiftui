import Foundation
import InventoryCore

/// Что показать в модальной форме места.
public enum PlaceFormMode: Sendable, Equatable {
  case create(parentId: String?)
  case edit(Place)

  public var editingPlace: Place? {
    if case .edit(let place) = self { return place }
    return nil
  }
}

public struct PlaceFormPresentation: Identifiable {
  public let id = UUID()
  public let mode: PlaceFormMode

  public init(mode: PlaceFormMode) {
    self.mode = mode
  }
}

/// Модальное действие над вещью из карточки.
public enum ItemActionMode: Sendable, Equatable {
  case changeStatus(ItemDetails)
  case give(ItemDetails)
  case returnItem(ItemDetails)

  public var item: ItemDetails {
    switch self {
    case .changeStatus(let item), .give(let item), .returnItem(let item):
      return item
    }
  }
}

public struct ItemActionPresentation: Identifiable {
  public let id = UUID()
  public let mode: ItemActionMode

  public init(mode: ItemActionMode) {
    self.mode = mode
  }
}

/// Сообщение, не связанное с конкретным экраном.
public enum AppAlert: Identifiable {
  case failure(String)

  public var id: String {
    switch self {
    case .failure(let message): return "failure-\(message)"
    }
  }

  public var message: String {
    switch self {
    case .failure(let message): return message
    }
  }
}

/// Состояние запуска приложения и общая навигация.
@MainActor
public final class AppModel: ObservableObject {
  public enum LoadState {
    case idle
    case opening
    case ready
    case failed(AppException)
  }

  @Published public private(set) var loadState: LoadState = .idle
  @Published public var selectedSection: SidebarSection? {
    didSet { persistSectionMode() }
  }
  @Published public var searchText = "" {
    didSet {
      guard searchText != oldValue else { return }
      let text = searchText
      Task { await gallery?.setSearchText(text) }
    }
  }
  @Published public private(set) var searchFocusToken = 0
  @Published public private(set) var storePath: String?
  @Published public private(set) var browser: PlaceBrowserModel?
  @Published public private(set) var gallery: GalleryModel?
  @Published public private(set) var statusesModel: StatusesModel?
  @Published public private(set) var peopleModel: PeopleModel?
  @Published public private(set) var tagsModel: TagsModel?
  @Published public var placeForm: PlaceFormPresentation?
  @Published public var itemForm: ItemFormPresentation?
  @Published public var itemAction: ItemActionPresentation?
  @Published public var alert: AppAlert?

  private let storage: StorageCoordinator
  private let imageProcessor: any ImageProcessor
  private let dialogs: any FileDialogs
  private let preferences: any PreferencesStore
  private var session: StorageSession?
  private var started = false

  public init(
    storage: StorageCoordinator,
    imageProcessor: any ImageProcessor,
    dialogs: any FileDialogs,
    preferences: any PreferencesStore
  ) {
    self.storage = storage
    self.imageProcessor = imageProcessor
    self.dialogs = dialogs
    self.preferences = preferences
    switch GalleryStateCodec.load(from: preferences).mode {
    case .grid:
      self.selectedSection = .gallery
    case .places:
      self.selectedSection = .places
    }
  }

  /// Вызывается один раз при появлении окна.
  public func start() async {
    guard !started else { return }
    started = true
    await openDefaultStore()
  }

  public func retry() async {
    switch loadState {
    case .opening: return
    case .ready:
      await openDefaultStore()
    case .idle, .failed:
      await openDefaultStore()
    }
  }

  /// Открывает существующую папку данных. Пустая папка не превращается в новую базу.
  public func chooseExistingStore() async {
    guard let url = dialogs.chooseDirectory(startingAt: currentDirectoryHint()) else { return }
    await performOpen { try self.storage.openExisting(url.path) }
  }

  /// Создаёт новое хранилище только по явному выбору пользователя.
  public func chooseNewStore() async {
    guard let url = dialogs.chooseDirectory(startingAt: currentDirectoryHint()) else { return }
    await performOpen { try self.storage.createNew(url.path) }
    if case .ready = loadState {
      placeForm = nil
    }
  }

  public func focusSearch() {
    guard canFocusSearch else { return }
    searchFocusToken &+= 1
  }

  /// Cmd+K доступен из любого раздела, но не поверх модальной формы (D09).
  public var canFocusSearch: Bool {
    isReady && placeForm == nil && itemForm == nil && itemAction == nil
  }

  public func closeInspector() {
    browser?.clearSelection()
    gallery?.clearSelection()
  }

  public func presentCreatePlace() {
    guard case .ready = loadState, placeForm == nil, let browser else { return }
    placeForm = PlaceFormPresentation(mode: .create(parentId: browser.currentParentId))
  }

  public func presentEditPlace(_ place: Place) {
    guard case .ready = loadState else { return }
    placeForm = PlaceFormPresentation(mode: .edit(place))
  }

  public func presentCreateItem(placeId: String?) {
    guard case .ready = loadState, itemForm == nil else { return }
    itemForm = ItemFormPresentation(mode: .create(placeId: placeId))
  }

  /// Cmd+N: вещь с местом текущего уровня в режиме «По местам».
  public func presentCreateItemFromCurrentContext() {
    let placeId =
      (selectedSection ?? .gallery) == .places
      ? browser?.creationPlaceId
      : nil
    presentCreateItem(placeId: placeId)
  }

  public func presentEditItem(_ details: ItemDetails) {
    guard case .ready = loadState, itemForm == nil else { return }
    itemForm = ItemFormPresentation(mode: .edit(details))
  }

  public func presentChangeStatus(_ details: ItemDetails) {
    guard case .ready = loadState, itemAction == nil else { return }
    itemAction = ItemActionPresentation(mode: .changeStatus(details))
  }

  public func presentGive(_ details: ItemDetails) {
    guard case .ready = loadState, itemAction == nil else { return }
    itemAction = ItemActionPresentation(mode: .give(details))
  }

  public func presentReturn(_ details: ItemDetails) {
    guard case .ready = loadState, itemAction == nil else { return }
    itemAction = ItemActionPresentation(mode: .returnItem(details))
  }

  public func dismissItemAction() {
    itemAction = nil
  }

  /// Переход к человеку из ленты истории вещи.
  public func openPerson(_ personId: String) {
    guard case .ready = loadState else { return }
    selectedSection = .people
    Task { await peopleModel?.select(personId) }
  }

  /// Переход к вещи из истории человека; правая панель открывается сразу.
  public func openItemInGallery(_ itemId: String) {
    guard case .ready = loadState else { return }
    selectedSection = .gallery
    Task { await gallery?.selectItem(id: itemId) }
  }

  /// Переход к месту из крошек карточки вещи.
  public func openPlaceInPlaces(_ placeId: String) {
    guard case .ready = loadState else { return }
    selectedSection = .places
    Task { await browser?.reveal(placeId: placeId) }
  }

  public func makePlaceFormModel(for presentation: PlaceFormPresentation) -> PlaceFormModel? {
    guard let session else { return nil }
    return PlaceFormModel(
      mode: presentation.mode,
      places: session.places,
      images: imageProcessor,
      dialogs: dialogs,
      photos: session.photos
    )
  }

  public func makeItemFormModel(for presentation: ItemFormPresentation) -> ItemFormModel? {
    guard let session else { return nil }
    return ItemFormModel(
      mode: presentation.mode,
      items: session.items,
      tags: session.tags,
      statuses: session.statuses,
      places: session.places,
      images: imageProcessor,
      dialogs: dialogs,
      photos: session.photos
    )
  }

  public func dismissPlaceForm() {
    placeForm = nil
  }

  public func dismissItemForm() {
    itemForm = nil
  }

  public func makeChangeStatusModel(for details: ItemDetails) -> ChangeStatusModel? {
    guard let session else { return nil }
    return ChangeStatusModel(
      item: details,
      actions: session.actions,
      statuses: session.statuses
    )
  }

  public func makeGiveModel(for details: ItemDetails) -> GiveModel? {
    guard let session else { return nil }
    return GiveModel(
      item: details,
      actions: session.actions,
      people: session.people,
      statuses: session.statuses,
      settings: session.statusSettings
    )
  }

  public func makeReturnModel(for details: ItemDetails) -> ReturnModel? {
    guard let session else { return nil }
    return ReturnModel(
      item: details,
      actions: session.actions,
      people: session.people,
      statuses: session.statuses,
      settings: session.statusSettings,
      places: session.places,
      history: session.history
    )
  }

  /// Закрывает хранилище. Нужен при выходе и в тестах.
  public func stop() {
    session?.close()
    session = nil
    browser = nil
    gallery = nil
    storePath = nil
    placeForm = nil
    itemForm = nil
    itemAction = nil
    statusesModel = nil
    peopleModel = nil
    tagsModel = nil
    alert = nil
    searchText = ""
    loadState = .idle
    started = false
  }

  public var canCreatePlace: Bool {
    if case .ready = loadState { return selectedSection == .places && placeForm == nil }
    return false
  }

  public var canCreateItem: Bool {
    if case .ready = loadState {
      let section = selectedSection ?? .gallery
      return (section == .gallery || section == .places) && itemForm == nil
    }
    return false
  }

  public var isReady: Bool {
    if case .ready = loadState { return true }
    return false
  }

  public var failure: AppException? {
    if case .failed(let error) = loadState { return error }
    return nil
  }

  // MARK: - Внутренние шаги

  /// Режим «Галерея/По местам» хранится вместе с видом галереи (D12/T02.09).
  private func persistSectionMode() {
    let mode: GalleryMode
    switch selectedSection {
    case .places:
      mode = .places
    case .gallery, .none:
      mode = .grid
    default:
      return
    }
    preferences.setString(mode.rawValue, forKey: PreferenceKeys.galleryMode)
  }

  private func openDefaultStore() async {
    await performOpen { try self.storage.openOrCreateDefault() }
  }

  private func performOpen(_ operation: @escaping @Sendable () throws -> StorageSession) async {
    loadState = .opening
    let result = await AsyncCore.run(operation)
    switch result {
    case .success(let opened):
      attach(opened)
      loadState = .ready
      if let browser {
        await browser.start()
      }
      if let gallery {
        await gallery.start()
        if !searchText.isEmpty {
          await gallery.setSearchText(searchText)
        }
      }
    case .failure(let error):
      if session != nil {
        // Уже открытое хранилище остаётся рабочим; ошибка переключения только сообщается.
        alert = .failure(ErrorPresenter.message(for: error))
        loadState = .ready
      } else {
        loadState = .failed(error)
      }
    }
  }

  private func attach(_ opened: StorageSession) {
    session?.close()
    session = opened
    storePath = opened.layout.rootPath
    browser = PlaceBrowserModel(
      places: opened.places,
      photos: opened.photos,
      items: opened.items,
      history: opened.history
    )
    gallery = GalleryModel(
      items: opened.items,
      tags: opened.tags,
      statuses: opened.statuses,
      places: opened.places,
      photos: opened.photos,
      preferences: preferences,
      history: opened.history,
      searchService: opened.search
    )
    statusesModel = StatusesModel(
      statuses: opened.statuses,
      settings: opened.statusSettings
    )
    peopleModel = PeopleModel(
      people: opened.people,
      history: opened.history,
      items: opened.items
    )
    tagsModel = TagsModel(tags: opened.tags, items: opened.items)
    placeForm = nil
    itemForm = nil
    itemAction = nil
  }

  private func currentDirectoryHint() -> URL? {
    if let storePath {
      return URL(fileURLWithPath: storePath, isDirectory: true).deletingLastPathComponent()
    }
    return nil
  }
}
