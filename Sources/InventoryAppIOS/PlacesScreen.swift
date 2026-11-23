import InventoryCore
import InventoryUI
import SwiftUI

/// Места на iPhone (IOS.06): обход дерева, вещи текущего уровня, создание и правка мест.
struct PlacesScreen: View {
  @ObservedObject var model: AppModel

  var body: some View {
    NavigationStack {
      Group {
        if let browser = model.browser {
          PlacesContent(browser: browser, model: model)
        }
      }
      .navigationTitle("Места")
    }
  }
}

private struct PlacesContent: View {
  @ObservedObject var browser: PlaceBrowserModel
  let model: AppModel

  @State private var placeForm: PlaceFormPresentation?
  @State private var itemForm: ItemFormPresentation?
  @State private var showsItemCard = false

  var body: some View {
    List {
      Section {
        breadcrumb
      }

      if !browser.isNoPlaceLevel {
        Section(L10n.string("places.title")) {
          ForEach(browser.children) { place in
            Button {
              Task { await browser.open(place) }
            } label: {
              HStack {
                Text(place.name)
                  .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                  .foregroundStyle(.secondary)
              }
            }
            .contextMenu {
              Button(L10n.string("places.edit")) {
                placeForm = PlaceFormPresentation(mode: .edit(place))
              }
              Button(L10n.string("places.delete"), role: .destructive) {
                Task {
                  await browser.select(place)
                  browser.requestDeleteSelected()
                }
              }
            }
          }
          if browser.currentPath.isEmpty {
            Button {
              Task { await browser.openNoPlace() }
            } label: {
              HStack {
                Text(L10n.string("items.noPlace"))
                  .foregroundStyle(.primary)
                Spacer()
                Text("\(browser.noPlaceItemCount)")
                  .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
      }

      Section("Вещи") {
        if browser.isNoPlaceLevel {
          Text(L10n.string("places.noPlaceEmpty"))
            .foregroundStyle(.secondary)
        }
        ForEach(browser.items) { entry in
          Button {
            Task {
              await browser.selectItem(entry)
              showsItemCard = true
            }
          } label: {
            HStack(spacing: 12) {
              AsyncImage(url: browser.thumbnailURL(for: entry)) { image in
                image.resizable().scaledToFill()
              } placeholder: {
                Color.gray.opacity(0.2)
              }
              .frame(width: 44, height: 44)
              .clipShape(RoundedRectangle(cornerRadius: 8))
              VStack(alignment: .leading, spacing: 2) {
                Text(entry.item.name)
                  .foregroundStyle(.primary)
                Text(entry.statusName)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
      }
    }
    .overlay {
      if browser.children.isEmpty && browser.items.isEmpty && !browser.isLoading {
        Text(L10n.string("places.empty"))
          .foregroundStyle(.secondary)
      }
    }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Button(L10n.string("places.add")) {
            placeForm = PlaceFormPresentation(mode: .create(parentId: browser.currentParentId))
          }
          Button(L10n.string("items.newTitle")) {
            itemForm = ItemFormPresentation(mode: .create(placeId: browser.creationPlaceId))
          }
        } label: {
          Label(L10n.string("items.add"), systemImage: "plus")
        }
      }
    }
    .refreshable {
      await browser.reload()
    }
    .task {
      await browser.reload()
    }
    .sheet(
      item: $placeForm,
      onDismiss: {
        Task { await browser.reload() }
      }
    ) { presentation in
      if let formModel = model.makePlaceFormModel(for: presentation) {
        PlaceFormScreen(model: formModel, onClose: { placeForm = nil })
      }
    }
    .sheet(
      item: $itemForm,
      onDismiss: {
        Task { await browser.reload() }
      }
    ) { presentation in
      if let formModel = model.makeItemFormModel(for: presentation) {
        ItemFormScreen(model: formModel, onClose: { itemForm = nil })
      }
    }
    .sheet(
      isPresented: $showsItemCard,
      onDismiss: {
        browser.clearSelection()
        Task { await browser.reload() }
      }
    ) {
      if let details = browser.selectedItem {
        ItemCardView(
          details: details,
          url: browser.photoURL(for: details),
          makeEditModel: { presentation in model.makeItemFormModel(for: presentation) }
        )
      }
    }
    .alert(item: $browser.alert) { alert in
      switch alert {
      case .delete(let place):
        return Alert(
          title: Text(L10n.string("places.deleteTitle")),
          message: Text(L10n.format("places.deleteMessage", place.name)),
          primaryButton: .destructive(Text(L10n.string("places.delete"))) {
            Task { await browser.confirmDelete(place) }
          },
          secondaryButton: .cancel(Text(L10n.string("places.cancel")))
        )
      case .failure(let message):
        return Alert(
          title: Text(L10n.string("common.error")),
          message: Text(message),
          dismissButton: .default(Text(L10n.string("common.ok")))
        )
      }
    }
  }

  private var breadcrumb: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        Button(L10n.string("places.root")) {
          Task { await browser.openRoot() }
        }
        .fontWeight(browser.currentPath.isEmpty && !browser.isNoPlaceLevel ? .semibold : .regular)

        if browser.isNoPlaceLevel {
          Image(systemName: "chevron.right")
            .foregroundStyle(.secondary)
          Text(L10n.string("items.noPlace"))
            .fontWeight(.semibold)
        } else {
          ForEach(browser.currentPath, id: \.id) { place in
            Image(systemName: "chevron.right")
              .foregroundStyle(.secondary)
            Button(place.name) {
              Task { await browser.open(place) }
            }
            .fontWeight(place.id == browser.currentPath.last?.id ? .semibold : .regular)
          }
        }
        if browser.currentPath.isEmpty && !browser.isNoPlaceLevel {
          Spacer(minLength: 0)
        }
        Spacer(minLength: 0)
      }
      .lineLimit(1)
    }
  }
}
