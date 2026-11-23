import InventoryCore
import InventoryUI
import SwiftUI

struct IOSRootView: View {
  @ObservedObject var model: AppModel

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
        }
        .padding()
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
