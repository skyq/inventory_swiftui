import InventoryCore
import InventoryUI
import SwiftUI

/// Создание и переименование статуса или тега на iPhone (IOS.06): одно поле названия.
struct NameFormScreen: View {
  let title: String
  let fieldTitle: String
  @Binding var alertMessage: String?
  let onSave: (String) async -> Bool
  let onClose: () -> Void

  @State private var name: String
  @State private var isSaving = false

  init(
    title: String,
    fieldTitle: String,
    initialName: String,
    alertMessage: Binding<String?>,
    onSave: @escaping (String) async -> Bool,
    onClose: @escaping () -> Void
  ) {
    self.title = title
    self.fieldTitle = fieldTitle
    _name = State(initialValue: initialName)
    _alertMessage = alertMessage
    self.onSave = onSave
    self.onClose = onClose
  }

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section(fieldTitle) {
          TextField(fieldTitle, text: $name)
        }
      }
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.string("places.cancel")) {
            onClose()
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.string("places.save")) {
            Task {
              isSaving = true
              let saved = await onSave(trimmedName)
              isSaving = false
              if saved {
                onClose()
              }
            }
          }
          .disabled(trimmedName.isEmpty || isSaving)
        }
      }
      .errorAlert($alertMessage)
    }
  }
}

extension View {
  func errorAlert(_ message: Binding<String?>) -> some View {
    alert(
      L10n.string("common.error"),
      isPresented: Binding(
        get: { message.wrappedValue != nil },
        set: { if !$0 { message.wrappedValue = nil } }
      )
    ) {
      Button(L10n.string("common.ok"), role: .cancel) { message.wrappedValue = nil }
    } message: {
      Text(message.wrappedValue ?? "")
    }
  }
}
