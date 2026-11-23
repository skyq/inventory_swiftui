import InventoryCore
import InventoryUI
import SwiftUI

/// Раздел «Люди» на iPhone (IOS.06): справочник, карточка человека и история передач.
struct PeopleScreen: View {
  @ObservedObject var model: AppModel

  var body: some View {
    NavigationStack {
      Group {
        if let people = model.peopleModel {
          PeopleContent(people: people, model: model)
        }
      }
      .navigationTitle(L10n.string("people.title"))
    }
  }
}

private struct PeopleContent: View {
  @ObservedObject var people: PeopleModel
  let model: AppModel
  @State private var form: PersonFormPresentation?
  @State private var showsDetail = false

  var body: some View {
    List {
      ForEach(people.people) { person in
        Button {
          showsDetail = true
          Task { await people.select(person.id) }
        } label: {
          HStack(spacing: 6) {
            Text(person.name)
              .foregroundColor(.primary)
            Spacer(minLength: 6)
            if person.isArchived {
              Text(L10n.string("gallery.archived"))
                .font(.caption)
                .foregroundColor(.secondary)
            }
          }
        }
      }
    }
    .overlay {
      if people.people.isEmpty {
        Text(L10n.string("people.empty"))
          .foregroundColor(.secondary)
      }
    }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          form = PersonFormPresentation(mode: .create)
        } label: {
          Label(L10n.string("people.add"), systemImage: "plus")
        }
      }
      ToolbarItem(placement: .topBarLeading) {
        Menu {
          Toggle(L10n.string("people.showArchived"), isOn: $people.includeArchived)
        } label: {
          Label(
            L10n.string("people.showArchived"),
            systemImage: people.includeArchived
              ? "archivebox.fill" : "archivebox"
          )
        }
      }
    }
    .navigationDestination(isPresented: $showsDetail) {
      PersonDetailView(people: people, model: model)
    }
    .sheet(item: $form) { presentation in
      PersonFormScreen(
        model: people.makeFormModel(for: presentation.mode),
        onClose: { form = nil }
      )
    }
    .task { await people.start() }
  }
}

private struct PersonDetailView: View {
  @ObservedObject var people: PeopleModel
  let model: AppModel
  @State private var form: PersonFormPresentation?
  @State private var showsArchiveConfirm = false
  @State private var openedItem: ItemDetails?

  var body: some View {
    Group {
      if let person = people.selectedPerson {
        List {
          Section {
            Text(person.name)
              .font(.title3.weight(.semibold))
            if !person.phone.isEmpty {
              LabeledContent(L10n.string("people.phone"), value: person.phone)
            }
            if !person.notes.isEmpty {
              Text(person.notes)
                .font(.callout)
                .foregroundColor(.secondary)
            }
          }

          Section {
            Button(L10n.string("people.edit")) {
              form = PersonFormPresentation(mode: .edit(person))
            }
            if person.isArchived {
              Button(L10n.string("people.restore")) {
                Task { await people.restoreSelected() }
              }
            } else {
              Button(L10n.string("people.archive"), role: .destructive) {
                showsArchiveConfirm = true
              }
            }
          }

          Section(L10n.string("people.history")) {
            if people.selectedHistory.isEmpty {
              Text(L10n.string("people.historyEmpty"))
                .foregroundColor(.secondary)
            } else {
              ForEach(people.selectedHistory) { entry in
                Button {
                  Task { openedItem = await model.loadItemDetails(entry.itemId) }
                } label: {
                  PersonHistoryLine(entry: entry)
                }
                .buttonStyle(.plain)
              }
            }
          }
        }
        .navigationTitle(person.name)
        .navigationBarTitleDisplayMode(.inline)
      } else {
        ProgressView()
      }
    }
    .sheet(item: $form) { presentation in
      PersonFormScreen(
        model: people.makeFormModel(for: presentation.mode),
        onClose: { form = nil }
      )
    }
    .sheet(
      isPresented: Binding(
        get: { openedItem != nil },
        set: { if !$0 { openedItem = nil } }
      )
    ) {
      if let details = openedItem {
        ItemCardView(
          details: details,
          url: model.gallery?.photoURL(for: details),
          model: model
        )
      }
    }
    .alert(
      L10n.string("people.archiveTitle"),
      isPresented: $showsArchiveConfirm
    ) {
      Button(L10n.string("people.archive"), role: .destructive) {
        Task { await people.archiveSelected() }
      }
      Button(L10n.string("places.cancel"), role: .cancel) {}
    } message: {
      Text(L10n.string("people.archiveMessage"))
    }
    .alert(
      L10n.string("common.error"),
      isPresented: Binding(
        get: { people.alertMessage != nil },
        set: { if !$0 { people.alertMessage = nil } }
      )
    ) {
      Button(L10n.string("common.ok"), role: .cancel) { people.alertMessage = nil }
    } message: {
      Text(people.alertMessage ?? "")
    }
  }
}

private struct PersonHistoryLine: View {
  let entry: PersonHistoryEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Image(systemName: entry.kind == .give ? "arrow.up.right" : "arrow.down.left")
          .foregroundColor(.secondary)
          .frame(width: 18)
        Text(
          entry.kind == .give
            ? L10n.string("items.historyGive") : L10n.string("items.historyReturn"))
        Spacer(minLength: 4)
        Text(
          Date(timeIntervalSince1970: Double(entry.occurredAt) / 1000).formatted(
            date: .abbreviated, time: .shortened)
        )
        .font(.caption2)
        .foregroundColor(.secondary)
      }
      Text(entry.itemName)
        .font(.caption)
        .foregroundColor(.accentColor)
        .padding(.leading, 26)
      if !entry.comment.isEmpty {
        Text(entry.comment)
          .font(.caption)
          .foregroundColor(.secondary)
          .padding(.leading, 26)
      }
    }
  }
}
