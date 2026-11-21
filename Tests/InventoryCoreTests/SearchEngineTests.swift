import Foundation
import InventoryCore
import Testing

@Suite("Поиск: совпадения и ранжирование")
struct SearchEngineTests {
  private func makeIndex(_ documents: [SearchDocument]) -> SearchIndex {
    let index = SearchIndex()
    index.rebuild(documents)
    return index
  }

  private func ids(_ index: SearchIndex, _ query: String) -> [String] {
    index.search(query).map(\.itemId)
  }

  // MARK: - ТЗ §8.3

  @Test("«куртка» находит «куртки», «куртку» и «курточку»")
  func kurtkaForms() {
    let index = makeIndex([
      SearchDocument(itemId: "a", name: "Куртки"),
      SearchDocument(itemId: "b", name: "Куртку"),
      SearchDocument(itemId: "c", name: "Курточку"),
      SearchDocument(itemId: "d", name: "Дрель"),
    ])
    #expect(Set(ids(index, "куртка")) == ["a", "b", "c"])
  }

  @Test("«курка» находит «куртка» (опечатка)")
  func typo() {
    let index = makeIndex([SearchDocument(itemId: "a", name: "Куртка")])
    #expect(ids(index, "курка") == ["a"])
  }

  @Test("«ёлка» находит «елка» и наоборот")
  func yo() {
    let index = makeIndex([
      SearchDocument(itemId: "a", name: "Елка"),
      SearchDocument(itemId: "b", name: "Ёлка"),
    ])
    #expect(ids(index, "ёлка") == ["a", "b"])
    #expect(ids(index, "елка") == ["a", "b"])
  }

  @Test("«шкаф» находит вещь на полке в шкафу")
  func placePath() {
    let index = makeIndex([
      SearchDocument(
        itemId: "coat",
        name: "Куртка",
        placePath: ["Шкаф", "Верхняя полка"]
      ),
      SearchDocument(itemId: "spoon", name: "Ложка"),
    ])
    #expect(ids(index, "шкаф") == ["coat"])
  }

  @Test("Имя архивного человека из передачи попадает в индекс")
  func archivedPerson() {
    let index = makeIndex([
      SearchDocument(itemId: "drill", name: "Дрель", people: ["Антон Архивный"])
    ])
    #expect(ids(index, "антон") == ["drill"])
  }

  // MARK: - Префикс и опечатки

  @Test("Запрос от двух букв находит начало слова")
  func prefix() {
    let index = makeIndex([SearchDocument(itemId: "a", name: "Куртка")])
    #expect(ids(index, "кур") == ["a"])
  }

  @Test("Одна буква не считается префиксом")
  func shortPrefix() {
    let index = makeIndex([SearchDocument(itemId: "a", name: "Куртка")])
    #expect(ids(index, "к").isEmpty)
  }

  @Test("Перестановка соседних букв — одна правка")
  func transposition() {
    let index = makeIndex([
      SearchDocument(itemId: "shkaf", name: "Шкаф"),
      SearchDocument(itemId: "kurtka", name: "Куртка"),
    ])
    #expect(ids(index, "шакф") == ["shkaf"])
    #expect(ids(index, "куртак") == ["kurtka"])
  }

  @Test("Короткие слова (до 3 букв) без опечаток")
  func shortWordsNoTypos() {
    let index = makeIndex([SearchDocument(itemId: "a", name: "Дом")])
    #expect(ids(index, "дол").isEmpty)
    #expect(ids(index, "дом") == ["a"])
  }

  @Test("Порог зависит от длины слова")
  func editThreshold() {
    #expect(TermMatcher.maxEditDistance(length: 3) == 0)
    #expect(TermMatcher.maxEditDistance(length: 4) == 1)
    #expect(TermMatcher.maxEditDistance(length: 7) == 1)
    #expect(TermMatcher.maxEditDistance(length: 8) == 2)
  }

  @Test("Расстояние Дамерау–Левенштейна считает перестановку одной правкой")
  func editDistance() {
    #expect(TermMatcher.editDistance("куртка", "кутрка") == 1)
    #expect(TermMatcher.editDistance("куртка", "курка") == 1)
    #expect(TermMatcher.editDistance("кот", "кот") == 0)
  }

  // MARK: - Ранжирование

  @Test("Точное совпадение выше основы, основа выше опечатки")
  func matchKinds() {
    let index = makeIndex([
      SearchDocument(itemId: "typo", name: "Курка"),
      SearchDocument(itemId: "stem", name: "Куртки"),
      SearchDocument(itemId: "exact", name: "Куртка"),
    ])
    #expect(ids(index, "куртка") == ["exact", "stem", "typo"])
  }

  @Test("Префикс ниже точного совпадения и выше опечатки")
  func prefixRank() {
    let index = makeIndex([
      SearchDocument(itemId: "fuzzy", name: "Пухк"),
      SearchDocument(itemId: "prefix", name: "Пуховик"),
      SearchDocument(itemId: "exact", name: "Пухо"),
    ])
    #expect(ids(index, "пухо") == ["exact", "prefix", "fuzzy"])
  }

  @Test("Название весомее описания и заметок")
  func fieldWeights() {
    let index = makeIndex([
      SearchDocument(itemId: "notes", name: "Ложка", notes: "дрель"),
      SearchDocument(itemId: "desc", name: "Ложка", description: "дрель"),
      SearchDocument(itemId: "name", name: "Дрель"),
    ])
    #expect(ids(index, "дрель") == ["name", "desc", "notes"])
    #expect(SearchField.name.weight > SearchField.notes.weight)
    #expect(SearchField.name.weight > SearchField.description.weight)
  }

  @Test("Основа совпадает, даже когда стеммер не изменил слово запроса")
  func stemWhenStemEqualsWord() {
    let index = makeIndex([SearchDocument(itemId: "a", name: "Столы")])
    let hits = index.search("стол")
    #expect(hits.map(\.itemId) == ["a"])
    #expect(abs((hits.first?.score ?? 0) - 1.6) < 0.0001)
  }

  @Test("Равный балл сортируется по id")
  func idTieBreak() {
    let index = makeIndex([
      SearchDocument(itemId: "c", name: "Ложка"),
      SearchDocument(itemId: "a", name: "Ложка"),
      SearchDocument(itemId: "b", name: "Ложка"),
    ])
    #expect(ids(index, "ложка") == ["a", "b", "c"])
  }

  @Test("Результат не зависит от порядка документов")
  func deterministic() {
    let documents = [
      SearchDocument(itemId: "a", name: "Куртка"),
      SearchDocument(itemId: "b", name: "Курка"),
      SearchDocument(itemId: "c", name: "Курточка"),
    ]
    let forward = makeIndex(documents)
    let backward = makeIndex(documents.reversed())
    #expect(ids(forward, "куртка") == ids(backward, "куртка"))
  }

  @Test("Несколько слов объединяются по И")
  func andSemantics() {
    let index = makeIndex([
      SearchDocument(itemId: "a", name: "Куртка", placePath: ["Шкаф"]),
      SearchDocument(itemId: "b", name: "Куртка", placePath: ["Комод"]),
      SearchDocument(itemId: "c", name: "Дрель", placePath: ["Шкаф"]),
    ])
    #expect(ids(index, "куртка шкаф") == ["a"])
    #expect(ids(index, "дрель куртка").isEmpty)
    #expect(ids(index, "куртка комод") == ["b"])
  }

  @Test("Пустой запрос возвращает все вещи")
  func emptyQuery() {
    let index = makeIndex([
      SearchDocument(itemId: "b", name: "Дрель"),
      SearchDocument(itemId: "a", name: "Куртка"),
    ])
    #expect(ids(index, "") == ["a", "b"])
    #expect(ids(index, "  !!  ") == ["a", "b"])
  }

  @Test("Повторы токенов не создают дублей itemId")
  func duplicates() {
    let index = makeIndex([
      SearchDocument(
        itemId: "spoon",
        name: "Ложка ложка ложки",
        description: "ложка",
        notes: "ложки",
        tags: ["ложка"]
      )
    ])
    #expect(ids(index, "ложка") == ["spoon"])
  }

  @Test("update заменяет документ и удаляет старые токены")
  func update() {
    let index = makeIndex([
      SearchDocument(itemId: "coat", name: "Куртка", notes: "синяя")
    ])
    index.update([
      SearchDocument(itemId: "coat", name: "Пальто", notes: "серое")
    ])
    #expect(ids(index, "куртка").isEmpty)
    #expect(ids(index, "синяя").isEmpty)
    #expect(ids(index, "пальто") == ["coat"])
    #expect(index.itemCount == 1)
  }

  @Test("Удаление вещи убирает её из индекса")
  func removal() {
    let index = makeIndex([
      SearchDocument(itemId: "coat", name: "Куртка"),
      SearchDocument(itemId: "drill", name: "Дрель"),
    ])
    index.update([], removedItemIds: ["coat"])
    #expect(ids(index, "куртка").isEmpty)
    #expect(ids(index, "") == ["drill"])
  }

  // MARK: - Негативные пары D05

  private static let negativePairs: [(String, String)] = [
    ("дрель", "куртка"), ("ложка", "дрель"), ("чайник", "куртка"),
    ("книга", "ложка"), ("ключ", "кружка"), ("молоток", "ложка"),
    ("зонт", "куртка"), ("ботинки", "чайник"), ("велосипед", "книга"),
    ("ножницы", "ключ"), ("лампа", "молоток"), ("подушка", "зонт"),
    ("миска", "ботинки"), ("тарелка", "велосипед"), ("перчатки", "лампа"),
    ("сковорода", "подушка"), ("ведро", "миска"), ("дверь", "тарелка"),
    ("карандаш", "перчатки"), ("свеча", "сковорода"), ("гитара", "ведро"),
    ("пылесос", "дверь"), ("куртина", "куртка"), ("курс", "куртка"),
  ]

  @Test("Набор негативных пар содержит не меньше 20 пар")
  func negativeSetSize() {
    #expect(Self.negativePairs.count >= 20)
  }

  @Test("Неродственные слова не находятся")
  func negatives() {
    let index = makeIndex([SearchDocument(itemId: "x", name: "Куртка")])
    for (query, name) in Self.negativePairs {
      let subject = makeIndex([SearchDocument(itemId: "x", name: name)])
      #expect(ids(subject, query).isEmpty, "«\(query)» не должно находить «\(name)»")
    }
    // Контрольная пара: индекс не пуст и точный запрос работает.
    #expect(ids(index, "куртка") == ["x"])
  }
}
