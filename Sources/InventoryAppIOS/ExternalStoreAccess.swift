import Foundation
import InventoryCore

/// Папка данных вне контейнера приложения (например, в «Файлах»): доступ сохраняется между запусками через закладку.
enum ExternalStoreAccess {
  private static let bookmarkKey = "storage.external_bookmark"

  /// Открывает сохранённую папку до проверки и открытия хранилища.
  static func restore(_ preferences: any PreferencesStore) {
    guard let encoded = preferences.string(forKey: bookmarkKey),
      let data = Data(base64Encoded: encoded)
    else { return }
    var stale = false
    guard
      let url = try? URL(
        resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    else { return }
    _ = url.startAccessingSecurityScopedResource()
    if stale {
      remember(url, in: preferences)
    }
  }

  static func remember(_ url: URL, in preferences: any PreferencesStore) {
    guard
      let data = try? url.bookmarkData(
        options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    else { return }
    preferences.setString(data.base64EncodedString(), forKey: bookmarkKey)
  }

  static func forget(in preferences: any PreferencesStore) {
    preferences.setString(nil, forKey: bookmarkKey)
  }
}
