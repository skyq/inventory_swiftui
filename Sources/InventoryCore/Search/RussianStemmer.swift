import Foundation

/// Русский стеммер Snowball (порт алгоритма `russian.sbl`) и ключ
/// уменьшительных. Чистый Swift, без NaturalLanguage и системных
/// токенизаторов (ТЗ §8.2, D05).
public enum RussianStemmer {
  private static let vowels: Set<Character> = [
    "а", "е", "и", "о", "у", "ы", "э", "ю", "я",
  ]

  private static let gerunds: [(String, Int)] = [
    ("в", 1), ("ив", 2), ("ыв", 2),
    ("вши", 1), ("ивши", 2), ("ывши", 2),
    ("вшись", 1), ("ившись", 2), ("ывшись", 2),
  ]

  private static let adjectives: [(String, Int)] = [
    ("ее", 1), ("ие", 1), ("ое", 1), ("ые", 1),
    ("ими", 1), ("ыми", 1), ("ей", 1), ("ий", 1), ("ой", 1), ("ый", 1),
    ("ем", 1), ("им", 1), ("ом", 1), ("ым", 1),
    ("его", 1), ("ого", 1), ("ему", 1), ("ому", 1),
    ("их", 1), ("ых", 1), ("ею", 1), ("ою", 1), ("ую", 1), ("юю", 1),
    ("ая", 1), ("яя", 1),
  ]

  private static let participles: [(String, Int)] = [
    ("ем", 1), ("нн", 1), ("вш", 1), ("ивш", 2), ("ывш", 2),
    ("щ", 1), ("ющ", 1), ("ующ", 2),
  ]

  private static let reflexives: [(String, Int)] = [
    ("сь", 1), ("ся", 1),
  ]

  private static let verbs: [(String, Int)] = [
    ("ла", 1), ("ила", 2), ("ыла", 2),
    ("на", 1), ("ена", 2),
    ("ете", 1), ("ите", 2), ("йте", 1), ("ейте", 2), ("уйте", 2),
    ("ли", 1), ("или", 2), ("ыли", 2),
    ("й", 1), ("ей", 2), ("уй", 2),
    ("л", 1), ("ил", 2), ("ыл", 2),
    ("ем", 1), ("им", 2), ("ым", 2),
    ("н", 1), ("ен", 2),
    ("ло", 1), ("ило", 2), ("ыло", 2),
    ("но", 1), ("ено", 2), ("нно", 1),
    ("ет", 1), ("ует", 2), ("ит", 2), ("ыт", 2),
    ("ют", 1), ("уют", 2), ("ят", 2),
    ("ны", 1), ("ены", 2),
    ("ть", 1), ("ить", 2), ("ыть", 2),
    ("ешь", 1), ("ишь", 2),
    ("ю", 2), ("ую", 2),
  ]

  private static let nouns: [(String, Int)] = [
    ("а", 1), ("ев", 1), ("ов", 1),
    ("е", 1), ("ие", 1), ("ье", 1),
    ("и", 1), ("еи", 1), ("ии", 1),
    ("ами", 1), ("ями", 1), ("иями", 1),
    ("й", 1), ("ей", 1), ("ией", 1), ("ий", 1), ("ой", 1),
    ("ам", 1), ("ем", 1), ("ием", 1), ("ом", 1), ("ям", 1), ("иям", 1),
    ("о", 1), ("у", 1),
    ("ах", 1), ("ях", 1), ("иях", 1),
    ("ы", 1), ("ь", 1), ("ю", 1), ("ию", 1), ("ью", 1),
    ("я", 1), ("ия", 1), ("ья", 1),
  ]

  private static let derivationals: [(String, Int)] = [
    ("ост", 1), ("ость", 1),
  ]

  private static let tidy: [(String, Int)] = [
    ("ейше", 1), ("н", 2), ("ейш", 1), ("ь", 3),
  ]

  private static let diminutiveSuffixes: [String] = [
    "очк", "ечк", "оньк", "еньк", "ичк", "иньк",
    "чик", "щик", "ик", "ек", "ок", "к",
  ]

  /// Основа русского слова. Ввод должен быть уже нормализован.
  public static func stem(_ input: String) -> String {
    let word = input.lowercased().replacingOccurrences(of: "ё", with: "е")
    guard let pv = afterFirstVowel(word) else { return word }
    let p2 = secondRegion(word, pv)

    var result = perfectiveGerund(word, pv) ?? reflexiveAndTail(word, pv)
    result = removeFinalI(result, pv)
    result = derivational(result, pv, p2) ?? result
    result = tidyUp(result, pv) ?? result
    return result
  }

  /// Ключ уменьшительных: срезает уменьшительные суффиксы, пока остаток
  /// не короче четырёх символов.
  public static func diminutive(_ stem: String) -> String {
    var word = stem
    var shortened = true
    while shortened {
      shortened = false
      for suffix in diminutiveSuffixes
      where word.count - suffix.count >= 4 && word.hasSuffix(suffix) {
        word = String(word.dropLast(suffix.count))
        shortened = true
        break
      }
    }
    return word
  }

  // MARK: - Шаги алгоритма

  private static func reflexiveAndTail(_ word: String, _ limit: Int) -> String {
    let reflexive = cutSuffix(word, limit, reflexives) ?? word
    return adjectival(reflexive, limit) ?? verb(reflexive, limit) ?? noun(reflexive, limit)
      ?? reflexive
  }

  private static func perfectiveGerund(_ word: String, _ limit: Int) -> String? {
    guard let hit = longest(word, limit, gerunds) else { return nil }
    let start = word.count - hit.length
    if hit.code == 1 {
      return hasAOrYaBefore(word, start, limit) ? prefix(word, start) : nil
    }
    return prefix(word, start)
  }

  private static func adjectival(_ word: String, _ limit: Int) -> String? {
    guard let adjective = cutSuffix(word, limit, adjectives) else { return nil }
    guard let hit = longest(adjective, limit, participles) else { return adjective }
    let start = adjective.count - hit.length
    if hit.code == 1 {
      return hasAOrYaBefore(adjective, start, limit) ? prefix(adjective, start) : adjective
    }
    return prefix(adjective, start)
  }

  private static func verb(_ word: String, _ limit: Int) -> String? {
    guard let hit = longest(word, limit, verbs) else { return nil }
    let start = word.count - hit.length
    if hit.code == 1 {
      return hasAOrYaBefore(word, start, limit) ? prefix(word, start) : nil
    }
    return prefix(word, start)
  }

  private static func noun(_ word: String, _ limit: Int) -> String? {
    cutSuffix(word, limit, nouns)
  }

  private static func removeFinalI(_ word: String, _ limit: Int) -> String {
    guard word.count - 1 >= limit, word.hasSuffix("и") else { return word }
    return String(word.dropLast())
  }

  private static func derivational(_ word: String, _ limit: Int, _ p2: Int) -> String? {
    guard let hit = longest(word, limit, derivationals) else { return nil }
    let start = word.count - hit.length
    guard start >= p2 else { return nil }
    return prefix(word, start)
  }

  private static func tidyUp(_ word: String, _ limit: Int) -> String? {
    guard let hit = longest(word, limit, tidy) else { return nil }
    let start = word.count - hit.length
    switch hit.code {
    case 1:
      var result = prefix(word, start)
      if result.count - 2 >= limit, result.hasSuffix("нн") {
        result = String(result.dropLast())
      }
      return result
    case 2:
      guard start > limit, character(word, at: start - 1) == "н" else { return nil }
      return prefix(word, start)
    default:
      return prefix(word, start)
    }
  }

  // MARK: - Вспомогательные

  private static func cutSuffix(
    _ word: String,
    _ limit: Int,
    _ table: [(String, Int)]
  ) -> String? {
    guard let hit = longest(word, limit, table) else { return nil }
    return prefix(word, word.count - hit.length)
  }

  private static func hasAOrYaBefore(_ word: String, _ start: Int, _ limit: Int) -> Bool {
    let index = start - 1
    guard index >= limit else { return false }
    let char = character(word, at: index)
    return char == "а" || char == "я"
  }

  private static func longest(
    _ word: String,
    _ limit: Int,
    _ table: [(String, Int)]
  ) -> (code: Int, length: Int)? {
    var best: (code: Int, length: Int)?
    for (suffix, code) in table {
      let start = word.count - suffix.count
      guard start >= limit, word.hasSuffix(suffix) else { continue }
      if best == nil || suffix.count > best!.length {
        best = (code: code, length: suffix.count)
      }
    }
    return best
  }

  private static func afterFirstVowel(_ word: String) -> Int? {
    let index = next(word, from: 0, vowel: true)
    return index < 0 ? nil : index + 1
  }

  private static func secondRegion(_ word: String, _ pv: Int) -> Int {
    var index = next(word, from: pv, vowel: false)
    guard index >= 0 else { return word.count }
    index = next(word, from: index + 1, vowel: true)
    guard index >= 0 else { return word.count }
    index = next(word, from: index + 1, vowel: false)
    guard index >= 0 else { return word.count }
    return index + 1
  }

  private static func next(_ word: String, from: Int, vowel: Bool) -> Int {
    var index = from
    while index < word.count {
      if vowels.contains(character(word, at: index)) == vowel {
        return index
      }
      index += 1
    }
    return -1
  }

  private static func prefix(_ word: String, _ length: Int) -> String {
    String(word.prefix(length))
  }

  private static func character(_ word: String, at offset: Int) -> Character {
    word[word.index(word.startIndex, offsetBy: offset)]
  }
}
