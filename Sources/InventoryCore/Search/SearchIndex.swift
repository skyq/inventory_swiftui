import Foundation

/// Источник текста внутри вещи. Вес поля задан решением D05.
public enum SearchField: Sendable, CaseIterable {
  case name
  case tags
  case placePath
  case people
  case description
  case notes

  public var weight: Double {
    switch self {
    case .name: return 2.0
    case .tags: return 1.5
    case .placePath: return 1.2
    case .people: return 1.0
    case .description: return 0.8
    case .notes: return 0.8
    }
  }
}

/// Индекс в памяти. Каждый токен хранится по трём ключам: точный текст,
/// основа и уменьшительный ключ. Повторы токена внутри вещи не дают дублей
/// itemId (ТЗ §8.2, D05). Потокобезопасен: поиск и обновление защищены
/// блокировкой.
public final class SearchIndex: @unchecked Sendable {
  private struct PostingKey: Hashable {
    let kind: TokenKind
    let term: String
  }

  private struct Posting: Hashable {
    let itemId: String
    let field: SearchField
    let kind: TokenKind
  }

  private let lock = NSLock()
  private var postings: [PostingKey: Set<Posting>] = [:]
  private var keysByItem: [String: Set<PostingKey>] = [:]
  private var itemIds: Set<String> = []

  public init() {}

  public var itemCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return itemIds.count
  }

  public func rebuild(_ documents: [SearchDocument]) {
    lock.lock()
    defer { lock.unlock() }
    postings.removeAll()
    keysByItem.removeAll()
    itemIds.removeAll()
    for document in documents {
      addLocked(document)
    }
  }

  public func update(_ documents: [SearchDocument], removedItemIds: Set<String> = []) {
    lock.lock()
    defer { lock.unlock() }
    for itemId in removedItemIds {
      removeLocked(itemId)
    }
    for document in documents {
      removeLocked(document.itemId)
      addLocked(document)
    }
  }

  /// Вещи, в которых есть совпадение для каждого слова запроса (И).
  /// Итоговый балл — сумма лучших совпадений по словам с весом поля.
  /// Порядок: балл по убыванию, при равенстве — id (D12).
  public func search(_ query: String) -> [SearchHit] {
    let tokens = SearchText.tokenize(query)

    lock.lock()
    defer { lock.unlock() }

    if tokens.isEmpty {
      return itemIds.sorted().map { SearchHit(itemId: $0, score: 0) }
    }

    var totals: [String: Double]?
    for token in tokens {
      var best: [String: Double] = [:]

      if let exact = postings[PostingKey(kind: .exact, term: token.text)] {
        accumulate(exact, match: .exact, into: &best)
      }
      if let stem = postings[PostingKey(kind: .stem, term: token.stem)] {
        accumulate(stem, match: .stem, into: &best)
      }
      if let diminutive = postings[PostingKey(kind: .diminutive, term: token.diminutive)] {
        accumulate(diminutive, match: .diminutive, into: &best)
      }

      // Префикс и нечёткое совпадение проверяются по точным терминам.
      for (key, postings) in postings where key.kind == .exact && key.term != token.text {
        guard let match = TermMatcher.match(token, kind: key.kind, term: key.term) else {
          continue
        }
        accumulate(postings, match: match, into: &best)
      }

      if let existing = totals {
        var merged: [String: Double] = [:]
        merged.reserveCapacity(min(existing.count, best.count))
        for (itemId, score) in existing {
          if let other = best[itemId] {
            merged[itemId] = score + other
          }
        }
        totals = merged
      } else {
        totals = best
      }

      if totals?.isEmpty != false {
        return []
      }
    }

    guard let totals else { return [] }
    return totals.keys.sorted { left, right in
      let leftScore = totals[left] ?? 0
      let rightScore = totals[right] ?? 0
      if leftScore != rightScore { return leftScore > rightScore }
      return left < right
    }.map { SearchHit(itemId: $0, score: totals[$0] ?? 0) }
  }

  // MARK: - Индексирование

  private func addLocked(_ document: SearchDocument) {
    let itemId = document.itemId
    itemIds.insert(itemId)
    var keys = keysByItem[itemId] ?? []
    indexLocked(itemId, field: .name, texts: [document.name], keys: &keys)
    indexLocked(itemId, field: .description, texts: [document.description], keys: &keys)
    indexLocked(itemId, field: .notes, texts: [document.notes], keys: &keys)
    indexLocked(itemId, field: .tags, texts: document.tags, keys: &keys)
    indexLocked(itemId, field: .placePath, texts: document.placePath, keys: &keys)
    indexLocked(itemId, field: .people, texts: document.people, keys: &keys)
    keysByItem[itemId] = keys
  }

  private func indexLocked(
    _ itemId: String,
    field: SearchField,
    texts: [String],
    keys: inout Set<PostingKey>
  ) {
    for text in texts {
      for token in SearchText.tokenize(text) {
        postLocked(itemId, field: field, kind: .exact, term: token.text, keys: &keys)
        postLocked(itemId, field: field, kind: .stem, term: token.stem, keys: &keys)
        postLocked(itemId, field: field, kind: .diminutive, term: token.diminutive, keys: &keys)
      }
    }
  }

  private func postLocked(
    _ itemId: String,
    field: SearchField,
    kind: TokenKind,
    term: String,
    keys: inout Set<PostingKey>
  ) {
    let key = PostingKey(kind: kind, term: term)
    keys.insert(key)
    postings[key, default: []].insert(Posting(itemId: itemId, field: field, kind: kind))
  }

  private func removeLocked(_ itemId: String) {
    itemIds.remove(itemId)
    guard let keys = keysByItem.removeValue(forKey: itemId) else { return }
    for key in keys {
      guard var set = postings[key] else { continue }
      // Поле неизвестно заранее: убираем все записи этой вещи по ключу.
      set = set.filter { $0.itemId != itemId }
      if set.isEmpty {
        postings.removeValue(forKey: key)
      } else {
        postings[key] = set
      }
    }
  }

  private func accumulate(
    _ entries: Set<Posting>,
    match: MatchKind,
    into best: inout [String: Double]
  ) {
    for posting in entries {
      let value = posting.field.weight * match.rawValue
      if value > (best[posting.itemId] ?? 0) {
        best[posting.itemId] = value
      }
    }
  }
}
