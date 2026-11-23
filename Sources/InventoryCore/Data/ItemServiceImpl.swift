import Foundation
import GRDB

public final class ItemServiceImpl: ItemService, @unchecked Sendable {
  private let db: InventoryDatabase
  private let photos: PhotoLifecycle
  private let clock: any Clock
  private let ids: any IdGenerator
  private let mutations: MutationBus

  public init(
    database: InventoryDatabase,
    photos: PhotoLifecycle,
    clock: any Clock,
    ids: any IdGenerator,
    mutations: MutationBus
  ) {
    self.db = database
    self.photos = photos
    self.clock = clock
    self.ids = ids
    self.mutations = mutations
  }

  public var changes: AsyncStream<MutationEvent> { mutations.events }

  public func create(_ input: ItemCreate) throws -> ItemDetails {
    let name = try validName(input.name)
    let quantity = try validQuantity(input.quantity)
    guard let photo = input.photo, !photo.photoBytes.isEmpty, !photo.thumbBytes.isEmpty else {
      throw AppException(.validationRequired, params: ["field": .string("itemPhoto")])
    }
    try validateTags(input.tags)

    let now = clock.nowMilliseconds()
    let id = ids.next()

    let outcome = try photos.replace(prepared: photo, previous: nil) { stored in
      try db.write { database in
        try ensurePlaceExists(database, input.placeId)
        let status = try resolveCreateStatus(database, requested: input.statusId)
        guard let stored else {
          throw AppException(.validationRequired, params: ["field": .string("itemPhoto")])
        }

        let item = Item(
          id: id,
          name: name,
          description: input.description,
          notes: input.notes,
          quantity: quantity,
          placeId: input.placeId,
          statusId: status.id,
          photoFile: stored.photoFile,
          thumbFile: stored.thumbFile,
          createdAt: now,
          updatedAt: now
        )
        try ItemRepository.insert(database, item: item)
        return try TagLinker.replaceForItem(
          database,
          itemId: item.id,
          rawNames: input.tags,
          ids: ids
        )
      }
    }

    mutations.emit(.itemsChanged(itemIds: [id], kind: .created))
    if !outcome.createdTagIds.isEmpty {
      mutations.emit(.tagsChanged(tagIds: outcome.createdTagIds, kind: .created))
    }
    return try get(id)
  }

  public func updateDetails(_ input: ItemDetailsUpdate) throws -> ItemDetails {
    let existing = try get(input.id)
    let name = try validName(input.name)
    let quantity = try validQuantity(input.quantity)
    try validateTags(input.tags)

    let outcome = try photos.replace(
      prepared: input.newPhoto,
      previous: storedPhoto(of: existing.item)
    ) { stored in
      try db.write { database in
        guard try ItemRepository.findOne(database, id: input.id) != nil else {
          throw AppException(
            .validationNotFound,
            params: ["entity": .string("item"), "id": .string(input.id)]
          )
        }
        try ensurePlaceExists(database, input.placeId)

        let now = clock.nowMilliseconds()
        try ItemRepository.updateDetails(
          database,
          id: input.id,
          name: name,
          description: input.description,
          notes: input.notes,
          quantity: quantity,
          placeId: input.placeId,
          photoFile: stored?.photoFile ?? existing.item.photoFile,
          thumbFile: stored?.thumbFile ?? existing.item.thumbFile,
          updatedAt: now
        )
        return try TagLinker.replaceForItem(
          database,
          itemId: input.id,
          rawNames: input.tags,
          ids: ids
        )
      }
    }

    mutations.emit(.itemsChanged(itemIds: [input.id], kind: .updated))
    if outcome.oldTagIds != outcome.tagIds {
      mutations.emit(
        .tagsChanged(
          tagIds: outcome.oldTagIds
            .union(outcome.tagIds)
            .union(outcome.createdTagIds)
            .union(outcome.removedTagIds),
          kind: .updated
        )
      )
    }
    return try get(input.id)
  }

  public func get(_ id: String) throws -> ItemDetails {
    try db.read { database in
      guard let row = try ItemRepository.findOne(database, id: id) else {
        throw AppException(
          .validationNotFound,
          params: ["entity": .string("item"), "id": .string(id)]
        )
      }
      let status =
        try StatusRepository.findOne(database, id: row.item.statusId)
        ?? Status(
          id: row.item.statusId,
          name: row.statusName,
          isArchived: row.statusArchived,
          sortOrder: 0,
          createdAt: row.item.createdAt
        )
      let tags = try TagRepository.tags(forItem: database, itemId: id)
      let path = try placePath(database, placeId: row.item.placeId)
      return ItemDetails(item: row.item, status: status, tags: tags, placePath: path)
    }
  }

  public func list(_ query: GalleryQuery) throws -> [GalleryEntry] {
    try db.read { database in
      let rows = try ItemRepository.all(database)
      let itemTags = try ItemRepository.allItemTags(database)
      let placeScope = try resolvePlaceScope(database, filter: query.place)

      let filtered = rows.filter { row in
        let item = row.item
        if let searchIds = query.searchItemIds, !searchIds.contains(item.id) {
          return false
        }
        if let placeScope, let placeId = item.placeId {
          if !placeScope.contains(placeId) { return false }
        } else if placeScope != nil, item.placeId == nil {
          return false
        }
        if case .noPlace = query.place, item.placeId != nil {
          return false
        }
        if !query.statusIds.isEmpty, !query.statusIds.contains(item.statusId) {
          return false
        }
        if row.statusHidden, !query.showHidden, !query.statusIds.contains(item.statusId) {
          return false
        }
        if !query.tagIds.isEmpty {
          let tags = itemTags[item.id] ?? []
          if !tags.isSuperset(of: query.tagIds) { return false }
        }
        return true
      }

      let entries = filtered.map {
        GalleryEntry(
          item: $0.item,
          statusName: $0.statusName,
          statusArchived: $0.statusArchived
        )
      }
      return sort(entries, sort: query.sort, direction: query.direction)
    }
  }

  // MARK: - Проверки и сборка

  private func validName(_ raw: String) throws -> String {
    try NameKey.parse(raw, field: "itemName").displayName
  }

  private func validQuantity(_ value: Int) throws -> Int {
    guard value >= 1 else {
      throw AppException(
        .validationOutOfRange,
        params: ["field": .string("quantity"), "min": .int(1)]
      )
    }
    return value
  }

  private func validateTags(_ rawNames: [String]) throws {
    for raw in rawNames {
      _ = try TagKey.parse(raw)
    }
  }

  private func resolveCreateStatus(_ db: Database, requested: String?) throws -> Status {
    let statusId: String?
    if let requested {
      statusId = requested
    } else {
      statusId = try StatusRepository.defaultStatusId(db)
    }
    guard let statusId, let status = try StatusRepository.findOne(db, id: statusId) else {
      throw AppException(
        .validationNotFound,
        params: ["entity": .string("status"), "id": .string(statusId ?? "")]
      )
    }
    if status.isArchived {
      throw AppException(.statusArchived, params: ["statusId": .string(status.id)])
    }
    return status
  }

  private func ensurePlaceExists(_ db: Database, _ placeId: String?) throws {
    guard let placeId else { return }
    guard try PlaceRepository.findOne(db, id: placeId) != nil else {
      throw AppException(
        .validationNotFound,
        params: ["entity": .string("place"), "id": .string(placeId)]
      )
    }
  }

  private func storedPhoto(of item: Item) -> StoredPhoto? {
    guard !item.photoFile.isEmpty, !item.thumbFile.isEmpty else { return nil }
    return StoredPhoto(photoFile: item.photoFile, thumbFile: item.thumbFile)
  }

  private func placePath(_ db: Database, placeId: String?) throws -> [Place] {
    guard let placeId else { return [] }
    let all = try PlaceRepository.all(db)
    let byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    var segments: [Place] = []
    var visited: Set<String> = []
    var current: String? = placeId
    while let cursor = current {
      guard visited.insert(cursor).inserted else {
        throw AppException(.placeCycle, params: ["placeId": .string(placeId)])
      }
      guard let place = byId[cursor] else {
        throw AppException(
          .validationNotFound,
          params: ["entity": .string("place"), "id": .string(cursor)]
        )
      }
      segments.append(place)
      current = place.parentId
    }
    return segments.reversed()
  }

  /// nil — без ограничения по месту. Иначе допустимые place_id.
  private func resolvePlaceScope(
    _ db: Database,
    filter: GalleryPlaceFilter
  ) throws -> Set<String>? {
    switch filter {
    case .all, .noPlace:
      return nil
    case .placeOnly(let placeId):
      try ensurePlaceExists(db, placeId)
      return [placeId]
    case .placeSubtree(let placeId):
      try ensurePlaceExists(db, placeId)
      let all = try PlaceRepository.all(db)
      var result: Set<String> = [placeId]
      var queue = [placeId]
      while !queue.isEmpty {
        let current = queue.removeFirst()
        for child in all where child.parentId == current {
          if result.insert(child.id).inserted {
            queue.append(child.id)
          }
        }
      }
      return result
    }
  }

  private func sort(
    _ entries: [GalleryEntry],
    sort: GallerySort,
    direction: GalleryDirection
  ) -> [GalleryEntry] {
    entries.sorted { left, right in
      switch sort {
      case .createdAt:
        if left.item.createdAt != right.item.createdAt {
          return direction == .asc
            ? left.item.createdAt < right.item.createdAt
            : left.item.createdAt > right.item.createdAt
        }
      case .name:
        let byName = NaturalSort.compare(left.item.name, right.item.name)
        if byName != 0 {
          return direction == .asc ? byName < 0 : byName > 0
        }
      }
      // Tie-break всегда id ASC, независимо от направления (D12).
      return left.item.id < right.item.id
    }
  }
}
