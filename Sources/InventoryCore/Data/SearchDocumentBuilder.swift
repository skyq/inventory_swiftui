import Foundation
import GRDB

/// Собирает документы поиска из всех требуемых источников: поля вещи, теги,
/// текущее место с предками и все имена людей из передач/возвратов, включая
/// архивных (ТЗ §8.1).
struct SearchDocumentBuilder {
  private let database: InventoryDatabase

  init(database: InventoryDatabase) {
    self.database = database
  }

  func buildAll() throws -> [SearchDocument] {
    try database.read { db in
      let items = try Row.fetchAll(
        db,
        sql: "SELECT id, name, description, notes, place_id FROM items"
      )
      let places = try Row.fetchAll(db, sql: "SELECT id, name, parent_id FROM places")
      let placesById = Dictionary(
        uniqueKeysWithValues: places.map { row in
          (
            row["id"] as String,
            (name: row["name"] as String, parentId: row["parent_id"] as String?)
          )
        }
      )

      var tagsByItem: [String: [String]] = [:]
      for row in try Row.fetchAll(
        db,
        sql: """
          SELECT it.item_id, t.name
          FROM item_tags it
          JOIN tags t ON t.id = it.tag_id
          """
      ) {
        let itemId: String = row["item_id"]
        let name: String = row["name"]
        tagsByItem[itemId, default: []].append(name)
      }

      var peopleByItem: [String: Set<String>] = [:]
      for row in try Row.fetchAll(
        db,
        sql: """
          SELECT tr.item_id, p.name
          FROM transfers tr
          JOIN people p ON p.id = tr.person_id
          """
      ) {
        let itemId: String = row["item_id"]
        let name: String = row["name"]
        peopleByItem[itemId, default: []].insert(name)
      }

      return items.map { row in
        let itemId: String = row["id"]
        return SearchDocument(
          itemId: itemId,
          name: row["name"],
          description: row["description"],
          notes: row["notes"],
          tags: sorted(tagsByItem[itemId] ?? []),
          placePath: placePath(row["place_id"], placesById: placesById),
          people: sorted(Array(peopleByItem[itemId] ?? []))
        )
      }
    }
  }

  private func placePath(
    _ placeId: String?,
    placesById: [String: (name: String, parentId: String?)]
  ) -> [String] {
    var names: [String] = []
    var visited: Set<String> = []
    var current = placeId
    while let cursor = current {
      guard visited.insert(cursor).inserted, let place = placesById[cursor] else {
        return []
      }
      names.append(place.name)
      current = place.parentId
    }
    return names.reversed()
  }

  private func sorted(_ names: [String]) -> [String] {
    names.sorted { left, right in
      let normalized = left.lowercased().compare(right.lowercased())
      return normalized == .orderedSame ? left < right : normalized == .orderedAscending
    }
  }
}
