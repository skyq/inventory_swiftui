import Foundation
import GRDB

public final class PlaceServiceImpl: PlaceService, @unchecked Sendable {
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

  public func create(_ input: PlaceCreate, duplicateConfirmed: Bool) throws -> Place {
    let name = try validName(input.name)
    guard let photo = input.photo, !photo.photoBytes.isEmpty, !photo.thumbBytes.isEmpty else {
      throw AppException(.validationRequired, params: ["field": .string("photo")])
    }

    let now = clock.nowMilliseconds()
    let id = ids.next()

    let place = try photos.replace(prepared: photo, previous: nil) { stored in
      try db.write { database in
        if let parentId = input.parentId {
          guard try PlaceRepository.findOne(database, id: parentId) != nil else {
            throw AppException(
              .validationNotFound,
              params: ["entity": .string("place"), "id": .string(parentId)]
            )
          }
        }
        if !duplicateConfirmed,
          try PlaceRepository.duplicateExists(
            database,
            nameKey: NameKey.parseUnchecked(name),
            parentId: input.parentId,
            excluding: nil
          )
        {
          throw AppException(
            .duplicateName,
            params: [
              "entity": .string("place"),
              "name": .string(name),
              "parentId": .string(input.parentId ?? ""),
            ]
          )
        }

        let created = Place(
          id: id,
          parentId: input.parentId,
          name: name,
          description: input.description,
          photoFile: stored?.photoFile,
          thumbFile: stored?.thumbFile,
          createdAt: now,
          updatedAt: now
        )
        try PlaceRepository.insert(database, place: created)
        return created
      }
    }

    mutations.emit(
      .placesChanged(affectedIds: [place.id], parentId: place.parentId, kind: .created))
    return place
  }

  public func get(_ id: String) throws -> Place {
    let place = try db.read { database in
      try PlaceRepository.findOne(database, id: id)
    }
    guard let place else {
      throw AppException(
        .validationNotFound,
        params: ["entity": .string("place"), "id": .string(id)]
      )
    }
    return place
  }

  public func updateDetails(
    _ input: PlaceDetailsUpdate,
    duplicateConfirmed: Bool
  ) throws -> Place {
    let existing = try get(input.id)
    let name = try validName(input.name)
    let parentChanged = existing.parentId != input.parentId

    let result = try photos.replace(prepared: input.newPhoto, previous: storedPhoto(of: existing)) {
      stored in
      try db.write { database in
        guard let current = try PlaceRepository.findOne(database, id: input.id) else {
          throw AppException(
            .validationNotFound,
            params: ["entity": .string("place"), "id": .string(input.id)]
          )
        }

        if parentChanged, let parentId = input.parentId {
          guard try PlaceRepository.findOne(database, id: parentId) != nil else {
            throw AppException(
              .validationNotFound,
              params: ["entity": .string("place"), "id": .string(parentId)]
            )
          }
          let invalid = try invalidParentIds(database, placeId: current.id)
          if invalid.contains(parentId) {
            throw AppException(
              .placeCycle,
              params: ["placeId": .string(current.id), "parentId": .string(parentId)]
            )
          }
        }

        if !duplicateConfirmed,
          try PlaceRepository.duplicateExists(
            database,
            nameKey: NameKey.parseUnchecked(name),
            parentId: input.parentId,
            excluding: current.id
          )
        {
          throw AppException(
            .duplicateName,
            params: [
              "entity": .string("place"),
              "name": .string(name),
              "parentId": .string(input.parentId ?? ""),
            ]
          )
        }

        let affected: Set<String>
        if parentChanged {
          var ids: Set<String> = [current.id]
          ids.formUnion(try descendantIds(database, of: current.id))
          affected = ids
        } else {
          affected = [current.id]
        }

        let now = clock.nowMilliseconds()
        try PlaceRepository.updateDetails(
          database,
          id: current.id,
          name: name,
          description: input.description,
          photoFile: stored?.photoFile ?? existing.photoFile,
          thumbFile: stored?.thumbFile ?? existing.thumbFile,
          parentId: input.parentId,
          updatedAt: now
        )

        let updated = Place(
          id: current.id,
          parentId: input.parentId,
          name: name,
          description: input.description,
          photoFile: stored?.photoFile ?? existing.photoFile,
          thumbFile: stored?.thumbFile ?? existing.thumbFile,
          createdAt: existing.createdAt,
          updatedAt: now
        )
        return (updated, affected)
      }
    }

    mutations.emit(
      .placesChanged(
        affectedIds: result.1,
        parentId: result.0.parentId,
        kind: parentChanged ? .moved : .updated
      )
    )
    return result.0
  }

  public func move(_ id: String, newParentId: String?) throws -> Place {
    let existing = try get(id)
    guard existing.parentId != newParentId else { return existing }

    let result = try db.write { database in
      guard let current = try PlaceRepository.findOne(database, id: id) else {
        throw AppException(
          .validationNotFound,
          params: ["entity": .string("place"), "id": .string(id)]
        )
      }
      if let newParentId {
        guard try PlaceRepository.findOne(database, id: newParentId) != nil else {
          throw AppException(
            .validationNotFound,
            params: ["entity": .string("place"), "id": .string(newParentId)]
          )
        }
        let invalid = try invalidParentIds(database, placeId: current.id)
        if invalid.contains(newParentId) {
          throw AppException(
            .placeCycle,
            params: ["placeId": .string(current.id), "parentId": .string(newParentId)]
          )
        }
      }

      let affected = try descendantIds(database, of: current.id).union([current.id])
      let now = clock.nowMilliseconds()
      try PlaceRepository.updateParent(
        database, id: current.id, parentId: newParentId, updatedAt: now)

      let moved = Place(
        id: current.id,
        parentId: newParentId,
        name: current.name,
        description: current.description,
        photoFile: current.photoFile,
        thumbFile: current.thumbFile,
        createdAt: current.createdAt,
        updatedAt: now
      )
      return (moved, affected)
    }

    mutations.emit(
      .placesChanged(affectedIds: result.1, parentId: newParentId, kind: .moved)
    )
    return result.0
  }

  public func deleteEmpty(_ id: String) throws {
    let existing = try get(id)

    try db.write { database in
      let childrenCount = try PlaceRepository.countChildren(database, id: id)
      let itemsCount = try PlaceRepository.countItems(database, id: id)
      if childrenCount > 0 || itemsCount > 0 {
        throw AppException(
          .placeNotEmpty,
          params: [
            "childrenCount": .int(childrenCount),
            "itemsCount": .int(itemsCount),
            "name": .string(existing.name),
          ]
        )
      }
      try PlaceRepository.delete(database, id: id)
    }

    if let stored = storedPhoto(of: existing) {
      photos.deleteAfterCommit(stored)
    }

    mutations.emit(
      .placesChanged(affectedIds: [existing.id], parentId: existing.parentId, kind: .deleted)
    )
  }

  public func children(of parentId: String?) throws -> [Place] {
    let places = try db.read { database in
      try PlaceRepository.children(database, parentId: parentId)
    }
    return sorted(places)
  }

  public func descendants(of id: String) throws -> [Place] {
    _ = try get(id)
    let places = try db.read { database in
      let all = try PlaceRepository.all(database)
      return descendants(of: id, in: all)
    }
    return sorted(places)
  }

  public func path(to id: String) throws -> PlacePath {
    let all = try db.read { database in
      try PlaceRepository.all(database)
    }
    let byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    var segments: [Place] = []
    var visited: Set<String> = []
    var current: String? = id

    while let cursor = current {
      guard visited.insert(cursor).inserted else {
        throw AppException(
          .placeCycle,
          params: ["placeId": .string(id), "parentId": .string(cursor)]
        )
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

    return PlacePath(segments: segments.reversed())
  }

  public func all() throws -> [Place] {
    let places = try db.read { database in
      try PlaceRepository.all(database)
    }
    return sorted(places)
  }

  public func invalidParentIds(for placeId: String?) throws -> Set<String> {
    guard let placeId else { return [] }
    let result = try db.read { database in
      try invalidParentIds(database, placeId: placeId)
    }
    return result
  }

  // MARK: - Внутренние проверки

  private func invalidParentIds(_ database: Database, placeId: String) throws -> Set<String> {
    var result = try descendantIds(database, of: placeId)
    result.insert(placeId)
    return result
  }

  private func descendantIds(_ database: Database, of id: String) throws -> Set<String> {
    let all = try PlaceRepository.all(database)
    return Set(descendants(of: id, in: all).map(\.id))
  }

  private func descendants(of id: String, in all: [Place]) -> [Place] {
    var byParent: [String?: [Place]] = [:]
    for place in all {
      byParent[place.parentId, default: []].append(place)
    }

    var result: [Place] = []
    var queue: [String] = [id]
    var visited: Set<String> = [id]
    while !queue.isEmpty {
      let current = queue.removeFirst()
      for child in byParent[current] ?? [] where visited.insert(child.id).inserted {
        result.append(child)
        queue.append(child.id)
      }
    }
    return result
  }

  private func sorted(_ places: [Place]) -> [Place] {
    places.sorted { left, right in
      let byName = NaturalSort.compare(left.name, right.name)
      return byName != 0 ? byName < 0 : left.id < right.id
    }
  }

  private func validName(_ raw: String) throws -> String {
    try NameKey.parse(raw, field: "name").displayName
  }

  private func storedPhoto(of place: Place) -> StoredPhoto? {
    guard let photoFile = place.photoFile, let thumbFile = place.thumbFile else { return nil }
    return StoredPhoto(photoFile: photoFile, thumbFile: thumbFile)
  }
}
