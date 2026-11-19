import Foundation
import InventoryCore
import Testing

@Suite("Имена и естественная сортировка")
struct NameAndSortTests {
  @Test("NameKey обрезает пробелы и сравнивает без регистра, сохраняя ё")
  func nameKeyRules() throws {
    let key = try NameKey.parse("  Ёлка  ", field: "name")
    #expect(key.displayName == "Ёлка")
    #expect(key.value == "ёлка")

    let other = try NameKey.parse("ёлка", field: "name")
    #expect(key == other)
    #expect(key != (try NameKey.parse("елка", field: "name")))
  }

  @Test("NameKey отвергает пустое и слишком длинное имя")
  func nameKeyValidation() {
    #expect(throws: AppException.self) {
      _ = try NameKey.parse("   ", field: "name")
    }
    #expect(throws: AppException.self) {
      _ = try NameKey.parse(String(repeating: "z", count: 201), field: "name")
    }
  }

  @Test("Естественная сортировка: Полка 2 раньше Полка 10")
  func naturalSort() {
    let names = ["Полка 10", "полка 2", "Полка 1", "Полка"]
    let sorted = names.sorted { NaturalSort.compare($0, $1) < 0 }
    #expect(sorted == ["Полка", "Полка 1", "полка 2", "Полка 10"])
    #expect(NaturalSort.compare("Полка 2", "Полка 10") < 0)
    #expect(NaturalSort.compare("ПОЛКА", "полка") == 0)
    #expect(NaturalSort.compare("007", "7") == 0)
  }
}
