import InventoryCore
import InventoryUI
import SwiftUI

/// Фильтры галереи на iPhone (IOS.04): лист с местом, статусами и тегами.
/// Меняет то же сохранённое состояние GalleryModel, что и фильтры на macOS.
struct GalleryFiltersSheet: View {
  @ObservedObject var model: GalleryModel
  @Environment(\.dismiss) private var dismiss

  private static let allPlacesId = ""
  private static let noPlaceId = "__no_place__"

  var body: some View {
    NavigationStack {
      Form {
        Section("Место") {
          Picker("Место", selection: placeSelection) {
            Text("Все места").tag(Self.allPlacesId)
            Text("Без места").tag(Self.noPlaceId)
            ForEach(model.placeChoices) { choice in
              Text(choice.path).tag(choice.id)
            }
          }
        }

        Section("Статусы") {
          ForEach(model.availableStatuses) { status in
            Toggle(
              status.isArchived ? "\(status.name) (архив)" : status.name,
              isOn: statusBinding(status.id)
            )
          }
        }

        Section {
          Toggle("Показывать скрытые", isOn: $model.showHidden)
        } footer: {
          Text(
            "Скрытые статусы (например, «Утеряна») не видны в галерее, пока эта опция выключена."
          )
        }

        Section("Теги") {
          if model.availableTags.isEmpty {
            Text("Тегов пока нет")
              .foregroundColor(.secondary)
          } else {
            ForEach(model.availableTags) { tag in
              Toggle(isOn: tagBinding(tag.id)) {
                HStack {
                  Text(tag.name)
                  Spacer(minLength: 12)
                  Text("\(tag.itemCount)")
                    .foregroundColor(.secondary)
                }
              }
            }
          }
        }
      }
      .navigationTitle("Фильтры")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Сбросить") {
            Task { await model.resetFilters() }
          }
          .disabled(!model.hasActiveFilters)
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Готово") { dismiss() }
            .fontWeight(.semibold)
        }
      }
    }
    .presentationDetents([.medium, .large])
  }

  private var placeSelection: Binding<String> {
    Binding(
      get: {
        if model.state.noPlace { return Self.noPlaceId }
        return model.state.placeId ?? Self.allPlacesId
      },
      set: { value in
        Task {
          if value == Self.noPlaceId {
            await model.setPlaceSelection(placeId: nil, noPlace: true)
          } else if value == Self.allPlacesId {
            await model.setPlaceSelection(placeId: nil, noPlace: false)
          } else {
            await model.setPlaceSelection(placeId: value, noPlace: false)
          }
        }
      }
    )
  }

  private func statusBinding(_ id: String) -> Binding<Bool> {
    Binding(
      get: { model.state.statusIds.contains(id) },
      set: { _ in
        Task { await model.toggleStatus(id) }
      }
    )
  }

  private func tagBinding(_ id: String) -> Binding<Bool> {
    Binding(
      get: { model.state.tagIds.contains(id) },
      set: { _ in
        Task { await model.toggleTag(id) }
      }
    )
  }
}
