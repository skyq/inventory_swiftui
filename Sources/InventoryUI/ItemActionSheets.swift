#if os(macOS)
  import InventoryCore
  import SwiftUI

  /// Общий диалог смены статуса: быстрый вызов и пункт меню «Действия».
  struct ChangeStatusSheet: View {
    @ObservedObject var model: ChangeStatusModel
    let onClose: () -> Void

    var body: some View {
      VStack(spacing: 0) {
        sheetHeader(L10n.string("items.changeStatusTitle"))

        Divider()

        Form {
          Section {
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

            VStack(alignment: .leading, spacing: 4) {
              Text(L10n.string("items.comment"))
                .font(.caption)
                .foregroundColor(.secondary)
              TextEditor(text: $model.comment)
                .frame(minHeight: 60)
                .padding(4)
                .overlay {
                  RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                }
            }
          }
        }

        Divider()

        sheetFooter(
          saveTitle: L10n.string("items.changeStatusSave"),
          canSave: model.canSave,
          isSaving: model.isSaving,
          onSave: { Task { await model.save() } },
          onClose: onClose
        )
      }
      .frame(width: 460)
      .task { await model.load() }
      .onChange(of: model.didSave) { saved in
        if saved { onClose() }
      }
      .onExitCommand { onClose() }
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

  /// Передача вещи человеку. Все поля §6.6 видимы, без скрытой логики.
  struct GiveSheet: View {
    @ObservedObject var model: GiveModel
    let onClose: () -> Void

    var body: some View {
      VStack(spacing: 0) {
        sheetHeader(L10n.string("items.giveTitle"))

        Divider()

        ScrollView {
          Form {
            Section(L10n.string("items.person")) {
              Picker(L10n.string("items.person"), selection: personSelection) {
                ForEach(model.people) { person in
                  Text(person.name).tag(GivePersonSelection.existing(person.id))
                }
                Text(L10n.string("items.newPerson"))
                  .tag(GivePersonSelection.new)
              }
              .pickerStyle(.radioGroup)

              if model.isCreatingPerson {
                TextField(L10n.string("people.name"), text: $model.newPersonName)
                TextField(L10n.string("people.phone"), text: $model.newPersonPhone)
                TextField(L10n.string("people.notes"), text: $model.newPersonNotes)
              }
            }

            Section(L10n.string("items.comment")) {
              TextEditor(text: $model.comment)
                .frame(minHeight: 64)
                .padding(4)
                .overlay {
                  RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                }
              Text(L10n.string("items.partialQuantityHint"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
        }

        Divider()

        sheetFooter(
          saveTitle: L10n.string("items.giveSave"),
          canSave: model.canSave,
          isSaving: model.isSaving,
          onSave: { Task { await model.save() } },
          onClose: onClose
        )
      }
      .frame(width: 540, height: 640)
      .task { await model.load() }
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

    private var personSelection: Binding<GivePersonSelection> {
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
  }

  enum GivePersonSelection: Hashable {
    case existing(String)
    case new
  }

  /// Возврат вещи: последний получатель, место и статус по D03/D04.
  struct ReturnSheet: View {
    @ObservedObject var model: ReturnModel
    let onClose: () -> Void

    var body: some View {
      VStack(spacing: 0) {
        sheetHeader(L10n.string("items.returnTitle"))

        Divider()

        ScrollView {
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
              TextEditor(text: $model.comment)
                .frame(minHeight: 60)
                .padding(4)
                .overlay {
                  RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                }
            }

            Section(L10n.string("items.place")) {
              Picker(L10n.string("items.place"), selection: $model.placeMode) {
                Text(L10n.string("items.returnKeepPlace"))
                  .tag(ReturnPlaceMode.keep)
                Text(L10n.string("items.noPlace"))
                  .tag(ReturnPlaceMode.clear)
                Text(L10n.string("items.returnNewPlace"))
                  .tag(ReturnPlaceMode.place)
              }
              .pickerStyle(.radioGroup)

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
        }

        Divider()

        sheetFooter(
          saveTitle: L10n.string("items.returnSave"),
          canSave: model.canSave,
          isSaving: model.isSaving,
          onSave: { Task { await model.save() } },
          onClose: onClose
        )
      }
      .frame(width: 540, height: 620)
      .task { await model.load() }
      .onChange(of: model.didSave) { saved in
        if saved { onClose() }
      }
      .onExitCommand { onClose() }
      .alert(
        L10n.string("common.error"),
        isPresented: binding(for: $model.alertMessage)
      ) {
        Button(L10n.string("common.ok"), role: .cancel) { model.alertMessage = nil }
      } message: {
        Text(model.alertMessage ?? "")
      }
    }

    private func personLabel(_ person: Person) -> String {
      person.isArchived
        ? "\(person.name) (\(L10n.string("gallery.archived")))"
        : person.name
    }
  }

  // MARK: - Общие части

  func sheetHeader(_ title: String) -> some View {
    HStack {
      Text(title)
        .font(.title3)
        .fontWeight(.semibold)
      Spacer()
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 14)
  }

  @MainActor
  func sheetFooter(
    saveTitle: String,
    canSave: Bool,
    isSaving: Bool,
    onSave: @escaping () -> Void,
    onClose: @escaping () -> Void
  ) -> some View {
    HStack(spacing: 10) {
      Spacer()
      Button(L10n.string("places.cancel"), action: onClose)
        .keyboardShortcut(.cancelAction)
      Button {
        onSave()
      } label: {
        if isSaving {
          ProgressView()
            .controlSize(.small)
        } else {
          Text(saveTitle)
        }
      }
      .keyboardShortcut(.defaultAction)
      .buttonStyle(.borderedProminent)
      .disabled(!canSave || isSaving)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
  }

  func binding(for message: Binding<String?>) -> Binding<Bool> {
    Binding(
      get: { message.wrappedValue != nil },
      set: { presented in
        if !presented { message.wrappedValue = nil }
      }
    )
  }
#endif
