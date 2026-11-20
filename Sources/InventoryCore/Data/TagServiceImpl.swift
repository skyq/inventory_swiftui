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
}
