import InventoryCore
import InventoryUI
import SwiftUI

/// Карточка вещи на iPhone: фото, поля, действия (статус, передача, возврат) и история.
struct ItemCardView: View {
  let url: URL?
  let model: AppModel

  @Environment(\.dismiss) private var dismiss
  @State private var current: ItemDetails
  @State private var history: [ItemHistoryEntry] = []
  @State private var editing: ItemFormPresentation?
  @State private var action: ItemAction?

  init(details: ItemDetails, url: URL?, model: AppModel) {
    _current = State(initialValue: details)
    self.url = url
    self.model = model
  }

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
          Text(current.item.name)
            .font(.title3)
            .fontWeight(.semibold)
          if !current.item.description.isEmpty {
            Text(current.item.description)
              .foregroundColor(.secondary)
          }
        }
        Section {
          LabeledContent("Статус", value: current.status.name)
          LabeledContent("Место", value: placeText)
          LabeledContent("Теги", value: tagsText)
        }
        Section(L10n.string("items.history")) {
          if history.isEmpty {
            Text(L10n.string("items.historyEmpty"))
              .foregroundColor(.secondary)
          } else {
            ForEach(history) { entry in
              ItemHistoryLine(entry: entry)
            }
          }
        }
      }
      .navigationTitle("Вещь")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Menu {
            Button(L10n.string("items.changeStatus")) {
              if let model = model.makeChangeStatusModel(for: current) {
                action = .changeStatus(model)
              }
            }
            Button(L10n.string("items.give")) {
              if let model = model.makeGiveModel(for: current) {
                action = .give(model)
              }
            }
            Button(L10n.string("items.return")) {
              if let model = model.makeReturnModel(for: current) {
                action = .returnItem(model)
              }
            }
            Divider()
            Button(L10n.string("items.edit")) {
              editing = ItemFormPresentation(mode: .edit(current))
            }
          } label: {
            Label(L10n.string("items.actions"), systemImage: "ellipsis.circle")
          }
        }
      }
      .task { await reload() }
      .sheet(item: $action, onDismiss: { Task { await reload() } }) { action in
        switch action {
        case .changeStatus(let model):
          ChangeStatusScreen(model: model, onClose: { self.action = nil })
        case .give(let model):
          GiveScreen(model: model, onClose: { self.action = nil })
        case .returnItem(let model):
          ReturnScreen(model: model, onClose: { self.action = nil })
        }
      }
      .sheet(item: $editing) { presentation in
        ItemFormSheet(
          presentation: presentation,
          makeModel: { model.makeItemFormModel(for: $0) },
          onClose: {
            editing = nil
            dismiss()
          }
        )
      }
    }
    .presentationDetents([.large])
  }

  private func reload() async {
    if let fresh = await model.loadItemDetails(current.item.id) {
      current = fresh
    }
    history = await model.loadItemHistory(current.item.id)
  }

  private var placeText: String {
    current.placePath.isEmpty ? "Без места" : current.placePath.map(\.name).joined(separator: " / ")
  }

  private var tagsText: String {
    current.tags.isEmpty ? "—" : current.tags.map(\.name).joined(separator: ", ")
  }
}

struct ItemCardPresentation: Identifiable {
  let id = UUID()
  let details: ItemDetails
}

private enum ItemAction: Identifiable {
  case changeStatus(ChangeStatusModel)
  case give(GiveModel)
  case returnItem(ReturnModel)

  var id: String {
    switch self {
    case .changeStatus: return "changeStatus"
    case .give: return "give"
    case .returnItem: return "returnItem"
    }
  }
}

private struct ItemHistoryLine: View {
  let entry: ItemHistoryEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Image(systemName: icon)
          .foregroundColor(.secondary)
          .frame(width: 18)
        Text(title)
        Spacer(minLength: 4)
        Text(
          Date(timeIntervalSince1970: Double(entry.occurredAt) / 1000).formatted(
            date: .abbreviated, time: .shortened)
        )
        .font(.caption2)
        .foregroundColor(.secondary)
      }
      if let personName = entry.personName {
        Text(personName)
          .font(.caption)
          .foregroundColor(.accentColor)
          .padding(.leading, 26)
      }
      if !entry.comment.isEmpty {
        Text(entry.comment)
          .font(.caption)
          .foregroundColor(.secondary)
          .padding(.leading, 26)
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
      return "\(entry.fromStatusName ?? "—") → \(entry.toStatusName ?? "—")"
    case .give:
      return L10n.string("items.historyGive")
    case .returnTransfer:
      return L10n.string("items.historyReturn")
    }
  }
}
