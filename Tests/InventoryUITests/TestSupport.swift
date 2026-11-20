import Foundation
import InventoryCore

@testable import InventoryUI

func makeTestPlace(
  id: String,
  parentId: String? = nil,
  name: String,
  description: String = "",
  photo: Bool = true
) -> Place {
  Place(
    id: id,
    parentId: parentId,
    name: name,
    description: description,
    photoFile: photo ? "photos/\(id).jpg" : nil,
    thumbFile: photo ? "thumbs/\(id).jpg" : nil,
    createdAt: 1_700_000_000_000,
    updatedAt: 1_700_000_000_000
  )
}

func makeTestPhoto() -> ProcessedPhoto {
  ProcessedPhoto(
    photoBytes: Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01]),
    thumbBytes: Data([0xFF, 0xD8, 0xFF, 0xE0, 0x02]),
    width: 100,
    height: 80,
    thumbWidth: 40,
    thumbHeight: 32,
    originalWidth: 200,
    originalHeight: 160
  )
}

func makeTestStatus(id: String = "status-1", name: String = "В наличии", archived: Bool = false)
  -> Status
{
  Status(id: id, name: name, isArchived: archived, sortOrder: 0, createdAt: 1_700_000_000_000)
}

func makeTestItemDetails(
  id: String,
  name: String,
  placeId: String? = nil,
  statusId: String = "status-1",
  status: Status? = nil,
  tagNames: [String] = [],
  quantity: Int = 1,
  createdAt: Int64 = 1_700_000_000_000
) -> ItemDetails {
  let item = Item(
    id: id,
    name: name,
    description: "",
    notes: "",
    quantity: quantity,
    placeId: placeId,
    statusId: statusId,
    photoFile: "photos/\(id).jpg",
    thumbFile: "thumbs/\(id).jpg",
    createdAt: createdAt,
    updatedAt: createdAt
  )
  let tags = tagNames.map { name in
    Tag(id: "tag-\(name)", name: name, nameKey: name.lowercased())
  }
  return ItemDetails(
    item: item,
    status: status ?? makeTestStatus(id: statusId),
    tags: tags,
    placePath: []
  )
}

final class FakePlaceService: PlaceService, @unchecked Sendable {
  private let lock = NSLock()
  private var placesById: [String: Place] = [:]
  private var created: [(PlaceCreate, Bool)] = []
  private var updated: [(PlaceDetailsUpdate, Bool)] = []
  private var idCounter = 0
  private let continuation: AsyncStream<MutationEvent>.Continuation
  let changes: AsyncStream<MutationEvent>

  var createError: AppException?
  var duplicateUntilConfirmed = false
  var updateError: AppException?
  var childrenError: AppException?
  var deleteError: AppException?

  init(initial: [Place] = []) {
    for place in initial {
      placesById[place.id] = place
    }
    (changes, continuation) = AsyncStream.makeStream(of: MutationEvent.self)
  }

  var allPlaces: [Place] {
    lock.lock()
    defer { lock.unlock() }
    return sorted(Array(placesById.values))
  }

  var createdInputs: [(PlaceCreate, Bool)] {
    lock.lock()
    defer { lock.unlock() }
    return created
  }

  var updatedInputs: [(PlaceDetailsUpdate, Bool)] {
    lock.lock()
    defer { lock.unlock() }
    return updated
  }

  func emit(_ event: MutationEvent) {
    continuation.yield(event)
  }

  func create(_ input: PlaceCreate, duplicateConfirmed: Bool) throws -> Place {
    lock.lock()
    created.append((input, duplicateConfirmed))
    if let createError, !(duplicateUntilConfirmed && duplicateConfirmed) {
      lock.unlock()
      throw createError
    }
    idCounter += 1
    let id = "created-\(idCounter)"
    let place = Place(
      id: id,
      parentId: input.parentId,
      name: input.name.trimmingCharacters(in: .whitespacesAndNewlines),
      description: input.description,
      photoFile: input.photo == nil ? nil : "photos/\(id).jpg",
      thumbFile: input.photo == nil ? nil : "thumbs/\(id).jpg",
      createdAt: 1_700_000_000_000,
      updatedAt: 1_700_000_000_000
    )
    placesById[id] = place
    lock.unlock()
    continuation.yield(.placesChanged(affectedIds: [id], parentId: place.parentId, kind: .created))
    return place
  }

  func get(_ id: String) throws -> Place {
    lock.lock()
    defer { lock.unlock() }
    guard let place = placesById[id] else {
      throw AppException(.validationNotFound, params: ["id": .string(id)])
    }
    return place
  }

  func updateDetails(_ input: PlaceDetailsUpdate, duplicateConfirmed: Bool) throws -> Place {
    lock.lock()
    updated.append((input, duplicateConfirmed))
    if let updateError {
      lock.unlock()
      throw updateError
    }
    guard let existing = placesById[input.id] else {
      lock.unlock()
      throw AppException(.validationNotFound, params: ["id": .string(input.id)])
    }
    let place = Place(
      id: existing.id,
      parentId: input.parentId,
      name: input.name.trimmingCharacters(in: .whitespacesAndNewlines),
      description: input.description,
      photoFile: existing.photoFile,
      thumbFile: existing.thumbFile,
      createdAt: existing.createdAt,
      updatedAt: 1_700_000_000_100
    )
    placesById[place.id] = place
    lock.unlock()
    continuation.yield(
      .placesChanged(affectedIds: [place.id], parentId: place.parentId, kind: .updated))
    return place
  }

  func move(_ id: String, newParentId: String?) throws -> Place {
    lock.lock()
    defer { lock.unlock() }
    guard let existing = placesById[id] else {
      throw AppException(.validationNotFound, params: ["id": .string(id)])
    }
    let moved = Place(
      id: existing.id,
      parentId: newParentId,
      name: existing.name,
      description: existing.description,
      photoFile: existing.photoFile,
      thumbFile: existing.thumbFile,
      createdAt: existing.createdAt,
      updatedAt: 1_700_000_000_100
    )
    placesById[moved.id] = moved
    return moved
  }

  func deleteEmpty(_ id: String) throws {
    lock.lock()
    if let deleteError {
      lock.unlock()
      throw deleteError
    }
    if placesById.values.contains(where: { $0.parentId == id }) {
      lock.unlock()
      throw AppException(.placeNotEmpty, params: ["childrenCount": .int(1), "itemsCount": .int(0)])
    }
    placesById[id] = nil
    lock.unlock()
    continuation.yield(.placesChanged(affectedIds: [id], parentId: nil, kind: .deleted))
  }

  func children(of parentId: String?) throws -> [Place] {
    lock.lock()
    if let childrenError {
      lock.unlock()
      throw childrenError
    }
    let result = sorted(placesById.values.filter { $0.parentId == parentId })
    lock.unlock()
    return result
  }

  func descendants(of id: String) throws -> [Place] {
    lock.lock()
    defer { lock.unlock() }
    return descendants(id, in: Array(placesById.values))
  }

  func path(to id: String) throws -> PlacePath {
    lock.lock()
    defer { lock.unlock() }
    var segments: [Place] = []
    var visited: Set<String> = []
    var current: String? = id
    while let cursor = current {
      guard visited.insert(cursor).inserted else {
        throw AppException(.placeCycle, params: ["placeId": .string(id)])
      }
      guard let place = placesById[cursor] else {
        throw AppException(.validationNotFound, params: ["id": .string(cursor)])
      }
      segments.append(place)
      current = place.parentId
    }
    return PlacePath(segments: segments.reversed())
  }

  func all() throws -> [Place] {
    lock.lock()
    defer { lock.unlock() }
    return sorted(Array(placesById.values))
  }

  func invalidParentIds(for placeId: String?) throws -> Set<String> {
    guard let placeId else { return [] }
    lock.lock()
    defer { lock.unlock() }
    var result = Set(descendants(placeId, in: Array(placesById.values)).map(\.id))
    result.insert(placeId)
    return result
  }

  private func descendants(_ id: String, in all: [Place]) -> [Place] {
    var result: [Place] = []
    var queue = [id]
    var visited: Set<String> = [id]
    while !queue.isEmpty {
      let current = queue.removeFirst()
      for child in all where child.parentId == current && visited.insert(child.id).inserted {
        result.append(child)
        queue.append(child.id)
      }
    }
    return result
  }

  private func sorted<S: Sequence>(_ places: S) -> [Place] where S.Element == Place {
    places.sorted { NaturalSort.compare($0.name, $1.name) < 0 }
  }
}

final class FakeItemService: ItemService, @unchecked Sendable {
  private let lock = NSLock()
  private var itemsById: [String: ItemDetails]
  private var created: [ItemCreate] = []
  private var updated: [ItemDetailsUpdate] = []
  private var idCounter = 0
  private let continuation: AsyncStream<MutationEvent>.Continuation
  let changes: AsyncStream<MutationEvent>

  var createError: AppException?
  var updateError: AppException?
  var listError: AppException?
  var getError: AppException?
  private(set) var lastQuery: GalleryQuery?

  init(initial: [ItemDetails] = []) {
    itemsById = Dictionary(uniqueKeysWithValues: initial.map { ($0.item.id, $0) })
    (changes, continuation) = AsyncStream.makeStream(of: MutationEvent.self)
  }

  var stored: [ItemDetails] {
    lock.lock()
    defer { lock.unlock() }
    return Array(itemsById.values)
  }

  var createdInputs: [ItemCreate] {
    lock.lock()
    defer { lock.unlock() }
    return created
  }

  var updatedInputs: [ItemDetailsUpdate] {
    lock.lock()
    defer { lock.unlock() }
    return updated
  }

  func emit(_ event: MutationEvent) {
    continuation.yield(event)
  }

  func create(_ input: ItemCreate) throws -> ItemDetails {
    lock.lock()
    created.append(input)
    if let createError {
      lock.unlock()
      throw createError
    }
    idCounter += 1
    let id = "created-item-\(idCounter)"
    let details = makeTestItemDetails(
      id: id,
      name: input.name.trimmingCharacters(in: .whitespacesAndNewlines),
      placeId: input.placeId,
      statusId: input.statusId ?? "status-1",
      tagNames: input.tags,
      quantity: input.quantity
    )
    itemsById[id] = details
    lock.unlock()
    continuation.yield(.itemsChanged(itemIds: [id], kind: .created))
    return details
  }

  func updateDetails(_ input: ItemDetailsUpdate) throws -> ItemDetails {
    lock.lock()
    updated.append(input)
    if let updateError {
      lock.unlock()
      throw updateError
    }
    guard let existing = itemsById[input.id] else {
      lock.unlock()
      throw AppException(.validationNotFound, params: ["entity": .string("item")])
    }
    let details = makeTestItemDetails(
      id: existing.item.id,
      name: input.name.trimmingCharacters(in: .whitespacesAndNewlines),
      placeId: input.placeId,
      statusId: existing.item.statusId,
      tagNames: input.tags,
      quantity: input.quantity,
      createdAt: existing.item.createdAt
    )
    itemsById[details.item.id] = details
    lock.unlock()
    continuation.yield(.itemsChanged(itemIds: [details.item.id], kind: .updated))
    return details
  }

  func get(_ id: String) throws -> ItemDetails {
    lock.lock()
    defer { lock.unlock() }
    if let getError { throw getError }
    guard let details = itemsById[id] else {
      throw AppException(.validationNotFound, params: ["entity": .string("item")])
    }
    return details
  }

  func list(_ query: GalleryQuery) throws -> [GalleryEntry] {
    lock.lock()
    defer { lock.unlock() }
    if let listError { throw listError }
    lastQuery = query
    let filtered = itemsById.values.filter { details in
      let item = details.item
      if let searchIds = query.searchItemIds, !searchIds.contains(item.id) {
        return false
      }
      switch query.place {
      case .all:
        break
      case .noPlace:
        if item.placeId != nil { return false }
      case .placeOnly(let placeId):
        if item.placeId != placeId { return false }
      case .placeSubtree(let placeId):
        if item.placeId != placeId { return false }
      }
      if !query.statusIds.isEmpty, !query.statusIds.contains(item.statusId) {
        return false
      }
      if !query.tagIds.isEmpty {
        let ids = Set(details.tags.map(\.id))
        if !ids.isSuperset(of: query.tagIds) { return false }
      }
      return true
    }

    let sorted = filtered.sorted { left, right in
      switch query.sort {
      case .createdAt:
        if left.item.createdAt != right.item.createdAt {
          return query.direction == .asc
            ? left.item.createdAt < right.item.createdAt
            : left.item.createdAt > right.item.createdAt
        }
      case .name:
        let byName = NaturalSort.compare(left.item.name, right.item.name)
        if byName != 0 {
          return query.direction == .asc ? byName < 0 : byName > 0
        }
      }
      return left.item.id < right.item.id
    }
    return sorted.map {
      GalleryEntry(
        item: $0.item,
        statusName: $0.status.name,
        statusArchived: $0.status.isArchived
      )
    }
  }
}

final class FakeStatusService: StatusService, @unchecked Sendable {
  private let lock = NSLock()
  private var statuses: [Status]
  private let continuation: AsyncStream<MutationEvent>.Continuation
  let changes: AsyncStream<MutationEvent>

  var listError: AppException?
  var getError: AppException?

  init(statuses: [Status] = [makeTestStatus()]) {
    self.statuses = statuses
    (changes, continuation) = AsyncStream.makeStream(of: MutationEvent.self)
  }

  func emit(_ event: MutationEvent) {
    continuation.yield(event)
  }

  func list(includeArchived: Bool) throws -> [Status] {
    lock.lock()
    defer { lock.unlock() }
    if let listError { throw listError }
    return includeArchived ? statuses : statuses.filter { !$0.isArchived }
  }

  func get(_ id: String) throws -> Status {
    lock.lock()
    defer { lock.unlock() }
    if let getError { throw getError }
    guard let status = statuses.first(where: { $0.id == id }) else {
      throw AppException(.validationNotFound, params: ["entity": .string("status")])
    }
    return status
  }
}

final class FakeTagService: TagService, @unchecked Sendable {
  private let lock = NSLock()
  private var suggestions: [TagSuggestion]
  private var attached: [String: [String]] = [:]
  private let continuation: AsyncStream<MutationEvent>.Continuation
  let changes: AsyncStream<MutationEvent>

  var suggestError: AppException?

  init(suggestions: [TagSuggestion] = []) {
    self.suggestions = suggestions
    (changes, continuation) = AsyncStream.makeStream(of: MutationEvent.self)
  }

  func emit(_ event: MutationEvent) {
    continuation.yield(event)
  }

  func suggest(_ query: String, limit: Int) throws -> [TagSuggestion] {
    lock.lock()
    defer { lock.unlock() }
    if let suggestError { throw suggestError }
    let key = TagKey.normalize(query)
    return
      suggestions
      .filter { key.isEmpty || TagKey.normalize($0.name).hasPrefix(key) }
      .prefix(limit)
      .map { $0 }
  }

  func tagsForItem(_ itemId: String) throws -> [Tag] {
    lock.lock()
    defer { lock.unlock() }
    return (attached[itemId] ?? []).map {
      Tag(id: "tag-\($0)", name: $0, nameKey: $0.lowercased())
    }
  }

  func setItemTags(_ itemId: String, rawNames: [String]) throws {
    lock.lock()
    defer { lock.unlock() }
    attached[itemId] = rawNames
  }

  func removeUnused() throws {}
}

final class FakePhotoStore: PhotoStore, @unchecked Sendable {
  let layout: StoreLayout

  init(root: URL = URL(fileURLWithPath: "/tmp/inventory-ui-tests", isDirectory: true)) {
    self.layout = StoreLayout(rootURL: root)
  }

  func store(_ photo: ProcessedPhoto) throws -> StoredPhoto {
    StoredPhoto(photoFile: "photos/fake.jpg", thumbFile: "thumbs/fake.jpg")
  }

  func deleteFiles(photoFile: String, thumbFile: String) {}

  func fileURL(for relativePath: String) throws -> URL {
    try layout.fileURL(forRelativePath: relativePath)
  }

  func cleanupOrphans(referencedRelativePaths: Set<String>) {}
}

actor FakeImageProcessor: ImageProcessor {
  private var result: ProcessedPhoto
  private var error: AppException?
  private(set) var calls = 0

  init(result: ProcessedPhoto = makeTestPhoto(), error: AppException? = nil) {
    self.result = result
    self.error = error
  }

  func process(_ input: PhotoInput) async throws -> ProcessedPhoto {
    calls += 1
    if let error {
      throw error
    }
    return result
  }

  func callCount() -> Int { calls }

  func setError(_ error: AppException?) {
    self.error = error
  }
}

@MainActor
final class FakeFileDialogs: FileDialogs {
  var imageURL: URL?
  var directoryURL: URL?
  private(set) var imageRequestCount = 0
  private(set) var directoryRequestCount = 0

  func chooseDirectory(startingAt url: URL?) -> URL? {
    directoryRequestCount += 1
    return directoryURL
  }

  func chooseImageFile() -> URL? {
    imageRequestCount += 1
    return imageURL
  }
}

func makeTemporaryFile(contents: String = "image") throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("InventoryUITest-\(UUID().uuidString).jpg")
  try Data(contents.utf8).write(to: url)
  return url
}
