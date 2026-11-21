import Foundation

/// Токен поискового текста.
///
/// `text` — нормализованный токен для точного совпадения, `stem` — основа,
/// `diminutive` — ключ уменьшительных. Для латиницы и цифр основа не
/// вычисляется и равна `text` (ТЗ §8.2).
public struct SearchToken: Sendable, Equatable {
  public let text: String
  public let stem: String
  public let diminutive: String

  public init(text: String, stem: String, diminutive: String) {
    self.text = text
    self.stem = stem
    self.diminutive = diminutive
  }

  public init(normalized: String) {
    if normalized.unicodeScalars.contains(where: SearchText.isCyrillic) {
      let stem = RussianStemmer.stem(normalized)
      self.init(
        text: normalized,
        stem: stem,
        diminutive: RussianStemmer.diminutive(stem)
      )
    } else {
      self.init(text: normalized, stem: normalized, diminutive: normalized)
    }
  }
}

/// Нормализация и токенизация поискового текста. Чистый Swift.
public enum SearchText {
  /// Нижний регистр, ё→е, пунктуация в пробел, схлопывание пробелов.
  public static func normalize(_ raw: String) -> String {
    let lowered = raw.lowercased().replacingOccurrences(of: "ё", with: "е")
    var result = ""
    var pendingSpace = false
    for scalar in lowered.unicodeScalars {
      if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
        if pendingSpace && !result.isEmpty {
          result.append(" ")
        }
        pendingSpace = false
        result.append(contentsOf: String(scalar))
      } else {
        pendingSpace = true
      }
    }
    return result
  }

  /// Токены запроса или документа. Пустой или пунктуационный ввод даёт
  /// пустой список.
  public static func tokenize(_ raw: String) -> [SearchToken] {
    let normalized = normalize(raw)
    guard !normalized.isEmpty else { return [] }
    return normalized.split(separator: " ").map { SearchToken(normalized: String($0)) }
  }

  static func isCyrillic(_ scalar: Unicode.Scalar) -> Bool {
    (0x0400...0x04FF).contains(scalar.value) || (0x0500...0x052F).contains(scalar.value)
  }
}
