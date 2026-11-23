import InventoryCore
import InventoryPlatform
import InventoryUI
import SwiftUI
import UniformTypeIdentifiers

struct IOSRootView: View {
  @ObservedObject var model: AppModel

  private let preferences = UserDefaultsPreferencesStore()
  @State private var showFolderPicker = false

  var body: some View {
    Group {
      switch model.loadState {
      case .idle, .opening:
        ProgressView("Открываем хранилище…")
      case .failed(let error):
        VStack(spacing: 12) {
          Text(ErrorPresenter.message(for: error))
            .multilineTextAlignment(.center)
          Button("Повторить") {
            Task { await model.retry() }
          }
          Button("Выбрать папку данных…") {
            showFolderPicker = true
          }
        }
        .padding()
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
          guard case .success(let url) = result else { return }
          _ = url.startAccessingSecurityScopedResource()
          ExternalStoreAccess.remember(url, in: preferences)
          Task { await model.openExistingStore(at: url) }
        }
      case .ready:
        TabView {
          GalleryScreen(model: model)
            .tabItem { Label("Вещи", systemImage: "square.grid.2x2") }
          PlacesScreen(model: model)
            .tabItem { Label("Места", systemImage: "mappin.and.ellipse") }
          PeopleScreen(model: model)
            .tabItem { Label("Люди", systemImage: "person.2") }
          ReferencesScreen(model: model)
            .tabItem { Label("Справочники", systemImage: "list.bullet.rectangle") }
          SelfCheckView()
            .tabItem { Label("Проверка", systemImage: "checkmark.seal") }
        }
      }
    }
    .task { await model.start() }
  }
}
