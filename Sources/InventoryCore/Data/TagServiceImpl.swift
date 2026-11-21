import Foundation
import GRDB

public final class TagServiceImpl: TagService, @unchecked Sendable {
  private let db: InventoryDatabase
  private let ids: any IdGenerator
  private let mutations: MutationBus

  public init(database: InventoryDatabase, ids: any IdGenerator, mutations: MutationBus) {
    self.db = database
    self.ids = ids
    self.mutations = mutations
  }

  public var changes: AsyncStream<MutationEvent> { mutations.events }

  public func suggest(_ query: String, limit: Int) throws -> [TagSuggestion] {
    let prefix = TagKey.normalize(query)
    let bounded = min(max(limit, 1), 200)
    let all = try db.read { database in
      try TagRepository.suggestions(database)
    }
    let filtered = all.filter { prefix.isEmpty || $0.nameKey.hasPrefix(prefix) }
    let ordered = filtered.sorted { left, right in
      if left.tag.itemCount != right.tag.itemCount {
        return left.tag.itemCount > right.tag.itemCount
      }
      if left.nameKey != right.nameKey { return left.nameKey < right.nameKey }
      return left.tag.id < right.tag.id
    }
    return ordered.prefix(bounded).map(\.tag)
  }

  public func tagsForItem(_ itemId: String) throws -> [Tag] {
    try db.read { database in
      guard
        try Bool.fetchOne(
          database,
          sql: "SELECT 1 FROM items WHERE id = ?",
          arguments: [itemId]
        ) != nil
      else {
        throw AppException(
          .validationNotFound,
          params: ["entity": .string("item"), "id": .string(itemId)]
        )
      }
      return try TagRepository.tags(forItem: database, itemId: itemId)
    }
  }

  public func setItemTags(_ itemId: String, rawNames: [String]) throws {
    let outcome = try db.write { database -> TagLinker.Result in
      guard
        try Bool.fetchOne(
          database,
          sql: "SELECT 1 FROM items WHERE id = ?",
          arguments: [itemId]
        ) != nil
      else {
        throw AppException(
          .validationNotFound,
          params: ["entity": .string("item"), "id": .string(itemId)]
        )
      }
      return try TagLinker.replaceForItem(
        database,
        itemId: itemId,
        rawNames: rawNames,
        ids: ids
      )
    }

    guard outcome.oldTagIds != outcome.tagIds else { return }
    mutations.emit(.itemsChanged(itemIds: [itemId], kind: .updated))
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

  public func removeUnused() throws {
    let removed = try db.write { database in
      try TagRepository.removeUnused(database)
    }
    guard !removed.isEmpty else { return }
    mutations.emit(.tagsChanged(tagIds: removed, kind: .deleted))
  }

  public func listWithCounts() throws -> [TagSuggestion] {
    let all = try db.read { database in
      try TagRepository.suggestions(database).map(\.tag)
    }
    return all.sorted { left, right in
      let byName = NaturalSort.compare(left.name, right.name)
      return byName != 0 ? byName < 0 : left.id < right.id
    }
  }

  public func rename(_ id: String, to name: String) throws -> Tag {
    let key = try TagKey.parse(name)
    let tag = try db.write { database -> Tag in
      guard try TagRepository.findOne(database, id: id) != nil else {
        throw notFound(id)
      }
      if let existing = try TagRepository.findOne(database, nameKey: key.value),
        existing.id != id
      {
        throw conflict(existing)
      }
      try TagRepository.updateName(
        database, id: id, name: key.displayName, nameKey: key.value)
      guard let updated = try TagRepository.findOne(database, id: id) else {
        throw notFound(id)
      }
      return updated
    }
    mutations.emit(.tagsChanged(tagIds: [tag.id], kind: .updated))
    return tag
  }

  public func merge(_ sourceId: String, into targetId: String, resultName: String?) throws -> Tag {
    guard sourceId != targetId else {
      throw AppException(.tagNameConflict, params: ["tagId": .string(sourceId)])
    }

    var finalName: String?
    var finalKey: String?
    if let resultName {
      let key = try TagKey.parse(resultName)
      finalName = key.displayName
      finalKey = key.value
    }

    let outcome = try db.write { database -> (Tag, Set<String>) in
      guard let source = try TagRepository.findOne(database, id: sourceId) else {
        throw notFound(sourceId)
      }
      guard let target = try TagRepository.findOne(database, id: targetId) else {
        throw notFound(targetId)
      }

      let name = finalName ?? target.name
      let nameKey = finalKey ?? target.nameKey
      if let existing = try TagRepository.findOne(database, nameKey: nameKey),
        existing.id != source.id, existing.id != target.id
      {
        throw conflict(existing)
      }

      let affected =
        try TagRepository.itemIds(forTag: database, tagId: source.id)
        .union(try TagRepository.itemIds(forTag: database, tagId: target.id))

      try TagRepository.moveLinks(database, from: source.id, to: target.id)
      try TagRepository.updateName(
        database, id: target.id, name: name, nameKey: nameKey)
      try TagRepository.delete(database, id: source.id)

      guard let updated = try TagRepository.findOne(database, id: target.id) else {
        throw notFound(target.id)
      }
      return (updated, affected)
    }

    mutations.emit(.tagsChanged(tagIds: [sourceId, targetId], kind: .updated))
    if !outcome.1.isEmpty {
      mutations.emit(.itemsChanged(itemIds: outcome.1, kind: .updated))
    }
    return outcome.0
  }

  public func delete(_ id: String) throws -> TagDeletion {
    let affected = try db.write { database -> Set<String> in
      guard let tag = try TagRepository.findOne(database, id: id) else {
        throw notFound(id)
      }
      let itemIds = try TagRepository.itemIds(forTag: database, tagId: tag.id)
      try database.execute(sql: "DELETE FROM item_tags WHERE tag_id = ?", arguments: [id])
      try TagRepository.delete(database, id: id)
      return itemIds
    }

    mutations.emit(.tagsChanged(tagIds: [id], kind: .deleted))
    if !affected.isEmpty {
      mutations.emit(.itemsChanged(itemIds: affected, kind: .updated))
    }
    return TagDeletion(itemIds: affected)
  }

  // MARK: - Внутренние шаги

  private func notFound(_ id: String) -> AppException {
    AppException(
      .validationNotFound,
      params: ["entity": .string("tag"), "id": .string(id)]
    )
  }

  private func conflict(_ tag: Tag) -> AppException {
    AppException(
      .tagNameConflict,
      params: ["tagId": .string(tag.id), "name": .string(tag.name)]
    )
  }
}
