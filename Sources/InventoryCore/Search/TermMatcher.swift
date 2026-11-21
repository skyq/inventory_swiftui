import Foundation

/// Как токен документа попал в индекс: точный текст, основа, уменьшительный
/// ключ.
public enum TokenKind: Sendable, Hashable {
  case exact
  case stem
  case diminutive
}

/// Вид совпадения термина запроса с термином индекса. Вес убывает по
/// порядку (D05: exact > stem > prefix > fuzzy).
public enum MatchKind: Double, Sendable, CaseIterable {
  case exact = 1.0
  case stem = 0.8
  case diminutive = 0.7
  case prefix = 0.6
  case fuzzy = 0.4
}

/// Правила сопоставления одного термина запроса. Без словарей и
/// хардкода отдельных слов.
public enum TermMatcher {
  static let minPrefixLength = 2

  /// Совпадение термина индекса вида `kind` с токеном запроса `query`.
  public static func match(_ query: SearchToken, kind: TokenKind, term: String) -> MatchKind? {
    switch kind {
    case .exact:
      if term == query.text {
        return .exact
      }
      if query.text.count >= minPrefixLength, term.hasPrefix(query.text) {
        return .prefix
      }
      return isTypo(query.text, term) ? .fuzzy : nil
    case .stem:
      return term == query.stem ? .stem : nil
    case .diminutive:
      return term == query.diminutive ? .diminutive : nil
    }
  }

  /// Допустимое число правок по длине слова запроса.
  ///
  /// Короче 4 символов — без опечаток; 4–7 — одна правка; от 8 — две.
  public static func maxEditDistance(length: Int) -> Int {
    if length < 4 { return 0 }
    if length < 8 { return 1 }
    return 2
  }

  /// Опечатка: совпадает первая буква, расстояние Дамерау–Левенштейна
  /// (перестановка соседних букв — одна правка) не выше порога.
  static func isTypo(_ query: String, _ term: String) -> Bool {
    guard let firstQuery = query.first, let firstTerm = term.first,
      firstQuery == firstTerm
    else {
      return false
    }
    let limit = maxEditDistance(length: query.count)
    guard limit > 0, abs(query.count - term.count) <= limit else { return false }
    return editDistance(query, term) <= limit
  }

  /// Расстояние Дамерау–Левенштейна с транспозицией соседних символов.
  public static func editDistance(_ left: String, _ right: String) -> Int {
    let a = Array(left)
    let b = Array(right)
    var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
    for i in 0...a.count { d[i][0] = i }
    for j in 0...b.count { d[0][j] = j }

    guard !a.isEmpty, !b.isEmpty else { return d[a.count][b.count] }

    for i in 1...a.count {
      for j in 1...b.count {
        let cost = a[i - 1] == b[j - 1] ? 0 : 1
        var best = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
        if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
          best = min(best, d[i - 2][j - 2] + 1)
        }
        d[i][j] = best
      }
    }
    return d[a.count][b.count]
  }
}
