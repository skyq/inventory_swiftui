import InventoryCore
import SwiftUI

struct PlaceFormView: View {
  @ObservedObject var model: PlaceFormModel
  let onClose: () -> Void

  @FocusState private var nameFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(model.title)
          .font(.title3)
          .fontWeight(.semibold)
        Spacer()
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 14)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          field(
            title: L10n.string("places.name"),
            hint: L10n.format("places.nameMaxLength", NameKey.maxLength)
          ) {
            TextField(L10n.string("places.name"), text: $model.name)
              .textFieldStyle(.roundedBorder)
              .focused($nameFocused)
              .onSubmit {
                Task { await model.save() }
              }
          }

          field(title: L10n.string("places.description"), hint: nil) {
            TextEditor(text: $model.description)
              .font(.body)
              .frame(minHeight: 74, maxHeight: 110)
              .padding(4)
              .overlay {
                RoundedRectangle(cornerRadius: 5)
                  .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
              }
          }

          photoSection

          field(title: L10n.string("places.parent"), hint: nil) {
            Picker("", selection: $model.parentId) {
              Text(L10n.string("places.noParent")).tag(String?.none)
              ForEach(model.parentChoices) { choice in
                Text(choice.path).tag(Optional(choice.id))
              }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 420, alignment: .leading)
          }
        }
        .padding(20)
      }

      Divider()

      HStack(spacing: 10) {
        if model.isProcessingPhoto {
          ProgressView()
            .controlSize(.small)
          Text(L10n.string("photo.processing"))
            .font(.callout)
            .foregroundColor(.secondary)
        }
        Spacer()
        Button(L10n.string("places.cancel")) {
          onClose()
        }
        .keyboardShortcut(.cancelAction)

        Button {
          Task { await model.save() }
        } label: {
          if model.isSaving {
            ProgressView()
              .controlSize(.small)
          } else {
            Text(L10n.string("places.save"))
          }
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(!model.canSave)
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 12)
    }
    .frame(minWidth: 520, idealWidth: 560, minHeight: 500, idealHeight: 560)
    .task {
      await model.loadReferences()
      nameFocused = true
    }
    .onChange(of: model.didSave) { saved in
      if saved {
        onClose()
      }
    }
    .onExitCommand {
      onClose()
    }
    .alert(item: $model.alert) { alert in
      switch alert {
      case .duplicate(let name):
        return Alert(
          title: Text(L10n.string("places.duplicateTitle")),
          message: Text(L10n.format("places.duplicateMessage", name)),
          primaryButton: .default(Text(L10n.string("places.duplicateConfirm"))) {
            Task { await model.save(duplicateConfirmed: true) }
          },
          secondaryButton: .cancel(Text(L10n.string("places.cancel")))
        )
      case .failure(let message):
        return Alert(
          title: Text(L10n.string("common.error")),
          message: Text(message),
          dismissButton: .default(Text(L10n.string("common.ok")))
        )
      }
    }
  }

  private var photoSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(L10n.string("places.photo"))
        .font(.headline)
      HStack(alignment: .top, spacing: 16) {
        ZStack {
          RoundedRectangle(cornerRadius: 6)
            .fill(Color(nsColor: .quaternaryLabelColor))
          if let image = model.previewImage {
            Image(nsImage: image)
              .resizable()
              .aspectRatio(contentMode: .fill)
          } else {
            Image(systemName: "photo")
              .font(.system(size: 28))
              .foregroundColor(.secondary)
          }
          if model.isProcessingPhoto {
            Color(nsColor: .windowBackgroundColor)
              .opacity(0.65)
            ProgressView()
              .controlSize(.small)
          }
        }
        .frame(width: 150, height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 6))

        VStack(alignment: .leading, spacing: 8) {
          Button {
            Task { await model.choosePhoto() }
          } label: {
            Text(
              L10n.string(model.hasPhoto ? "places.changePhoto" : "places.choosePhoto")
            )
          }
          .disabled(model.isProcessingPhoto)

          Text(L10n.string("places.photoHint"))
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

          if !model.hasPhoto {
            Text(L10n.string("places.photoRequired"))
              .font(.caption)
              .foregroundColor(.orange)
          }
        }
        Spacer(minLength: 0)
      }
    }
  }

  private func field<Content: View>(
    title: String,
    hint: String?,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.headline)
      content()
      if let hint {
        Text(hint)
          .font(.caption)
          .foregroundColor(
            model.nameIsTooLong && title == L10n.string("places.name") ? .orange : .secondary)
      }
    }
  }
}
