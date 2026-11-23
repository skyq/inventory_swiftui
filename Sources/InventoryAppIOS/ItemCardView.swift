import InventoryCore
import SwiftUI

/// Карточка вещи на iPhone: фото и поля, которые показываются и на macOS.
struct ItemCardView: View {
  let details: ItemDetails
  let url: URL?

  var body: some View {
    NavigationStack {
      List {
        Section {
          AsyncImage(url: url) { image in
            image.resizable().scaledToFit()
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
