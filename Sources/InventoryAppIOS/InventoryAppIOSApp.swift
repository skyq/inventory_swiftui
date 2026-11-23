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

/// Заглушка до IOS.07: выбор папок и архивов на iPhone появится через «Файлы».
@MainActor
final class IOSFileDialogs: FileDialogs {
  func chooseDirectory(startingAt url: URL?) -> URL? { nil }
  func chooseImageFile() -> URL? { nil }
  func chooseArchiveFile() -> URL? { nil }
}
