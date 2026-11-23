import Foundation

public struct Item: Identifiable, Sendable, Equatable {
  public let id: String
  public let name: String
  public let description: String
  public let notes: String
  public let quantity: Int
  public let placeId: String?
  public let statusId: String
  public let photoFile: String
  public let thumbFile: String
  public let createdAt: Int64
  public let updatedAt: Int64

  public init(
    id: String,
    name: String,
    description: String,
    notes: String,
    quantity: Int,
    placeId: String?,
    statusId: String,
    photoFile: String,
    thumbFile: String,
    createdAt: Int64,
    updatedAt: Int64
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.notes = notes
    self.quantity = quantity
    self.placeId = placeId
    self.statusId = statusId
    self.photoFile = photoFile
    self.thumbFile = thumbFile
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct ItemCreate: Sendable {
  public let name: String
  public let description: String
  public let notes: String
  public let quantity: Int
  public let placeId: String?
  /// nil — взять default_status_id из settings.
  public let statusId: String?
  /// Сырые имена тегов: нормализация и создание выполняются в транзакции вещи.
  public let tags: [String]
  /// Фото обязательно при создании.
  public let photo: ProcessedPhoto?

  public init(
    name: String,
    description: String = "",
    notes: String = "",
    quantity: Int = 1,
    placeId: String?,
    statusId: String?,
    tags: [String] = [],
    photo: ProcessedPhoto?
  ) {
    self.name = name
    self.description = description
    self.notes = notes
    self.quantity = quantity
    self.placeId = placeId
    self.statusId = statusId
    self.tags = tags
    self.photo = photo
  }
}

public struct ItemDetailsUpdate: Sendable {
  public let id: String
  public let name: String
  public let description: String
  public let notes: String
  public let quantity: Int
  public let placeId: String?
  public let tags: [String]
  /// nil — оставить текущее фото.
  public let newPhoto: ProcessedPhoto?

  public init(
    id: String,
    name: String,
    description: String,
    notes: String,
    quantity: Int,
    placeId: String?,
    tags: [String],
    newPhoto: ProcessedPhoto?
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.notes = notes
    self.quantity = quantity
    self.placeId = placeId
    self.tags = tags
    self.newPhoto = newPhoto
  }
}

public struct ItemDetails: Sendable, Equatable {
  public let item: Item
  public let status: Status
  /// Естественный порядок имён, tie-break — id.
  public let tags: [Tag]
  /// [] — без места; иначе от корня к месту.
  public let placePath: [Place]

  public init(item: Item, status: Status, tags: [Tag], placePath: [Place]) {
    self.item = item
    self.status = status
    self.tags = tags
    self.placePath = placePath
  }
}

public struct GalleryEntry: Identifiable, Sendable, Equatable {
  public let item: Item
  public let statusName: String
  public let statusArchived: Bool

  public var id: String { item.id }

  public init(item: Item, statusName: String, statusArchived: Bool) {
    self.item = item
    self.statusName = statusName
    self.statusArchived = statusArchived
  }
}

public enum GalleryPlaceFilter: Sendable, Equatable {
  case all
  /// Только вещи с place_id IS NULL.
  case noPlace
  /// Место и все потомки.
  case placeSubtree(String)
  /// Только прямые вещи места; режим «По местам».
  case placeOnly(String)
}

public enum GallerySort: String, CaseIterable, Sendable {
  case createdAt
  case name
}

public enum GalleryDirection: String, CaseIterable, Sendable {
  case asc
  case desc
}

public struct GalleryQuery: Sendable, Equatable {
  public let place: GalleryPlaceFilter
  /// Пусто — все статусы, включая архивные.
  public let statusIds: Set<String>
  /// AND: вещь должна иметь все теги.
  public let tagIds: Set<String>
  public let sort: GallerySort
  public let direction: GalleryDirection
  /// Пересечение с результатами поиска. nil — без ограничения; пусто — пусто.
  public let searchItemIds: Set<String>?
  /// false — вещи со скрытыми статусами не показываются, если их статус не выбран в `statusIds`.
  public let showHidden: Bool

  public init(
    place: GalleryPlaceFilter = .all,
    statusIds: Set<String> = [],
    tagIds: Set<String> = [],
    sort: GallerySort = .createdAt,
    direction: GalleryDirection = .desc,
    searchItemIds: Set<String>? = nil,
    showHidden: Bool = false
  ) {
    self.place = place
    self.statusIds = statusIds
    self.tagIds = tagIds
    self.sort = sort
    self.direction = direction
    self.searchItemIds = searchItemIds
    self.showHidden = showHidden
  }
}

public protocol ItemService: Sendable {
  func create(_ input: ItemCreate) throws -> ItemDetails
  /// Не принимает statusId: статус меняется отдельной командой этапа 3.
  func updateDetails(_ input: ItemDetailsUpdate) throws -> ItemDetails
  func get(_ id: String) throws -> ItemDetails
  func list(_ query: GalleryQuery) throws -> [GalleryEntry]
  var changes: AsyncStream<MutationEvent> { get }
}
