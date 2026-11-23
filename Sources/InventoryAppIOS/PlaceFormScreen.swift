import InventoryCore
import InventoryUI
import PhotosUI
import SwiftUI

/// Создание и редактирование места на iPhone (IOS.06): название, описание, родитель и фото.
struct PlaceFormScreen: View {
  @ObservedObject var model: PlaceFormModel
  let onClose: () -> Void

  @State private var pickerItem: PhotosPickerItem?
  @State private var showsCamera = false
  @State private var cropSource: UIImage?

  var body: some View {
    NavigationStack {
      Form {
        Section(L10n.string("places.name")) {
          TextField(L10n.string("places.name"), text: $model.name)
        }

        Section(L10n.string("places.description")) {
          TextEditor(text: $model.description)
            .frame(minHeight: 80)
        }

        Section {
          Picker(L10n.string("places.parent"), selection: $model.parentId) {
            Text(L10n.string("places.noParent")).tag(String?.none)
            ForEach(model.parentChoices) { choice in
              Text(choice.path).tag(Optional(choice.id))
            }
          }
        }

        Section {
          if let image = model.previewImage {
            Image(uiImage: image)
              .resizable()
              .scaledToFill()
              .frame(width: 220, height: 220)
              .clipShape(RoundedRectangle(cornerRadius: 10))
              .frame(maxWidth: .infinity)
          }
          if model.isProcessingPhoto {
            ProgressView()
          }
          PhotosPicker(selection: $pickerItem, matching: .images) {
            Label(L10n.string("places.choosePhoto"), systemImage: "photo.on.rectangle")
          }
          .disabled(model.isProcessingPhoto)
          if UIImagePickerController.isSourceTypeAvailable(.camera) {
            Button {
              showsCamera = true
            } label: {
              Label("Снять фото", systemImage: "camera")
            }
            .disabled(model.isProcessingPhoto)
          }
        } header: {
          Text(L10n.string("places.photo"))
        } footer: {
          Text(
            model.hasPhoto
              ? L10n.string("places.photoHint") : L10n.string("places.photoRequired"))
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
      .task {
        await model.loadReferences()
      }
      .onChange(of: model.didSave) { _, saved in
        if saved {
          onClose()
        }
      }
      .onChange(of: pickerItem) { _, item in
        guard let item else { return }
        Task {
          if let data = try? await item.loadTransferable(type: Data.self),
            let image = UIImage(data: data)
          {
            cropSource = image.normalizedForCrop()
          }
          pickerItem = nil
        }
      }
      .fullScreenCover(isPresented: $showsCamera) {
        CameraPicker { data in
          showsCamera = false
          guard let data else { return }
          Task { await model.setPhoto(data: data, sourceName: "camera.jpg") }
        }
        .ignoresSafeArea()
      }
      .fullScreenCover(
        isPresented: Binding(
          get: { cropSource != nil },
          set: { if !$0 { cropSource = nil } }
        )
      ) {
        if let image = cropSource {
          SquareCropView(
            image: image,
            onCancel: { cropSource = nil },
            onDone: { data in
              cropSource = nil
              Task { await model.setPhoto(data: data, sourceName: "library.jpg") }
            }
          )
        }
      }
      .alert(item: $model.alert) { alert in
        switch alert {
        case .failure(let message):
          return Alert(
            title: Text(L10n.string("common.error")),
            message: Text(message),
            dismissButton: .default(Text(L10n.string("common.ok")))
          )
        case .duplicate(let name):
          return Alert(
            title: Text(L10n.string("places.duplicateTitle")),
            message: Text(L10n.format("places.duplicateMessage", name)),
            primaryButton: .default(Text(L10n.string("places.duplicateConfirm"))) {
              Task { await model.save(duplicateConfirmed: true) }
            },
            secondaryButton: .cancel(Text(L10n.string("places.cancel")))
          )
        }
      }
    }
  }
}
