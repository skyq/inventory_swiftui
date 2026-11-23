import InventoryCore
import InventoryUI
import SwiftUI

/// Смена статуса вещи на iPhone (IOS.06).
struct ChangeStatusScreen: View {
  @ObservedObject var model: ChangeStatusModel
  let onClose: () -> Void

  var body: some View {
    NavigationStack {
      Form {
        Section(L10n.string("items.status")) {
          Picker(L10n.string("items.status"), selection: $model.statusId) {
            ForEach(model.statuses) { status in
              Text(status.name).tag(Optional(status.id))
            }
          }
          if model.statuses.isEmpty && !model.isLoading {
            Text(L10n.string("items.changeStatusNoOptions"))
              .font(.caption)
              .foregroundColor(.secondary)
          }
        }
        Section(L10n.string("items.comment")) {
          TextField(L10n.string("items.comment"), text: $model.comment, axis: .vertical)
            .lineLimit(3...6)
        }
      }
      .navigationTitle(L10n.string("items.changeStatusTitle"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.string("places.cancel")) {
            onClose()
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.string("items.changeStatusSave")) {
            Task { await model.save() }
          }
          .disabled(!model.canSave)
        }
      }
      .task { await model.load() }
      .onChange(of: model.didSave) { _, saved in
        if saved {
          onClose()
        }
      }
      .errorAlert($model.alertMessage)
    }
  }
}

/// Передача вещи человеку на iPhone (IOS.06): существующий человек или новый, статус и место.
struct GiveScreen: View {
  @ObservedObject var model: GiveModel
  let onClose: () -> Void

  var body: some View {
    NavigationStack {
      Form {
        Section(L10n.string("items.person")) {
          Picker(L10n.string("items.person"), selection: personSelection) {
            ForEach(model.people) { person in
              Text(personLabel(person)).tag(GivePersonChoice.existing(person.id))
            }
            Text(L10n.string("items.newPerson"))
              .tag(GivePersonChoice.new)
          }
          if model.isCreatingPerson {
            TextField(L10n.string("people.name"), text: $model.newPersonName)
            TextField(L10n.string("people.phone"), text: $model.newPersonPhone)
              .keyboardType(.phonePad)
            TextField(L10n.string("people.notes"), text: $model.newPersonNotes, axis: .vertical)
          }
        }

        Section {
          TextField(L10n.string("items.comment"), text: $model.comment, axis: .vertical)
            .lineLimit(3...6)
        } header: {
          Text(L10n.string("items.comment"))
        } footer: {
          Text(L10n.string("items.partialQuantityHint"))
        }

        Section {
          Toggle(L10n.string("items.changeStatusToggle"), isOn: $model.changeStatus)
          if model.changeStatus {
            Picker(L10n.string("items.status"), selection: $model.statusId) {
              ForEach(model.statuses) { status in
                Text(status.name).tag(Optional(status.id))
              }
            }
            if model.statusIsCurrent {
              Text(L10n.string("items.sameStatusHint"))
                .font(.caption)
                .foregroundColor(.secondary)
            }
          }
          Toggle(L10n.string("items.clearPlace"), isOn: $model.clearPlace)
        }
      }
      .navigationTitle(L10n.string("items.giveTitle"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.string("places.cancel")) {
            onClose()
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.string("items.giveSave")) {
            Task { await model.save() }
          }
          .disabled(!model.canSave)
        }
      }
      .task { await model.load() }
      .onChange(of: model.didSave) { _, saved in
        if saved {
          onClose()
        }
      }
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
      .errorAlert($model.alertMessage)
    }
  }

  private var personSelection: Binding<GivePersonChoice> {
    Binding(
      get: {
        if model.isCreatingPerson { return .new }
        guard let id = model.selectedPersonId else { return .new }
        return .existing(id)
      },
      set: { value in
        switch value {
        case .new:
          model.isCreatingPerson = true
          model.selectedPersonId = nil
        case .existing(let id):
          model.isCreatingPerson = false
          model.selectedPersonId = id
        }
      }
    )
  }

  private func personLabel(_ person: Person) -> String {
    person.isArchived
      ? "\(person.name) (\(L10n.string("gallery.archived")))"
      : person.name
  }
}

private enum GivePersonChoice: Hashable {
  case existing(String)
  case new
}

/// Возврат вещи на iPhone (IOS.06): последний получатель, место и статус по D03/D04.
struct ReturnScreen: View {
  @ObservedObject var model: ReturnModel
  let onClose: () -> Void

  var body: some View {
    NavigationStack {
      Form {
        Section(L10n.string("items.person")) {
          Picker(L10n.string("items.person"), selection: $model.selectedPersonId) {
            Text(L10n.string("items.personNotChosen")).tag(String?.none)
            ForEach(model.people) { person in
              Text(personLabel(person)).tag(Optional(person.id))
            }
          }
        }

        Section(L10n.string("items.comment")) {
          TextField(L10n.string("items.comment"), text: $model.comment, axis: .vertical)
            .lineLimit(3...6)
        }

        Section(L10n.string("items.place")) {
          Picker(L10n.string("items.place"), selection: $model.placeMode) {
            Text(L10n.string("items.returnKeepPlace")).tag(ReturnPlaceMode.keep)
            Text(L10n.string("items.noPlace")).tag(ReturnPlaceMode.clear)
            Text(L10n.string("items.returnNewPlace")).tag(ReturnPlaceMode.place)
          }
          if model.placeMode == .place {
            Picker(L10n.string("items.place"), selection: $model.placeId) {
              Text(L10n.string("items.personNotChosen")).tag(String?.none)
              ForEach(model.placeChoices) { choice in
                Text(choice.path).tag(Optional(choice.id))
              }
            }
          }
        }

        Section(L10n.string("items.status")) {
          Picker(L10n.string("items.status"), selection: $model.statusId) {
            Text(L10n.string("items.returnKeepStatus")).tag(String?.none)
            ForEach(model.statuses) { status in
              Text(status.name).tag(Optional(status.id))
            }
          }
        }
      }
      .navigationTitle(L10n.string("items.returnTitle"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.string("places.cancel")) {
            onClose()
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.string("items.returnSave")) {
            Task { await model.save() }
          }
          .disabled(!model.canSave)
        }
      }
      .task { await model.load() }
      .onChange(of: model.didSave) { _, saved in
        if saved {
          onClose()
        }
      }
      .errorAlert($model.alertMessage)
    }
  }

  private func personLabel(_ person: Person) -> String {
    person.isArchived
      ? "\(person.name) (\(L10n.string("gallery.archived")))"
      : person.name
  }
}
