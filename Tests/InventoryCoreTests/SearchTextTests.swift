import Foundation
import InventoryCore
import Testing

@Suite("Поиск: нормализация и токены")
struct SearchTextTests {
  @Test("Нижний регистр, ё→е и пунктуация в пробелы")
  func normalizes() {
    #expect(SearchText.normalize("  ЁЛКА!  ") == "елка")
    #expect(SearchText.normalize("Шкаф, «Верхняя» полка") == "шкаф верхняя полка")
  }

  @Test("«ЁЛКА!» и «елка» дают совместимые токены")
  func yoAndE() {
    #expect(SearchText.tokenize("ЁЛКА!") == SearchText.tokenize("елка"))
  }

  @Test("Пустая и пунктуационная строка не падают")
  func emptyInput() {
    #expect(SearchText.tokenize("").isEmpty)
    #expect(SearchText.tokenize("   ").isEmpty)
    #expect(SearchText.tokenize("!?.,;:-—«»").isEmpty)
    #expect(SearchText.normalize("!!!").isEmpty)
  }

  @Test("Исходный токен и основа хранятся отдельно")
  func keepsTextAndStem() {
    let token = SearchText.tokenize("Куртки").first
    #expect(token?.text == "куртки")
    #expect(token?.stem == "куртк")
    #expect(token?.diminutive == "курт")
  }

  @Test("Куртки, куртку и курточку совпадают по основе или ключу")
  func forms() {
    let kurtki = SearchText.tokenize("куртки").first
    let kurtku = SearchText.tokenize("куртку").first
    let kurtochku = SearchText.tokenize("курточку").first
    #expect(kurtki?.stem == kurtku?.stem)
    #expect(kurtochku?.diminutive == kurtki?.diminutive)
  }

  @Test("Латиница и цифры не стеммируются")
  func latinAndDigits() {
    let tokens = SearchText.tokenize("Ski-Jumps 2026")
    #expect(tokens.map(\.text) == ["ski", "jumps", "2026"])
    #expect(tokens.map(\.stem) == ["ski", "jumps", "2026"])
  }

  @Test("Смешанный текст даёт токены по словам")
  func mixedText() {
    let tokens = SearchText.tokenize("Шкаф 2, верхняя полка")
    #expect(tokens.map(\.text) == ["шкаф", "2", "верхняя", "полка"])
  }
}
