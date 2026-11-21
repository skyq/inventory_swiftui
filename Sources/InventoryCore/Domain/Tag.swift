import Foundation

/// Проверенный ключ тега: trim, внутренние пробелы схлопнуты, lower, ё→е.
public struct TagKey: Sendable, Equatable, CustomStringConvertible {
  public static let maxLength = 50

  /// Ключ сравнения без учёта регистра и различий е/ё.
  public let value: String
  /// Первое написание для показа: trim и схлопнутые пробелы, регистр сохранён.
  public let displayName: String

  private init(value: String, displayName: String) {
    self.value = value
    self.displayName = displayName
  }

  public static func parse(_ raw: String) throws -> TagKey {
    let displayName = collapse(raw)
    guard !displayName.isEmpty else {
      throw AppException(.validationRequired, params: ["field": .string("tag")])
    }
    let value = displayName.lowercased().replacingOccurrences(of: "ё", with: "е")
    guard displayName.count <= maxLength, value.count <= maxLength else {
      throw AppException(
        .validationTooLong,
        params: ["field": .string("tag"), "max": .int(maxLength)]
      )
    }
    return TagKey(value: value, displayName: displayName)
  }

  /// Ключ без проверки длины. Пустая строка допустима: так нормализуется запрос.
  public static func normalize(_ raw: String) -> String {
    collapse(raw).lowercased().replacingOccurrences(of: "ё", with: "е")
  }

  private static func collapse(_ raw: String) -> String {
    raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
  }

  public var description: String { value }
}

public struct Tag: Identifiable, Sendable, Equatable, Hashable {
  public let id: String
  /// Первое сохранённое написание; при повторном прикреплении не перезаписывается.
  public let name: String
  public let nameKey: String

  public init(id: String, name: String, nameKey: String) {
    self.id = id
    self.name = name
    self.nameKey = nameKey
  }
}

/// Итог удаления тега: вещи, с которых связь снята.
public struct TagDeletion: Sendable, Equatable {
  public let itemIds: Set<String>

  public init(itemIds: Set<String>) {
    self.itemIds = itemIds
  }

  public var itemCount: Int { itemIds.count }
}

public struct TagSuggestion: Identifiable, Sendable, Equatable {
  public let id: String
  public let name: String
  public let itemCount: Int

  public init(id: String, name: String, itemCount: Int) {
    self.id = id
    self.name = name
    self.itemCount = itemCount
  }
}

public protocol TagService: Sendable {
  /// Автодополнение по префиксу ключа. Пустой запрос — самые используемые теги.
  func suggest(_ query: String, limit: Int) throws -> [TagSuggestion]
  func tagsForItem(_ itemId: String) throws -> [Tag]
  /// Заменяет набор тегов вещи. Новые теги создаются в той же транзакции.
  func setItemTags(_ itemId: String, rawNames: [String]) throws
  /// Удаляет теги без вещей.
  func removeUnused() throws
  /// Все теги с количеством вещей; естественная сортировка по имени.
  func listWithCounts() throws -> [TagSuggestion]
  /// Переименование без слияния. Конфликт ключа — `tagNameConflict`.
  func rename(_ id: String, to name: String) throws -> Tag
  /// Объединение связей; `resultName` nil — оставить имя целевого тега.
  func merge(_ sourceId: String, into targetId: String, resultName: String?) throws -> Tag
  /// Снимает тег со всех вещей; возвращает затронутые вещи.
  func delete(_ id: String) throws -> TagDeletion
  var changes: AsyncStream<MutationEvent> { get }
}

extension TagService {
  public func merge(_ sourceId: String, into targetId: String) throws -> Tag {
    try merge(sourceId, into: targetId, resultName: nil)
  }
}

extension TagService {
  public func suggest(_ query: String) throws -> [TagSuggestion] {
    try suggest(query, limit: 10)
  }
}
