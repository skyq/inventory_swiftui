import InventoryCore
import SwiftUI

/// Раздел «Люди»: справочник и карточка человека с историей передач.
struct PeopleWorkspaceView: View {
  @ObservedObject var model: PeopleModel
  let onOpenItem: (String) -> Void

  @State private var form: PersonFormPresentation?
  @State private var pendingArchive: Person?

  var body: some View {
    HSplitView {
      VStack(spacing: 0) {
        header
        Divider()
        if let error = model.loadError {
          errorBanner(error)
          Divider()
        }
        list
      }
      .frame(minWidth: 240, idealWidth: 280, maxWidth: 380)

      detail
        .frame(minWidth: 360, maxWidth: .infinity)
    }
    .task { await model.start() }
    .sheet(item: $form) { presentation in
      PersonFormSheet(
        model: model.makeFormModel(for: presentation.mode),
        onClose: { form = nil }
      )
    }
    .alert(
      L10n.string("people.archiveTitle"),
      isPresented: Binding(
        get: { pendingArchive != nil },
        set: { if !$0 { pendingArchive = nil } }
      )
    ) {
      Button(L10n.string("people.archive"), role: .destructive) {
        pendingArchive = nil
        Task { await model.archiveSelected() }
      }
      Button(L10n.string("places.cancel"), role: .cancel) {
        pendingArchive = nil
      }
    } message: {
      Text(L10n.string("people.archiveMessage"))
    }
    .alert(
      L10n.string("common.error"),
      isPresented: binding(for: $model.alertMessage)
    ) {
      Button(L10n.string("common.ok"), role: .cancel) { model.alertMessage = nil }
    } message: {
      Text(model.alertMessage ?? "")
    }
  }

  private var header: some View {
    HStack(spacing: 10) {
      Text(L10n.format("people.count", model.people.count))
        .font(.callout)
        .foregroundColor(.secondary)
      Spacer()
      Toggle(L10n.string("people.showArchived"), isOn: $model.includeArchived)
        .toggleStyle(.checkbox)
        .controlSize(.small)
      Button {
        form = PersonFormPresentation(mode: .create)
      } label: {
        Label(L10n.string("people.add"), systemImage: "plus")
      }
      .buttonStyle(.bordered)
      .help(L10n.string("people.add"))
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  private var list: some View {
    List(selection: $model.selectedPersonId) {
      ForEach(model.people) { person in
        HStack(spacing: 6) {
          Text(person.name)
          Spacer(minLength: 6)
          if person.isArchived {
            Text(L10n.string("gallery.archived"))
              .font(.caption2)
              .foregroundColor(.secondary)
          }
        }
        .tag(person.id)
        .contextMenu {
          Button(L10n.string("people.edit")) {
            form = PersonFormPresentation(mode: .edit(person))
          }
          if person.isArchived {
            Button(L10n.string("people.restore")) {
              Task {
                await model.select(person.id)
                await model.restoreSelected()
              }
            }
          } else {
            Button(L10n.string("people.archive")) {
              Task {
                await model.select(person.id)
                pendingArchive = person
              }
            }
          }
        }
      }
    }
    .listStyle(.inset)
  }

  @ViewBuilder
  private var detail: some View {
    if let person = model.selectedPerson {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          HStack(alignment: .firstTextBaseline) {
            Text(person.name)
              .font(.title3)
              .fontWeight(.semibold)
              .textSelection(.enabled)
            if person.isArchived {
              Text(L10n.string("gallery.archived"))
                .font(.caption)
                .foregroundColor(.secondary)
            }
          }

          if !person.phone.isEmpty {
            detailRow(L10n.string("people.phone"), person.phone)
          }
          if !person.notes.isEmpty {
            detailRow(L10n.string("people.notes"), person.notes)
          }

          HStack(spacing: 8) {
            Button(L10n.string("people.edit")) {
              form = PersonFormPresentation(mode: .edit(person))
            }
            if person.isArchived {
              Button(L10n.string("people.restore")) {
                Task { await model.restoreSelected() }
              }
            } else {
              Button(L10n.string("people.archive")) {
                pendingArchive = person
              }
            }
          }
          .buttonStyle(.bordered)

          Divider()

          VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("people.history"))
              .font(.headline)
            if model.selectedHistory.isEmpty {
              Text(L10n.string("people.historyEmpty"))
                .font(.callout)
                .foregroundColor(.secondary)
            } else {
              VStack(alignment: .leading, spacing: 10) {
                ForEach(model.selectedHistory) { entry in
                  PersonHistoryRow(entry: entry, onOpenItem: onOpenItem)
                }
              }
            }
          }
        }
        .padding(18)
      }
    } else {
      VStack(spacing: 10) {
        Image(systemName: "person.2")
          .font(.system(size: 36))
          .foregroundColor(.secondary)
        Text(L10n.string("people.selectHint"))
          .foregroundColor(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func detailRow(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.caption)
        .foregroundColor(.secondary)
      Text(value)
        .font(.callout)
        .textSelection(.enabled)
    }
  }

  private func errorBanner(_ error: AppException) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundColor(.orange)
      Text(ErrorPresenter.message(for: error))
        .font(.callout)
      Spacer()
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(Color(nsColor: .controlBackgroundColor))
  }
}

/// Форма человека: имя, телефон, заметка и подтверждение дубля.
struct PersonFormSheet: View {
  @ObservedObject var model: PersonFormModel
  let onClose: () -> Void

  @FocusState private var nameFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      sheetHeader(model.title)
      Divider()
      Form {
        TextField(L10n.string("people.name"), text: $model.name)
          .focused($nameFocused)
        TextField(L10n.string("people.phone"), text: $model.phone)
        VStack(alignment: .leading, spacing: 4) {
          Text(L10n.string("people.notes"))
            .font(.caption)
            .foregroundColor(.secondary)
          TextEditor(text: $model.notes)
            .frame(minHeight: 60)
            .padding(4)
            .overlay {
              RoundedRectangle(cornerRadius: 5)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
        }
        if model.nameIsTooLong {
          Text(L10n.format("people.nameMaxLength", NameKey.maxLength))
            .font(.caption)
            .foregroundColor(.orange)
        }
      }
      Divider()
      sheetFooter(
        saveTitle: L10n.string("places.save"),
        canSave: model.canSave,
        isSaving: model.isSaving,
        onSave: { Task { await model.save() } },
        onClose: onClose
      )
    }
    .frame(width: 460)
    .task { nameFocused = true }
    .onChange(of: model.didSave) { saved in
      if saved { onClose() }
    }
    .onExitCommand { onClose() }
    .alert(
      L10n.string("people.duplicateTitle"),
      isPresented: $model.pendingDuplicate
    ) {
      Button(L10n.string("people.duplicateConfirm")) {
        Task { await model.saveDuplicate() }
      }
      Button(L10n.string("places.cancel"), role: .cancel) {
        model.pendingDuplicate = false
      }
    } message: {
      Text(L10n.string("people.duplicateMessage"))
    }
    .alert(
      L10n.string("common.error"),
      isPresented: binding(for: $model.alertMessage)
    ) {
      Button(L10n.string("common.ok"), role: .cancel) { model.alertMessage = nil }
    } message: {
      Text(model.alertMessage ?? "")
    }
  }
}
