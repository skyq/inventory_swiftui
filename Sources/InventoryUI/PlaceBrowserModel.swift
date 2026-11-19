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
  @Published public private(set) var selectedPath: [Place] = []
  @Published public var selectedPlaceId: String?
  @Published public private(set) var showsInspector = false
  @Published public private(set) var isLoading = false
  @Published public private(set) var loadError: AppException?
  @Published public var alert: BrowserAlert?

  private let places: any PlaceService
  private let photos: any PhotoStore
  private var observationTask: Task<Void, Never>?
  private var isObserving = false

  public init(places: any PlaceService, photos: any PhotoStore) {
    self.places = places
    self.photos = photos
  }

  deinit {
    observationTask?.cancel()
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
    }
    await reload()
  }

  public func reload() async {
    isLoading = true
    let parentId = currentParentId
    let service = places

    let childrenResult = await AsyncCore.run {
      try service.children(of: parentId)
    }
    let pathResult: Result<PlacePath, AppException>
    if let parentId {
      pathResult = await AsyncCore.run { try service.path(to: parentId) }
    } else {
      pathResult = .success(PlacePath(segments: []))
    }

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
    }

    if let selectedPlaceId,
      !children.contains(where: { $0.id == selectedPlaceId }),
      currentPath.last?.id != selectedPlaceId
    {
      self.selectedPlaceId = nil
      selectedPath = []
    }

    await refreshSelectedPath()
  }

  public func openRoot() async {
    currentParentId = nil
    currentPath = []
    selectedPlaceId = nil
    selectedPath = []
    showsInspector = false
    await reload()
  }

  public func open(_ place: Place) async {
    currentParentId = place.id
    selectedPlaceId = place.id
    selectedPath = []
    showsInspector = true
    await reload()
  }

  /// Переход по хлебной крошке: открываются дети выбранного предка.
  public func navigate(to place: Place) async {
    await open(place)
  }

  public func select(_ place: Place) async {
    selectedPlaceId = place.id
    showsInspector = true
    await refreshSelectedPath()
  }

  public func clearSelection() {
    showsInspector = false
  }

  public func toggleInspector() {
    guard selectedPlace != nil else { return }
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
