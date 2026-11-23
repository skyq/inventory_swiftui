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
  var archiveError: AppException?

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

  func create(name: String) throws -> Status {
    lock.lock()
    defer { lock.unlock() }
    let status = Status(
      id: "status-\(statuses.count + 1)",
      name: name,
      isArchived: false,
      sortOrder: statuses.count,
      createdAt: 1_700_000_000_000
    )
    statuses.append(status)
    return status
  }

  func rename(_ id: String, to name: String) throws -> Status {
    lock.lock()
    defer { lock.unlock() }
    guard let index = statuses.firstIndex(where: { $0.id == id }) else {
      throw AppException(.validationNotFound, params: ["entity": .string("status")])
    }
    let old = statuses[index]
    let updated = Status(
      id: old.id, name: name, isArchived: old.isArchived,
      sortOrder: old.sortOrder, createdAt: old.createdAt
    )
    statuses[index] = updated
    return updated
  }

  func archive(_ id: String, replacementId: String?) throws -> Status {
    lock.lock()
    defer { lock.unlock() }
    if let archiveError { throw archiveError }
    guard let index = statuses.firstIndex(where: { $0.id == id }) else {
      throw AppException(.validationNotFound, params: ["entity": .string("status")])
    }
    let old = statuses[index]
    let updated = Status(
      id: old.id, name: old.name, isArchived: true,
      sortOrder: old.sortOrder, createdAt: old.createdAt
    )
    statuses[index] = updated
    return updated
  }

  func restore(_ id: String) throws -> Status {
    lock.lock()
    defer { lock.unlock() }
    guard let index = statuses.firstIndex(where: { $0.id == id }) else {
      throw AppException(.validationNotFound, params: ["entity": .string("status")])
    }
    let old = statuses[index]
    let updated = Status(
      id: old.id, name: old.name, isArchived: false,
      sortOrder: old.sortOrder, createdAt: old.createdAt
    )
    statuses[index] = updated
    return updated
  }
}

final class FakeTagService: TagService, @unchecked Sendable {
  private let lock = NSLock()
  private var suggestions: [TagSuggestion]
  private var attached: [String: [String]] = [:]
  private let continuation: AsyncStream<MutationEvent>.Continuation
  let changes: AsyncStream<MutationEvent>

  var suggestError: AppException?
  var renameError: AppException?

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

  func listWithCounts() throws -> [TagSuggestion] {
    lock.lock()
    defer { lock.unlock() }
    return suggestions
  }

  func rename(_ id: String, to name: String) throws -> Tag {
    lock.lock()
    defer { lock.unlock() }
    if let renameError { throw renameError }
    guard let index = suggestions.firstIndex(where: { $0.id == id }) else {
      throw AppException(.validationNotFound, params: ["entity": .string("tag")])
    }
    let updated = TagSuggestion(
      id: id, name: name, itemCount: suggestions[index].itemCount)
    suggestions[index] = updated
    return Tag(id: id, name: name, nameKey: TagKey.normalize(name))
  }

  func merge(_ sourceId: String, into targetId: String, resultName: String?) throws -> Tag {
    lock.lock()
    defer { lock.unlock() }
    guard let target = suggestions.first(where: { $0.id == targetId }) else {
      throw AppException(.validationNotFound, params: ["entity": .string("tag")])
    }
    suggestions.removeAll { $0.id == sourceId }
    return Tag(
      id: target.id,
      name: resultName ?? target.name,
      nameKey: TagKey.normalize(resultName ?? target.name)
    )
  }

  func delete(_ id: String) throws -> TagDeletion {
    lock.lock()
    defer { lock.unlock() }
    suggestions.removeAll { $0.id == id }
    return TagDeletion(itemIds: [])
  }
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

  var archiveURL: URL?

  func chooseArchiveFile() -> URL? {
    archiveURL
  }
}

func makeTemporaryFile(contents: String = "image") throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("InventoryUITest-\(UUID().uuidString).jpg")
  try Data(contents.utf8).write(to: url)
  return url
}

// MARK: - Люди, действия, история, настройки статусов

final class FakePeopleService: PeopleService, @unchecked Sendable {
  private let lock = NSLock()
  private var peopleById: [String: Person] = [:]
  private var lastGiven: [String: String] = [:]
  private var counter = 0
  private let continuation: AsyncStream<MutationEvent>.Continuation
  let changes: AsyncStream<MutationEvent>

  var createError: AppException?
  var updateError: AppException?
  var archiveError: AppException?
  var requiresDuplicateConfirmation = false
  private(set) var createdInputs: [PersonCreate] = []
  private(set) var updateInputs: [PersonUpdate] = []

  init(initial: [Person] = []) {
    for person in initial { peopleById[person.id] = person }
    (changes, continuation) = AsyncStream.makeStream(of: MutationEvent.self)
  }

  func setLastGiven(itemId: String, personId: String) {
    lock.lock()
    lastGiven[itemId] = personId
    lock.unlock()
  }

  func list(includeArchived: Bool) throws -> [Person] {
    lock.lock()
    defer { lock.unlock() }
    return peopleById.values
      .filter { includeArchived || !$0.isArchived }
      .sorted { $0.name < $1.name }
  }

  func get(_ id: String) throws -> Person {
    lock.lock()
    defer { lock.unlock() }
    guard let person = peopleById[id] else {
      throw AppException(.validationNotFound, params: ["entity": .string("person")])
    }
    return person
  }

  func create(_ input: PersonCreate, duplicateConfirmed: Bool) throws -> Person {
    lock.lock()
    defer { lock.unlock() }
    if let createError { throw createError }
    if requiresDuplicateConfirmation && !duplicateConfirmed,
      peopleById.values.contains(where: { $0.name.lowercased() == input.name.lowercased() })
    {
      throw AppException(.personNameDuplicate, params: ["name": .string(input.name)])
    }
    counter += 1
    let person = Person(
      id: "person-\(counter)",
      name: input.name,
      phone: input.phone,
      notes: input.notes,
      isArchived: false,
      createdAt: 1_700_000_000_000,
      updatedAt: 1_700_000_000_000
    )
    peopleById[person.id] = person
    createdInputs.append(input)
    return person
  }

  func update(_ input: PersonUpdate, duplicateConfirmed: Bool) throws -> Person {
    lock.lock()
    defer { lock.unlock() }
    if let updateError { throw updateError }
    guard let old = peopleById[input.id] else {
      throw AppException(.validationNotFound, params: ["entity": .string("person")])
    }
    let updated = Person(
      id: old.id,
      name: input.name,
      phone: input.phone,
      notes: input.notes,
      isArchived: old.isArchived,
      createdAt: old.createdAt,
      updatedAt: old.updatedAt
    )
    peopleById[input.id] = updated
    updateInputs.append(input)
    return updated
  }

  func archive(_ id: String) throws -> Person {
    lock.lock()
    defer { lock.unlock() }
    if let archiveError { throw archiveError }
    guard let old = peopleById[id] else {
      throw AppException(.validationNotFound, params: ["entity": .string("person")])
    }
    let updated = Person(
      id: old.id,
      name: old.name,
      phone: old.phone,
      notes: old.notes,
      isArchived: true,
      createdAt: old.createdAt,
      updatedAt: old.updatedAt
    )
    peopleById[id] = updated
    return updated
  }

  func restore(_ id: String) throws -> Person {
    lock.lock()
    defer { lock.unlock() }
    guard let old = peopleById[id] else {
      throw AppException(.validationNotFound, params: ["entity": .string("person")])
    }
    let updated = Person(
      id: old.id,
      name: old.name,
      phone: old.phone,
      notes: old.notes,
      isArchived: false,
      createdAt: old.createdAt,
      updatedAt: old.updatedAt
    )
    peopleById[id] = updated
    return updated
  }

  func lastGivenPersonId(itemId: String) throws -> String? {
    lock.lock()
    defer { lock.unlock() }
    return lastGiven[itemId]
  }
}

final class FakeItemActions: ItemActions, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var changeStatusCommands: [ChangeStatusCommand] = []
  private(set) var giveCommands: [GiveCommand] = []
  private(set) var returnCommands: [ReturnCommand] = []
  var error: AppException?
  var details: ItemDetails

  init(details: ItemDetails = makeTestItemDetails(id: "item-1", name: "Куртка")) {
    self.details = details
  }

  func changeStatus(_ command: ChangeStatusCommand) throws -> ItemDetails {
    lock.lock()
    defer { lock.unlock() }
    if let error { throw error }
    changeStatusCommands.append(command)
    return details
  }

  func give(_ command: GiveCommand) throws -> ItemDetails {
    lock.lock()
    defer { lock.unlock() }
    if let error { throw error }
    giveCommands.append(command)
    return details
  }

  func returnItem(_ command: ReturnCommand) throws -> ItemDetails {
    lock.lock()
    defer { lock.unlock() }
    if let error { throw error }
    returnCommands.append(command)
    return details
  }
}

final class FakeHistoryReadService: HistoryReadService, @unchecked Sendable {
  var itemEntries: [ItemHistoryEntry] = []
  var personEntries: [PersonHistoryEntry] = []
  var error: AppException?

  func itemHistory(itemId: String) throws -> [ItemHistoryEntry] {
    if let error { throw error }
    return itemEntries
  }

  func personHistory(personId: String) throws -> [PersonHistoryEntry] {
    if let error { throw error }
    return personEntries
  }
}

final class FakeStatusSettingsService: StatusSettingsService, @unchecked Sendable {
  var value: StatusSettings
  var error: AppException?
  private(set) var updates: [StatusSettings] = []

  init(value: StatusSettings) {
    self.value = value
  }

  func settings() throws -> StatusSettings {
    if let error { throw error }
    return value
  }

  func update(_ settings: StatusSettings) throws {
    if let error { throw error }
    value = settings
    updates.append(settings)
  }
}

/// Поиск для UI-тестов: выдача задаётся по тексту запроса.
final class FakeSearchService: SearchService, @unchecked Sendable {
  private let lock = NSLock()
  private var results: [String: [SearchHit]]
  private var recordedQueries: [String] = []
  private let continuation: AsyncStream<Void>.Continuation
  let changes: AsyncStream<Void>

  /// Хук перед выдачей: позволяет задержать конкретный запрос в тесте.
  var onSearch: (@Sendable (String) -> Void)?
  /// Запрос, который ждёт `gate`; используется для проверки устаревших ответов.
  var gatedQuery: String?
  var gate: DispatchSemaphore?
  private var startedQueries: [String] = []
  private(set) var rebuildCount = 0

  func hasStarted(_ query: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return startedQueries.contains(query)
  }

  init(results: [String: [SearchHit]] = [:]) {
    self.results = results
    (changes, continuation) = AsyncStream.makeStream(of: Void.self)
  }

  var queries: [String] {
    lock.lock()
    defer { lock.unlock() }
    return recordedQueries
  }

  func setResults(_ hits: [SearchHit], for query: String) {
    lock.lock()
    results[query] = hits
    lock.unlock()
  }

  func emitChange() {
    continuation.yield(())
  }

  func search(_ query: String) -> [SearchHit] {
    let hook = onSearch
    hook?(query)
    let target = gatedQuery
    let barrier = gate
    if let target, query == target {
      lock.lock()
      startedQueries.append(query)
      lock.unlock()
      barrier?.wait()
    }
    lock.lock()
    defer { lock.unlock() }
    recordedQueries.append(query)
    return results[query] ?? []
  }

  func rebuild() async {
    bumpRebuildCount()
    continuation.yield(())
  }

  private func bumpRebuildCount() {
    lock.lock()
    rebuildCount += 1
    lock.unlock()
  }

  func waitForIdle() async {}
}
