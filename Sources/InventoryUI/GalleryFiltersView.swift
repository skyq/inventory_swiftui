#if os(macOS)
  import InventoryCore
  import SwiftUI

  /// Панель фильтров галереи. Меняет сохранённое состояние GalleryState.
  struct GalleryFiltersView: View {
    @ObservedObject var model: GalleryModel

    private static let allPlacesId = ""
    private static let noPlaceId = "__no_place__"

    var body: some View {
      VStack(alignment: .leading, spacing: 14) {
        Text(L10n.string("gallery.filters"))
          .font(.headline)

        VStack(alignment: .leading, spacing: 5) {
          Text(L10n.string("gallery.filters.place"))
            .font(.subheadline)
          Picker("", selection: placeSelection) {
            Text(L10n.string("gallery.filters.allPlaces"))
              .tag(Self.allPlacesId)
            Text(L10n.string("items.noPlace"))
              .tag(Self.noPlaceId)
            ForEach(model.placeChoices) { choice in
              Text(choice.path).tag(choice.id)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
        }

        Divider()

        VStack(alignment: .leading, spacing: 5) {
          Text(L10n.string("gallery.filters.statuses"))
            .font(.subheadline)
          ScrollView {
            VStack(alignment: .leading, spacing: 4) {
              ForEach(model.availableStatuses) { status in
                Toggle(isOn: statusBinding(status.id)) {
                  Text(
                    status.isArchived
                      ? "\(status.name) (\(L10n.string("gallery.archived")))"
                      : status.name
                  )
                }
                .toggleStyle(.checkbox)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(minHeight: 90, maxHeight: .infinity)
        }

        Toggle(L10n.string("gallery.filters.showHidden"), isOn: $model.showHidden)
          .font(.subheadline)

        Divider()

        VStack(alignment: .leading, spacing: 5) {
          Text(L10n.string("gallery.filters.tags"))
            .font(.subheadline)
          if model.availableTags.isEmpty {
            Text(L10n.string("gallery.filters.noTags"))
              .font(.caption)
              .foregroundColor(.secondary)
          } else {
            ScrollView {
              VStack(alignment: .leading, spacing: 4) {
                ForEach(model.availableTags) { tag in
                  Toggle(isOn: tagBinding(tag.id)) {
                    HStack {
                      Text(tag.name)
                      Spacer(minLength: 12)
                      Text("\(tag.itemCount)")
                        .foregroundColor(.secondary)
                    }
                  }
                  .toggleStyle(.checkbox)
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 90, maxHeight: .infinity)
          }
        }

        Divider()

        HStack {
          Button(L10n.string("gallery.filters.reset")) {
            Task { await model.resetFilters() }
          }
          .disabled(!model.hasActiveFilters)
          Spacer()
        }
      }
      .padding(16)
      .frame(minWidth: 300, minHeight: 380, alignment: .topLeading)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
#endif
