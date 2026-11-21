import Foundation

/// Пересечение поиска с галереей без потери ранга (D12).
public enum SearchRanking {
  /// Релевантность — главный порядок, порядок галереи — вторичный, финальный
  /// tie-break — id. Вещи без попадания в `hits` отбрасываются.
  public static func order(entries: [GalleryEntry], hits: [SearchHit]) -> [GalleryEntry] {
    var scoreById: [String: Double] = [:]
    for hit in hits {
      if let existing = scoreById[hit.itemId], existing >= hit.score {
        continue
      }
      scoreById[hit.itemId] = hit.score
    }

    var galleryIndexById: [String: Int] = [:]
    for (index, entry) in entries.enumerated() {
      galleryIndexById[entry.id] = index
    }

    return
      entries
      .filter { scoreById[$0.id] != nil }
      .sorted { left, right in
        let leftScore = scoreById[left.id] ?? 0
        let rightScore = scoreById[right.id] ?? 0
        if leftScore != rightScore {
          return leftScore > rightScore
        }
        let leftIndex = galleryIndexById[left.id] ?? 0
        let rightIndex = galleryIndexById[right.id] ?? 0
        if leftIndex != rightIndex {
          return leftIndex < rightIndex
        }
        return left.id < right.id
      }
  }
}
