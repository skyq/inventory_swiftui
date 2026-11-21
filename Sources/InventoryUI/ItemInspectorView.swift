import InventoryCore
import SwiftUI

/// Карточка вещи в правой панели: фото, действия, история и путь места.
struct ItemInspectorView: View {
  let details: ItemDetails
  let photoURL: URL?
  let history: [ItemHistoryEntry]
  let onEdit: () -> Void
  let onChangeStatus: () -> Void
  let onGive: () -> Void
  let onReturn: () -> Void
  let onOpenPlace: (String) -> Void
  let onOpenPerson: (String) -> Void
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

        actions

        Divider()

        detailRow(title: L10n.string("items.created"), value: format(details.item.createdAt))
        detailRow(title: L10n.string("items.updated"), value: format(details.item.updatedAt))

        Divider()

        historySection
      }
      .padding(16)
    }
  }

  private var actions: some View {
    HStack(spacing: 8) {
      Menu {
        Button(L10n.string("items.changeStatus"), action: onChangeStatus)
        Button(L10n.string("items.give"), action: onGive)
        Button(L10n.string("items.return"), action: onReturn)
        Divider()
        Button(L10n.string("items.edit"), action: onEdit)
      } label: {
        Label(L10n.string("items.actions"), systemImage: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help(L10n.string("items.actions"))
      Spacer()
    }
  }

  private var historySection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(L10n.string("items.history"))
        .font(.headline)

      if history.isEmpty {
        Text(L10n.string("items.historyEmpty"))
          .font(.callout)
          .foregroundColor(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(history) { entry in
            ItemHistoryRow(entry: entry, onOpenPerson: onOpenPerson)
          }
        }
      }
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
    HistoryFormat.date(milliseconds)
  }
}

/// Одна строка единой ленты вещи.
struct ItemHistoryRow: View {
  let entry: ItemHistoryEntry
  let onOpenPerson: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        Image(systemName: icon)
          .foregroundColor(.secondary)
          .frame(width: 16)
        Text(title)
          .font(.callout)
        Spacer(minLength: 4)
        Text(HistoryFormat.date(entry.occurredAt))
          .font(.caption2)
          .foregroundColor(.secondary)
      }
      if let personName = entry.personName, let personId = entry.personId {
        Button {
          onOpenPerson(personId)
        } label: {
          Text(personName)
            .font(.caption)
        }
        .buttonStyle(.link)
        .padding(.leading, 22)
      }
      if !entry.comment.isEmpty {
        Text(entry.comment)
          .font(.caption)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.leading, 22)
      }
    }
  }

  private var icon: String {
    switch entry.kind {
    case .statusChange: return "arrow.triangle.swap"
    case .give: return "arrow.up.right"
    case .returnTransfer: return "arrow.down.left"
    }
  }

  private var title: String {
    switch entry.kind {
    case .statusChange:
      let from = entry.fromStatusName ?? "—"
      let to = entry.toStatusName ?? "—"
      return "\(from) → \(to)"
    case .give:
      return L10n.string("items.historyGive")
    case .returnTransfer:
      return L10n.string("items.historyReturn")
    }
  }
}

/// Одна передача/возврат в карточке человека.
struct PersonHistoryRow: View {
  let entry: PersonHistoryEntry
  let onOpenItem: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        Image(systemName: icon)
          .foregroundColor(.secondary)
          .frame(width: 16)
        Text(kindTitle)
          .font(.callout)
        Spacer(minLength: 4)
        Text(HistoryFormat.date(entry.occurredAt))
          .font(.caption2)
          .foregroundColor(.secondary)
      }
      Button {
        onOpenItem(entry.itemId)
      } label: {
        Text(entry.itemName)
          .font(.caption)
      }
      .buttonStyle(.link)
      .padding(.leading, 22)
      if !entry.comment.isEmpty {
        Text(entry.comment)
          .font(.caption)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.leading, 22)
      }
    }
  }

  private var icon: String {
    entry.kind == .give ? "arrow.up.right" : "arrow.down.left"
  }

  private var kindTitle: String {
    entry.kind == .give
      ? L10n.string("items.historyGive")
      : L10n.string("items.historyReturn")
  }
}

enum HistoryFormat {
  static func date(_ milliseconds: Int64) -> String {
    let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    return date.formatted(date: .abbreviated, time: .shortened)
  }
}
