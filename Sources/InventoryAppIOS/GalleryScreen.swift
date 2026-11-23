import InventoryCore
import InventoryUI
import SwiftUI

/// Галерея вещей на iPhone (IOS.04): сетка, поиск и карточка вещи.
struct GalleryScreen: View {
  @ObservedObject var model: AppModel
  @State private var searchText = ""
  @State private var selectedItem: String?

  private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

  var body: some View {
    NavigationStack {
      Group {
        if let gallery = model.gallery {
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
              set: { if !$0 { selectedItem = nil; gallery.clearSelection() } }
            )
          ) {
            if let details = gallery.selected {
              ItemCardView(details: details, url: gallery.photoURL(for: details))
            }
          }
        }
      }
      .navigationTitle("Инвентарь")
    }
  }
}

private struct GalleryTile: View {
  let entry: GalleryEntry
  let url: URL?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      AsyncImage(url: url) { image in
        image.resizable().scaledToFill()
      } placeholder: {
        Color.gray.opacity(0.2)
      }
      .frame(height: 150)
      .clipped()
      .cornerRadius(10)
      Text(entry.item.name)
        .font(.subheadline)
        .lineLimit(2)
      Text(entry.statusName)
        .font(.caption)
        .foregroundColor(.secondary)
    }
  }
}
