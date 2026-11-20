import Foundation
import InventoryCore

/// Сообщения режима «По местам».
public enum BrowserAlert: Identifiable {
  case delete(Place)
  case failure(String)

  public var id: String {
    switch self {
    case .delete(let place): return "delete-\(place.id)"
    case .failure(let message): return "failure-\(message)"
    }
  }

  public var message: String {
    switch self {
    case .failure(let message): return message
    case .delete: return ""
    }
  }
}

/// Навигация по иерархии мест. Путь не хранится в БД — он перечитывается из сервиса.
@MainActor
public final class PlaceBrowserModel: ObservableObject {
  @Published public private(set) var currentParentId: String?
  @Published public private(set) var currentPath: [Place] = []
  @Published public private(set) var children: [Place] = []
  @Published public private(set) var items: [GalleryEntry] = []
  @Published public private(set) var noPlaceItemCount = 0
  @Published public private(set) var isNoPlaceLevel = false
  @Published public private(set) var selectedPath: [Place] = []
  @Published public var selectedPlaceId: String?
  @Published public private(set) var selectedItemId: String?
  @Published public private(set) var selectedItem: ItemDetails?
  @Published public private(set) var showsInspector = false
  @Published public private(set) var isLoading = false
  @Published public private(set) var loadError: AppException?
  @Published public var alert: BrowserAlert?

  private let places: any PlaceService
  private let photos: any PhotoStore
  private let itemsService: any ItemService

  private var observationTask: Task<Void, Never>?
  private var itemObservationTask: Task<Void, Never>?
  private var isObserving = false

  public init(
    places: any PlaceService,
    photos: any PhotoStore,
    items: any ItemService
  ) {
    self.places = places
    self.photos = photos
    self.itemsService = items
  }

  deinit {
    observationTask?.cancel()
    itemObservationTask?.cancel()
  }

  public var selectedPlace: Place? {
    guard let selectedPlaceId else { return nil }
    if let child = children.first(where: { $0.id == selectedPlaceId }) {
      return child
    }
    if let current = currentPath.last, current.id == selectedPlaceId {
      return current
    }
    return nil
  }

  public var hasSelection: Bool {
    selectedPlace != nil || selectedItem != nil
  }

  /// Место, которое подставляется в новую вещь. «Без места» даёт nil.
  public var creationPlaceId: String? {
    isNoPlaceLevel ? nil : currentParentId
  }

  /// Подписывается на успешные изменения и загружает текущий уровень.
  public func start() async {
    if !isObserving {
      isObserving = true
      observationTask = Task { [weak self] in
        guard let self else { return }
        for await _ in self.places.changes {
          await self.reload()
        }
      }
      itemObservationTask = Task { [weak self] in
        guard let self else { return }
        for await _ in self.itemsService.changes {
          await self.reload()
        }
      }
    }
    await reload()
  }

  public func reload() async {
    isLoading = true
    let parentId = currentParentId
    let noPlace = isNoPlaceLevel
    let placesService = places
    let itemsService = self.itemsService

    let childrenResult: Result<[Place], AppException>
    if noPlace {
      childrenResult = .success([])
    } else {
      childrenResult = await AsyncCore.run { try placesService.children(of: parentId) }
    }

    let pathResult: Result<PlacePath, AppException>
    if let parentId, !noPlace {
      pathResult = await AsyncCore.run { try placesService.path(to: parentId) }
    } else {
      pathResult = .success(PlacePath(segments: []))
    }

    let itemQuery: GalleryQuery
    if noPlace {
      itemQuery = GalleryQuery(place: .noPlace, sort: .name, direction: .asc)
    } else if let parentId {
      itemQuery = GalleryQuery(place: .placeOnly(parentId), sort: .name, direction: .asc)
    } else {
      // В корне вещи не показываются: сначала идёт «Без места».
      itemQuery = GalleryQuery(place: .noPlace, sort: .name, direction: .asc)
    }
    let itemsResult = await AsyncCore.run { try itemsService.list(itemQuery) }

    isLoading = false

    switch childrenResult {
    case .success(let loaded):
      children = loaded
      loadError = nil
    case .failure(let error):
      children = []
      loadError = error
    }

    switch pathResult {
    case .success(let path):
      currentPath = path.segments
    case .failure(let error):
      // Текущий уровень мог быть удалён снаружи: показываем корень без потери доступа к окну.
      loadError = loadError ?? error
      currentPath = []
      currentParentId = nil
      isNoPlaceLevel = false
    }

    switch itemsResult {
    case .success(let loaded):
      if noPlace {
        self.items = loaded
        noPlaceItemCount = loaded.count
      } else if parentId != nil {
        self.items = loaded
      } else {
        self.items = []
        noPlaceItemCount = loaded.count
      }
    case .failure(let error):
      self.items = []
      loadError = loadError ?? error
    }

    if let selectedPlaceId,
      !children.contains(where: { $0.id == selectedPlaceId }),
      currentPath.last?.id != selectedPlaceId
    {
      self.selectedPlaceId = nil
      selectedPath = []
    }

    if let selectedItemId,
      !items.contains(where: { $0.item.id == selectedItemId })
    {
      self.selectedItemId = nil
      selectedItem = nil
    } else if let selectedItemId {
      await loadItemDetails(selectedItemId)
    }

    if !hasSelection {
      showsInspector = false
    }

    await refreshSelectedPath()
  }

  public func openRoot() async {
    currentParentId = nil
    currentPath = []
    isNoPlaceLevel = false
    selectedPlaceId = nil
    selectedItemId = nil
    selectedItem = nil
    selectedPath = []
    showsInspector = false
    await reload()
  }

  public func openNoPlace() async {
    currentParentId = nil
    currentPath = []
    isNoPlaceLevel = true
    selectedPlaceId = nil
    selectedItemId = nil
    selectedItem = nil
    selectedPath = []
    showsInspector = false
    await reload()
  }

  public func open(_ place: Place) async {
    currentParentId = place.id
    isNoPlaceLevel = false
    selectedPlaceId = place.id
    selectedItemId = nil
    selectedItem = nil
    selectedPath = []
    showsInspector = true
    await reload()
  }

  /// Переход по хлебной крошке: открываются дети выбранного предка.
  public func navigate(to place: Place) async {
    await open(place)
  }

  /// Открывает место по id; используется крошками карточки вещи.
  public func reveal(placeId: String) async {
    let service = places
    let result = await AsyncCore.run { try service.get(placeId) }
    switch result {
    case .success(let place):
      await open(place)
    case .failure(let error):
      alert = .failure(ErrorPresenter.message(for: error))
    }
  }

  public func select(_ place: Place) async {
    selectedPlaceId = place.id
    selectedItemId = nil
    selectedItem = nil
    showsInspector = true
    await refreshSelectedPath()
  }

  public func selectItem(_ entry: GalleryEntry) async {
    selectedItemId = entry.id
    selectedPlaceId = nil
    selectedPath = []
    showsInspector = true
    await loadItemDetails(entry.id)
  }

  public func clearSelection() {
    showsInspector = false
  }

  public func toggleInspector() {
    guard hasSelection else { return }
    showsInspector.toggle()
  }

  public func requestDeleteSelected() {
    guard let place = selectedPlace else { return }
    alert = .delete(place)
  }

  public func confirmDelete(_ place: Place) async {
    let service = places
    let result = await AsyncCore.run { try service.deleteEmpty(place.id) }
    switch result {
    case .success:
      if currentParentId == place.id {
        await openRoot()
      } else {
        selectedPlaceId = nil
        selectedPath = []
        showsInspector = false
        await reload()
      }
    case .failure(let error):
      alert = .failure(ErrorPresenter.message(for: error))
    }
  }

  public func thumbnailURL(for place: Place) -> URL? {
    guard let thumbFile = place.thumbFile else { return nil }
    return try? photos.fileURL(for: thumbFile)
  }

  public func photoURL(for place: Place) -> URL? {
    guard let photoFile = place.photoFile else { return nil }
    return try? photos.fileURL(for: photoFile)
  }

  public func thumbnailURL(for entry: GalleryEntry) -> URL? {
    try? photos.fileURL(for: entry.item.thumbFile)
  }

  public func photoURL(for details: ItemDetails) -> URL? {
    try? photos.fileURL(for: details.item.photoFile)
  }

  private func loadItemDetails(_ id: String) async {
    let service = itemsService
    let result = await AsyncCore.run { try service.get(id) }
    switch result {
    case .success(let details):
      selectedItem = details
    case .failure(let error):
      if error.code == .validationNotFound {
        selectedItem = nil
        selectedItemId = nil
        showsInspector = false
      } else {
        alert = .failure(ErrorPresenter.message(for: error))
      }
    }
  }

  private func refreshSelectedPath() async {
    guard let place = selectedPlace else {
      selectedPath = []
      return
    }
    let service = places
    let result = await AsyncCore.run { try service.path(to: place.id) }
    if case .success(let path) = result {
      selectedPath = path.segments
    } else {
      selectedPath = []
    }
  }
}
