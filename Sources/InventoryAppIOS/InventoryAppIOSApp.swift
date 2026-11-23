import InventoryCore
import InventoryPlatform
import InventoryUI
import SwiftUI

@main
struct InventoryAppIOSApp: App {
  @StateObject private var model = InventoryAppIOSApp.makeModel()

  var body: some Scene {
    WindowGroup {
      IOSRootView(model: model)
    }
  }

  @MainActor
  private static func makeModel() -> AppModel {
    let preferences = UserDefaultsPreferencesStore()
    ExternalStoreAccess.restore(preferences)
    refreshStoredPath(preferences)
    let bootstrapLogger = RotatingFileLogger(
      directory: DefaultStoreLocation.url().appendingPathComponent("logs", isDirectory: true)
    )
    let storage = StorageCoordinator(
      preferences: preferences,
      logger: bootstrapLogger,
      loggerFactory: { layout in
        RotatingFileLogger(directory: layout.logsURL)
      }
    )
    return AppModel(
      storage: storage,
      imageProcessor: ImageIOProcessor(),
      dialogs: IOSFileDialogs(),
      preferences: preferences
    )
  }
}

extension InventoryAppIOSApp {
  /// На iOS путь к хранилищу меняется при переустановке (новый UUID контейнера).
  /// Если сохранённая папка пропала, а хранилище лежит по стандартному пути, переводим настройку на него.
  @MainActor
  static func refreshStoredPath(_ preferences: any PreferencesStore) {
    let defaultRoot = DefaultStoreLocation.url().path
    let defaultDatabase = StoreLayout(rootURL: URL(fileURLWithPath: defaultRoot)).databasePath
    guard let stored = preferences.string(forKey: PreferenceKeys.activeStorePath), !stored.isEmpty,
      stored != defaultRoot,
      !FileManager.default.fileExists(atPath: stored),
      FileManager.default.fileExists(atPath: defaultDatabase)
    else { return }
    preferences.setString(defaultRoot, forKey: PreferenceKeys.activeStorePath)
  }
}

/// На iPhone выбор папок и архивов идёт через SwiftUI (`fileImporter`), эти методы не вызываются.
@MainActor
final class IOSFileDialogs: FileDialogs {
  func chooseDirectory(startingAt url: URL?) -> URL? { nil }
  func chooseImageFile() -> URL? { nil }
  func chooseArchiveFile() -> URL? { nil }
}
