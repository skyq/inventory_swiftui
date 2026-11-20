import Foundation
import InventoryCore

/// Все строки интерфейса — в String Catalog (`Localizable.xcstrings`).
public enum L10n {
  public static func string(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), bundle: .module)
  }

  public static func format(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: string(key), locale: Locale.current, arguments: arguments)
  }
}

/// Перевод доменной ошибки в русское сообщение. Технические детали в UI не попадают.
public enum ErrorPresenter {
  public static func message(for error: AppException) -> String {
    switch error.code {
    case .placeNotEmpty:
      return L10n.format(
        "places.notEmptyMessage",
        error.string("name") ?? "",
        error.int("childrenCount") ?? 0,
        error.int("itemsCount") ?? 0
      )
    case .validationRequired where error.string("field") == "photo":
      return L10n.string("places.photoRequired")
    case .validationRequired where error.string("field") == "itemPhoto":
      return L10n.string("items.photoRequired")
    case .validationRequired where error.string("field") == "itemName":
      return L10n.string("items.nameRequired")
    case .validationTooLong where error.string("field") == "itemName":
      return L10n.format("items.nameMaxLength", error.int("max") ?? NameKey.maxLength)
    case .validationRequired where error.string("field") == "tag":
      return L10n.string("items.tagRequired")
    case .validationTooLong where error.string("field") == "tag":
      return L10n.format("items.tagTooLong", error.int("max") ?? TagKey.maxLength)
    case .validationOutOfRange where error.string("field") == "quantity":
      return L10n.string("items.quantityRange")
    case .validationRequired where error.string("field") == "name":
      return L10n.string("places.nameRequired")
    default:
      return L10n.string(error.localizationKey)
    }
  }
}
