import InventoryCore
import SwiftUI

/// Карточка вещи в правой панели: полное фото и кликабельный путь места.
struct ItemInspectorView: View {
  let details: ItemDetails
  let photoURL: URL?
  let onEdit: () -> Void
  let onOpenPlace: (String) -> Void
  let onClose: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Text(L10n.string("items.details"))
            .font(.headline)
          Spacer()
          Button {
            onClose()
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundColor(.secondary)
          }
          .buttonStyle(.plain)
          .help(L10n.string("common.close"))
        }

        PhotoFitView(url: photoURL)

        Text(details.item.name)
          .font(.title3)
          .fontWeight(.semibold)
          .textSelection(.enabled)

        if !details.item.description.isEmpty {
          Text(details.item.description)
            .foregroundColor(.secondary)
            .textSelection(.enabled)
        }

        if !details.item.notes.isEmpty {
          detailRow(title: L10n.string("items.notes"), value: details.item.notes)
        }

        detailRow(
          title: L10n.string("items.status"),
          value: details.status.isArchived
            ? "\(details.status.name) (\(L10n.string("gallery.archived")))"
            : details.status.name
        )
        detailRow(
          title: L10n.string("items.quantity"),
          value: "\(details.item.quantity)"
        )
        detailRow(
          title: L10n.string("items.tags"),
          value: details.tags.isEmpty
            ? L10n.string("items.none")
            : details.tags.map(\.name).joined(separator: ", ")
        )

        VStack(alignment: .leading, spacing: 4) {
          Text(L10n.string("items.place"))
            .font(.caption)
            .foregroundColor(.secondary)
          placeBreadcrumbs
        }

        Divider()

        detailRow(title: L10n.string("items.created"), value: format(details.item.createdAt))
        detailRow(title: L10n.string("items.updated"), value: format(details.item.updatedAt))

        Divider()

        Button(L10n.string("items.edit"), action: onEdit)
          .buttonStyle(.borderedProminent)
      }
      .padding(16)
    }
  }

  @ViewBuilder
  private var placeBreadcrumbs: some View {
    if details.placePath.isEmpty {
      Text(L10n.string("items.noPlace"))
        .font(.callout)
        .foregroundColor(.secondary)
    } else {
      HStack(spacing: 4) {
        ForEach(Array(details.placePath.enumerated()), id: \.element.id) { index, place in
          if index > 0 {
            Image(systemName: "chevron.compact.right")
              .foregroundColor(.secondary)
          }
          Button {
            onOpenPlace(place.id)
          } label: {
            Text(place.name)
              .lineLimit(1)
          }
          .buttonStyle(.plain)
          .foregroundColor(.accentColor)
          .help(place.name)
        }
      }
    }
  }

  private func detailRow(title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.caption)
        .foregroundColor(.secondary)
      Text(value)
        .font(.callout)
        .textSelection(.enabled)
    }
  }

  private func format(_ milliseconds: Int64) -> String {
    let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    return date.formatted(date: .abbreviated, time: .shortened)
  }
}
