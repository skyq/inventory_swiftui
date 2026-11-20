import InventoryCore
import InventoryPlatform
import InventoryUI
import SwiftUI

@main
struct InventoryApp: App {
  @StateObject private var model = InventoryApp.makeModel()

  var body: some Scene {
    WindowGroup {
      InventoryRootView(model: model)
    }
    .commands {
      CommandGroup(replacing: .newItem) {
        Button(L10n.string("items.add")) {
          model.presentCreateItemFromCurrentContext()
        }
        .keyboardShortcut("n", modifiers: .command)
        .disabled(!model.canCreateItem)
      }
      CommandGroup(after: .pasteboard) {
        Divider()
        Button(L10n.string("search.menu")) {
          model.focusSearch()
        }
        .keyboardShortcut("k", modifiers: .command)
        .disabled(!model.isReady)
      }
    }

    Settings {
      SettingsView(model: model)
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
      dialogs: SystemFileDialogs(),
      preferences: preferences
    )
  }
}
