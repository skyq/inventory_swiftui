import InventoryCore
import InventoryUI
import SwiftUI

/// Создание и редактирование человека на iPhone (IOS.06): имя, телефон, заметка и дубликат.
struct PersonFormScreen: View {
  @ObservedObject var model: PersonFormModel
  let onClose: () -> Void

  var body: some View {
    NavigationStack {
      Form {
        Section(L10n.string("people.name")) {
          TextField(L10n.string("people.name"), text: $model.name)
          if model.nameIsTooLong {
            Text(L10n.format("people.nameMaxLength", NameKey.maxLength))
              .font(.caption)
              .foregroundColor(.orange)
          }
        }

        Section(L10n.string("people.phone")) {
          TextField(L10n.string("people.phone"), text: $model.phone)
            .keyboardType(.phonePad)
        }

        Section(L10n.string("people.notes")) {
          TextEditor(text: $model.notes)
            .frame(minHeight: 80)
        }
      }
      .navigationTitle(model.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.string("places.cancel")) {
            onClose()
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.string("places.save")) {
            Task { await model.save() }
          }
          .disabled(!model.canSave)
        }
      }
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
      .alert(
        L10n.string("common.error"),
        isPresented: Binding(
          get: { model.alertMessage != nil },
          set: { if !$0 { model.alertMessage = nil } }
        )
      ) {
        Button(L10n.string("common.ok"), role: .cancel) { model.alertMessage = nil }
      } message: {
        Text(model.alertMessage ?? "")
      }
    }
  }
}
