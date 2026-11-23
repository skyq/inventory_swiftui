import InventoryCore
import InventoryUI
import SwiftUI

/// Карточка вещи на iPhone: фото и поля, которые показываются и на macOS.
struct ItemCardView: View {
  let details: ItemDetails
  let url: URL?
  let makeEditModel: (ItemFormPresentation) -> ItemFormModel?

  @Environment(\.dismiss) private var dismiss
  @State private var editing: ItemFormPresentation?

  var body: some View {
    NavigationStack {
      List {
        Section {
          AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
              .aspectRatio(1, contentMode: .fit)
              .clipShape(RoundedRectangle(cornerRadius: 10))
          } placeholder: {
            ProgressView()
          }
          .frame(maxWidth: .infinity)
          .listRowInsets(EdgeInsets())
        }
        Section {
          Text(details.item.name)
            .font(.title3)
            .fontWeight(.semibold)
          if !details.item.description.isEmpty {
            Text(details.item.description)
              .foregroundColor(.secondary)
          }
        }
        Section {
          LabeledContent("Статус", value: details.status.name)
          LabeledContent("Место", value: placeText)
          LabeledContent("Теги", value: tagsText)
        }
      }
      .navigationTitle("Вещь")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Изменить") {
            editing = ItemFormPresentation(mode: .edit(details))
          }
        }
      }
      .sheet(item: $editing) { presentation in
        if let formModel = makeEditModel(presentation) {
          ItemFormScreen(
            model: formModel,
            onClose: {
              editing = nil
              dismiss()
            })
        }
      }
    }
    .presentationDetents([.large])
  }

  private var placeText: String {
    details.placePath.isEmpty ? "Без места" : details.placePath.map(\.name).joined(separator: " / ")
  }

  private var tagsText: String {
    details.tags.isEmpty ? "—" : details.tags.map(\.name).joined(separator: ", ")
  }
}
