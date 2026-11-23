import InventoryCore
import InventoryUI
import SwiftUI

/// Галерея вещей на iPhone (IOS.04): сетка, поиск и карточка вещи.
struct GalleryScreen: View {
  @ObservedObject var model: AppModel

  var body: some View {
    NavigationStack {
      Group {
        if let gallery = model.gallery {
          GalleryContent(gallery: gallery, model: model)
        }
      }
      .navigationTitle("Инвентарь")
    }
  }
}

/// Наблюдает за GalleryModel напрямую: иначе изменения entries не перерисовывают экран.
private struct GalleryContent: View {
  @ObservedObject var gallery: GalleryModel
  let model: AppModel
  @State private var searchText = ""
  @State private var selectedItem: String?
  @State private var showsFilters = false
  @State private var itemForm: ItemFormPresentation?

  private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

  var body: some View {
    ScrollView {
      LazyVGrid(columns: columns, spacing: 12) {
        ForEach(gallery.entries) { entry in
          Button {
            selectedItem = entry.id
            Task { await gallery.selectItem(id: entry.id) }
          } label: {
            GalleryTile(entry: entry, url: gallery.thumbnailURL(for: entry))
          }
          .buttonStyle(.plain)
        }
      }
      .padding(12)
    }
    .overlay {
      if gallery.entries.isEmpty {
        Text(gallery.isSearchActive ? "Ничего не найдено" : "Вещей пока нет")
          .foregroundColor(.secondary)
      }
    }
    .searchable(text: $searchText, prompt: "Поиск вещей")
    .onChange(of: searchText) { _, text in
      Task { await gallery.setSearchText(text) }
    }
    .sheet(
      isPresented: Binding(
        get: { selectedItem != nil },
        set: {
          if !$0 {
            selectedItem = nil
            gallery.clearSelection()
          }
        }
      ),
      onDismiss: {
        Task { await gallery.reload() }
      }
    ) {
      if let details = gallery.selected {
        ItemCardView(
          details: details,
          url: gallery.photoURL(for: details),
          makeEditModel: { presentation in model.makeItemFormModel(for: presentation) }
        )
      }
    }
    .sheet(isPresented: $showsFilters) {
      GalleryFiltersSheet(model: gallery)
    }
    .sheet(
      item: $itemForm,
      onDismiss: {
        Task { await gallery.reload() }
      }
    ) { presentation in
      if let formModel = model.makeItemFormModel(for: presentation) {
        ItemFormScreen(model: formModel, onClose: { itemForm = nil })
      }
    }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          itemForm = ItemFormPresentation(mode: .create(placeId: nil))
        } label: {
          Label("Новая вещь", systemImage: "plus")
        }
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          showsFilters = true
        } label: {
          Label(
            "Фильтры",
            systemImage: gallery.hasActiveFilters
              ? "line.3.horizontal.decrease.circle.fill"
              : "line.3.horizontal.decrease.circle"
          )
        }
      }
    }
  }
}

private struct GalleryTile: View {
  let entry: GalleryEntry
  let url: URL?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Color.gray.opacity(0.2)
        .aspectRatio(1, contentMode: .fit)
        .overlay {
          AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
          } placeholder: {
            Color.clear
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
      Text(entry.item.name)
        .font(.subheadline)
        .lineLimit(2)
      Text(entry.statusName)
        .font(.caption)
        .foregroundColor(.secondary)
    }
  }
}
