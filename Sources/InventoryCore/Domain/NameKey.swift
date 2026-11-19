import Foundation

/// Проверенное имя справочника (место, статус, человек).
///
/// Ключ сравнения — trim + Unicode lower без замены ё→е.
public struct NameKey: Sendable, Equatable, CustomStringConvertible {
  public static let maxLength = 200

  /// Ключ без учёта регистра и внешних пробелов.
  public let value: String
  /// Имя для сохранения и показа: trim без изменения регистра.
  public let displayName: String

  private init(value: String, displayName: String) {
    self.value = value
    self.displayName = displayName
  }

  public static func == (left: NameKey, right: NameKey) -> Bool {
    left.value == right.value
  }

  public static func parse(_ raw: String, field: String) throws -> NameKey {
    let displayName = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if displayName.isEmpty {
      throw AppException(.validationRequired, params: ["field": .string(field)])
    }
    if displayName.count > maxLength {
      throw AppException(
        .validationTooLong,
        params: ["field": .string(field), "max": .int(maxLength)]
      )
    }
    return NameKey(value: displayName.lowercased(), displayName: displayName)
  }

  public var description: String { value }
}

/// Естественное сравнение: «Полка 2» идёт перед «Полка 10».
/// Регистр не учитывается, числовые группы сравниваются как числа.
public enum NaturalSort {
  public static func compare(_ left: String, _ right: String) -> Int {
    let a = Array(left.lowercased().utf16)
    let b = Array(right.lowercased().utf16)
    var i = 0
    var j = 0

    while i < a.count && j < b.count {
      let aCode = a[i]
      let bCode = b[j]
      let aDigit = isDigit(aCode)
      let bDigit = isDigit(bCode)

      if aDigit && bDigit {
        let aStart = i
        let bStart = j
        while i < a.count && isDigit(a[i]) { i += 1 }
        while j < b.count && isDigit(b[j]) { j += 1 }
        let aNumber = String(decoding: a[aStart..<i], as: UTF16.self)
          .replacingOccurrences(of: #"^0+"#, with: "", options: .regularExpression)
        let bNumber = String(decoding: b[bStart..<j], as: UTF16.self)
          .replacingOccurrences(of: #"^0+"#, with: "", options: .regularExpression)
        if aNumber.count != bNumber.count {
          return aNumber.count < bNumber.count ? -1 : 1
        }
        if aNumber != bNumber {
          return aNumber < bNumber ? -1 : 1
        }
        continue
      }

      if aCode != bCode {
        return aCode < bCode ? -1 : 1
      }
      i += 1
      j += 1
    }

    if i < a.count { return 1 }
    if j < b.count { return -1 }
    return 0
  }

  private static func isDigit(_ codeUnit: UInt16) -> Bool {
    codeUnit >= 48 && codeUnit <= 57
  }
}
