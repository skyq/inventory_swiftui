import Foundation
import InventoryCore

/// Плоский список мест для фильтра: id и полный путь.
public struct GalleryPlaceChoice: Identifiable, Sendable, Equatable {
  public let id: String
  public let path: String

  public init(id: String, path: String) {
    self.id = id
    self.path = path
  }
}

/// Состояние галереи: сохранённые настройки, загруженные плитки и выбранная вещь.
@MainActor
public final class GalleryModel: ObservableObject {
  @Published public private(set) var state: GalleryState
  @Published public private(set) var entries: [GalleryEntry] = []
  @Published public private(set) var placeChoices: [GalleryPlaceChoice] = []
  @Published public private(set) var availableStatuses: [Status] = []
  @Published public private(set) var availableTags: [TagSuggestion] = []
  @Published public private(set) var isLoading = false
  @Published public private(set) var loadError: AppException?
  @Published public private(set) var selected: ItemDetails?
  @Published public private(set) var selectedItemId: String?
  @Published public private(set) var showsInspector = false
  @Published public var alertMessage: String?

  private let items: any ItemService
  private let tags: any TagService
  private let statuses: any StatusService
  private let places: any PlaceService
  private let photos: any PhotoStore
  private let preferences: any PreferencesStore

  private var observationTasks: [Task<Void, Never>] = []
  private var started = false

  public init(
    items: any ItemService,
    tags: any TagService,
    statuses: any StatusService,
    places: any PlaceService,
    photos: any PhotoStore,
    preferences: any PreferencesStore
  ) {
    self.items = items
    self.tags = tags
    self.statuses = statuses
    self.places = places
    self.photos = photos
    self.preferences = preferences
    self.state = GalleryStateCodec.load(from: preferences)
  }

  deinit {
    for task in observationTasks {
      task.cancel()
    }
  }

  public var hasActiveFilters: Bool {
    state.placeId != nil || state.noPlace || !state.statusIds.isEmpty || !state.tagIds.isEmpty
  }

  public var selectedPhotoURL: URL? {
    guard let selected else { return nil }
    return try? photos.fileURL(for: selected.item.photoFile)
  }

  /// Загружает справочники, очищает исчезнувшие id и подписывается на изменения.
  public func start() async {
    if !started {
      started = true
      startObservation()
    }
    await loadFilterData()
    await reload()
  }

  public func reload() async {
    isLoading = true
    let query = makeQuery()
    let service = items
    let result = await AsyncCore.run { try service.list(query) }
    isLoading = false

    switch result {
    case .success(let loaded):
      entries = loaded
      loadError = nil
    case .failure(let error):
      entries = []
      loadError = error
    }

    if let selectedItemId {
      if entries.contains(where: { $0.item.id == selectedItemId }) {
        await loadDetails(selectedItemId)
      } else {
        self.selectedItemId = nil
        selected = nil
        showsInspector = false
      }
    }
  }

  public func select(_ entry: GalleryEntry) async {
    selectedItemId = entry.id
    showsInspector = true
    await loadDetails(entry.id)
  }

  public func clearSelection() {
    showsInspector = false
  }

  public func toggleInspector() {
    guard selectedItemId != nil else { return }
    showsInspector.toggle()
  }

  public func setTileSize(_ size: GalleryTileSize) {
    guard state.tileSize != size else { return }
    state.tileSize = size
    saveState()
  }

  public func setSort(_ sort: GallerySort) async {
    guard state.sort != sort else { return }
    state.sort = sort
    saveState()
    await reload()
  }

  public func setDirection(_ direction: GalleryDirection) async {
    guard state.direction != direction else { return }
    state.direction = direction
    saveState()
    await reload()
  }

  public func setPlaceSelection(placeId: String?, noPlace: Bool) async {
    state.noPlace = noPlace
    state.placeId = noPlace ? nil : placeId
    saveState()
    await reload()
  }

  public func toggleStatus(_ statusId: String) async {
    if state.statusIds.contains(statusId) {
      state.statusIds.remove(statusId)
    } else {
      state.statusIds.insert(statusId)
    }
    saveState()
    await reload()
  }

  public func toggleTag(_ tagId: String) async {
    if state.tagIds.contains(tagId) {
      state.tagIds.remove(tagId)
    } else {
      state.tagIds.insert(tagId)
    }
    saveState()
    await reload()
  }

  public func resetFilters() async {
    guard hasActiveFilters else { return }
    state.resetFilters()
    saveState()
    await reload()
  }

  public func thumbnailURL(for entry: GalleryEntry) -> URL? {
    try? photos.fileURL(for: entry.item.thumbFile)
  }

  public func photoURL(for details: ItemDetails) -> URL? {
    try? photos.fileURL(for: details.item.photoFile)
  }

  // MARK: - Внутренние шаги

  private func startObservation() {
    observationTasks.append(
      Task { [weak self] in
        guard let stream = self?.items.changes else { return }
        for await _ in stream {
          guard let self else { return }
          await self.reload()
        }
      }
    )
    observationTasks.append(
      Task { [weak self] in
        guard let stream = self?.tags.changes else { return }
        for await _ in stream {
          guard let self else { return }
          await self.refreshFilterData()
        }
      }
    )
    observationTasks.append(
      Task { [weak self] in
        guard let stream = self?.places.changes else { return }
        for await _ in stream {
          guard let self else { return }
          await self.refreshFilterData()
        }
      }
    )
  }

  /// Перечитывает справочники фильтров после изменения мест или тегов.
  private func refreshFilterData() async {
    await loadFilterData()
    await reload()
  }

  private func makeQuery() -> GalleryQuery {
    GalleryQuery(
      place: state.placeFilter,
      statusIds: state.statusIds,
      tagIds: state.tagIds,
      sort: state.sort,
      direction: state.direction
    )
  }

  private func loadDetails(_ id: String) async {
    let service = items
    let result = await AsyncCore.run { try service.get(id) }
    switch result {
    case .success(let details):
      selected = details
    case .failure(let error):
      if error.code == .validationNotFound {
        selected = nil
        selectedItemId = nil
        showsInspector = false
      } else {
        alertMessage = ErrorPresenter.message(for: error)
      }
    }
  }

  private func loadFilterData() async {
    let placesService = places
    let statusesService = statuses
    let tagsService = tags

    async let placesResult = AsyncCore.run { try placesService.all() }
    async let statusesResult = AsyncCore.run { try statusesService.list(includeArchived: true) }
    async let tagsResult = AsyncCore.run { try tagsService.suggest("", limit: 200) }

    let loadedPlaces = await placesResult
    let loadedStatuses = await statusesResult
    let loadedTags = await tagsResult

    switch loadedPlaces {
    case .success(let all):
      let byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
      placeChoices =
        all
        .map { GalleryPlaceChoice(id: $0.id, path: pathString(for: $0, byId: byId)) }
        .sorted { NaturalSort.compare($0.path, $1.path) < 0 }
    case .failure(let error):
      loadError = error
    }

    switch loadedStatuses {
    case .success(let list):
      availableStatuses = list
    case .failure(let error):
      loadError = loadError ?? error
    }

    switch loadedTags {
    case .success(let list):
      availableTags = list.sorted { NaturalSort.compare($0.name, $1.name) < 0 }
    case .failure(let error):
      loadError = loadError ?? error
    }

    let statusIds = Set(availableStatuses.map(\.id))
    let tagIds = Set(availableTags.map(\.id))
    let placeIds = Set(placeChoices.map(\.id))
    let sanitized = GalleryStateCodec.sanitize(
      state,
      placeIds: placeIds,
      statusIds: statusIds,
      tagIds: tagIds
    )
    if sanitized != state {
      state = sanitized
      saveState()
    }
  }

  private func saveState() {
    // Режим пишет AppModel при смене раздела; сохраняем актуальное значение.
    state.mode = GalleryStateCodec.load(from: preferences).mode
    GalleryStateCodec.save(state, to: preferences)
  }

  private func pathString(for place: Place, byId: [String: Place]) -> String {
    var names: [String] = []
    var visited: Set<String> = []
    var current: Place? = place
    while let cursor = current, visited.insert(cursor.id).inserted {
      names.append(cursor.name)
      current = cursor.parentId.flatMap { byId[$0] }
    }
    return names.reversed().joined(separator: " / ")
  }
}
