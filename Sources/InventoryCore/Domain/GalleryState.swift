import Foundation

public enum GalleryMode: String, CaseIterable, Sendable {
  case grid
  case places
}

public enum GalleryTileSize: String, CaseIterable, Sendable {
  case small
  case medium
  case large

  public var side: CGFloat {
    switch self {
    case .small: return 112
    case .medium: return 156
    case .large: return 220
    }
  }
}

public struct GalleryState: Sendable, Equatable {
  public var mode: GalleryMode
  public var tileSize: GalleryTileSize
  public var sort: GallerySort
  public var direction: GalleryDirection
  public var placeId: String?
  public var noPlace: Bool
  public var statusIds: Set<String>
  public var tagIds: Set<String>

  public init(
    mode: GalleryMode = .grid,
    tileSize: GalleryTileSize = .medium,
    sort: GallerySort = .createdAt,
    direction: GalleryDirection = .desc,
    placeId: String? = nil,
    noPlace: Bool = false,
    statusIds: Set<String> = [],
    tagIds: Set<String> = []
  ) {
    self.mode = mode
    self.tileSize = tileSize
    self.sort = sort
    self.direction = direction
    self.placeId = placeId
    self.noPlace = noPlace
    self.statusIds = statusIds
    self.tagIds = tagIds
  }

  public static let defaults = GalleryState()

  public var placeFilter: GalleryPlaceFilter {
    if noPlace { return .noPlace }
    if let placeId { return .placeSubtree(placeId) }
    return .all
  }

  public mutating func resetFilters() {
    placeId = nil
    noPlace = false
    statusIds = []
    tagIds = []
  }
}

/// Хранит вид галереи в PreferencesStore, вне папки данных и архива.
public enum GalleryStateCodec {
  public static func load(from store: any PreferencesStore) -> GalleryState {
    var state = GalleryState.defaults

    if let raw = store.string(forKey: PreferenceKeys.galleryMode),
      let mode = GalleryMode(rawValue: raw)
    {
      state.mode = mode
    }
    if let raw = store.string(forKey: PreferenceKeys.galleryTileSize),
      let size = GalleryTileSize(rawValue: raw)
    {
      state.tileSize = size
    }
    if let raw = store.string(forKey: PreferenceKeys.gallerySort),
      let sort = GallerySort(rawValue: raw)
    {
      state.sort = sort
    }
    if let raw = store.string(forKey: PreferenceKeys.gallerySortDirection),
      let direction = GalleryDirection(rawValue: raw)
    {
      state.direction = direction
    }
    if let raw = store.string(forKey: PreferenceKeys.galleryFilterPlaceId), !raw.isEmpty {
      state.placeId = raw
    }
    state.noPlace = store.bool(forKey: PreferenceKeys.galleryFilterNoPlace) ?? false
    if let raw = store.string(forKey: PreferenceKeys.galleryFilterStatusIds) {
      state.statusIds = decodeSet(raw)
    }
    if let raw = store.string(forKey: PreferenceKeys.galleryFilterTagIds) {
      state.tagIds = decodeSet(raw)
    }
    if state.noPlace {
      state.placeId = nil
    }
    return state
  }

  public static func save(_ state: GalleryState, to store: any PreferencesStore) {
    store.setString(state.mode.rawValue, forKey: PreferenceKeys.galleryMode)
    store.setString(state.tileSize.rawValue, forKey: PreferenceKeys.galleryTileSize)
    store.setString(state.sort.rawValue, forKey: PreferenceKeys.gallerySort)
    store.setString(state.direction.rawValue, forKey: PreferenceKeys.gallerySortDirection)
    store.setString(
      state.noPlace ? nil : state.placeId, forKey: PreferenceKeys.galleryFilterPlaceId)
    store.setBool(state.noPlace, forKey: PreferenceKeys.galleryFilterNoPlace)
    store.setString(
      encodeSet(state.statusIds),
      forKey: PreferenceKeys.galleryFilterStatusIds
    )
    store.setString(encodeSet(state.tagIds), forKey: PreferenceKeys.galleryFilterTagIds)
  }

  /// Убирает исчезнувшие id, сохраняя допустимые настройки. D12.
  public static func sanitize(
    _ state: GalleryState,
    placeIds: Set<String>,
    statusIds: Set<String>,
    tagIds: Set<String>
  ) -> GalleryState {
    var result = state
    if result.noPlace {
      result.placeId = nil
    } else if let placeId = result.placeId, !placeIds.contains(placeId) {
      result.placeId = nil
    }
    result.statusIds.formIntersection(statusIds)
    result.tagIds.formIntersection(tagIds)
    return result
  }

  private static func encodeSet(_ ids: Set<String>) -> String {
    let sorted = ids.sorted()
    guard let data = try? JSONEncoder().encode(sorted) else { return "[]" }
    return String(decoding: data, as: UTF8.self)
  }

  private static func decodeSet(_ raw: String) -> Set<String> {
    guard let data = raw.data(using: .utf8),
      let ids = try? JSONDecoder().decode([String].self, from: data)
    else {
      return []
    }
    return Set(ids)
  }
}
