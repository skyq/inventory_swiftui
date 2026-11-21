import Foundation

/// Источник текста для поиска: одна вещь со всеми связанными строками.
///
/// Поля передаются сырыми строками; нормализацию и токенизацию делает индекс
/// (ТЗ §8.1).
public struct SearchDocument: Sendable, Equatable {
  public let itemId: String
  public let name: String
  public let description: String
  public let notes: String
  public let tags: [String]
  /// Название текущего места и всех его предков, от корня.
  public let placePath: [String]
  /// Имена людей из передач и возвратов, включая архивных.
  public let people: [String]

  public init(
    itemId: String,
    name: String,
    description: String = "",
    notes: String = "",
    tags: [String] = [],
    placePath: [String] = [],
    people: [String] = []
  ) {
    self.itemId = itemId
    self.name = name
    self.description = description
    self.notes = notes
    self.tags = tags
    self.placePath = placePath
    self.people = people
  }
}

/// Одно попадание поиска: вещь и её релевантность.
public struct SearchHit: Sendable, Equatable {
  public let itemId: String
  public let score: Double

  public init(itemId: String, score: Double) {
    self.itemId = itemId
    self.score = score
  }
}

/// Поиск по вещам. Результат уже упорядочен по релевантности: балл по
/// убыванию, при равенстве — id по возрастанию (D12).
public protocol SearchService: Sendable {
  func search(_ query: String) -> [SearchHit]
  /// Полная пересборка индекса: открытие/смена хранилища, импорт, восстановление.
  func rebuild() async
  /// Ждёт завершения всех уже поставленных обновлений индекса.
  func waitForIdle() async
  /// Срабатывает после каждого изменения индекса.
  var changes: AsyncStream<Void> { get }
}
