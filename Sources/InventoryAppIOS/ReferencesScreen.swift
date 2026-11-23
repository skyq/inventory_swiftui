import InventoryUI
import SwiftUI

/// Вкладка «Справочники» на iPhone (IOS.06): статусы и теги.
struct ReferencesScreen: View {
  @ObservedObject var model: AppModel

  var body: some View {
    NavigationStack {
      List {
        NavigationLink {
          StatusesScreen(model: model)
        } label: {
          Label(L10n.string("statuses.title"), systemImage: "flag")
        }
        NavigationLink {
          TagsScreen(model: model)
        } label: {
          Label(L10n.string("tags.title"), systemImage: "tag")
        }
      }
      .navigationTitle(L10n.string("reference.title"))
    }
  }
}
