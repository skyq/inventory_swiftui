import InventoryCore
import InventoryUI
import PhotosUI
import SwiftUI

/// Создание и редактирование вещи на iPhone (IOS.05): фото из библиотеки или камеры, место, статус, теги.
struct ItemFormScreen: View {
  @ObservedObject var model: ItemFormModel
  let onClose: () -> Void

  @State private var pickerItem: PhotosPickerItem?
  @State private var showsCamera = false
  @State private var cropSource: UIImage?

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField(L10n.string("items.name"), text: $model.name)
        } header: {
          Text(L10n.string("items.name"))
        } footer: {
          Text(L10n.format("items.nameMaxLength", NameKey.maxLength))
            .foregroundStyle(model.nameIsTooLong ? .orange : .secondary)
        }

        Section(L10n.string("items.description")) {
          TextEditor(text: $model.description)
            .frame(minHeight: 80)
        }

        photoSection

        Section {
          if model.isEditing {
            LabeledContent(L10n.string("items.status"), value: model.readOnlyStatusName ?? "—")
          } else {
            Picker(L10n.string("items.status"), selection: $model.statusId) {
              Text(L10n.string("items.statusDefault")).tag(String?.none)
              ForEach(model.activeStatuses) { status in
                Text(status.name).tag(Optional(status.id))
              }
            }
          }
          Picker(L10n.string("items.place"), selection: $model.placeId) {
            Text(L10n.string("items.noPlace")).tag(String?.none)
            ForEach(model.placeChoices) { choice in
              Text(choice.path).tag(Optional(choice.id))
            }
          }
        } footer: {
          if model.isEditing {
            Text(L10n.string("items.statusReadOnly"))
          }
        }

        tagsSection
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
          Button {
            Task { await model.save() }
          } label: {
            if model.isSaving {
              ProgressView()
            } else {
              Text(L10n.string("places.save"))
            }
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
      .onChange(of: model.tagInput) { _, _ in
        Task { await model.refreshTagSuggestions() }
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
        }
      }
    }
  }

  private var photoSection: some View {
    Section {
      if let image = model.previewImage {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
          .frame(width: 220, height: 220)
          .clipShape(RoundedRectangle(cornerRadius: 10))
          .frame(maxWidth: .infinity)
      }
      let pickerTitle = L10n.string(model.hasPhoto ? "items.changePhoto" : "items.choosePhoto")
      PhotosPicker(selection: $pickerItem, matching: .images) {
        Label(pickerTitle, systemImage: "photo.on.rectangle")
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
      if model.isProcessingPhoto {
        HStack {
          ProgressView()
          Text(L10n.string("photo.processing"))
            .foregroundStyle(.secondary)
        }
      }
    } header: {
      Text(L10n.string("items.photo"))
    } footer: {
      photoFooter
    }
  }

  @ViewBuilder
  private var photoFooter: some View {
    if model.hasPhoto {
      Text(L10n.string("items.photoHint"))
    } else {
      Text(L10n.string("items.photoRequired"))
        .foregroundStyle(.orange)
    }
  }

  private var tagsSection: some View {
    Section {
      ForEach(model.selectedTags, id: \.self) { tag in
        HStack {
          Text(tag)
          Spacer()
          Button {
            model.removeTag(tag)
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.borderless)
          .accessibilityLabel(L10n.string("items.removeTag"))
        }
      }
      TextField(L10n.string("items.tagPlaceholder"), text: $model.tagInput)
        .onSubmit {
          model.addTagFromInput()
        }
      ForEach(model.tagSuggestions) { suggestion in
        Button {
          model.selectTagSuggestion(suggestion)
        } label: {
          HStack {
            Text(suggestion.name)
            Spacer()
            Text("\(suggestion.itemCount)")
              .foregroundStyle(.secondary)
          }
        }
      }
    } header: {
      Text(L10n.string("items.tags"))
    } footer: {
      Text(L10n.format("items.tagHint", TagKey.maxLength))
    }
  }
}

/// Держит одну модель формы на время показа sheet: перерисовка родителя не должна создавать новую модель и терять фото и ввод.
struct ItemFormSheet: View {
  let presentation: ItemFormPresentation
  let makeModel: (ItemFormPresentation) -> ItemFormModel?
  let onClose: () -> Void

  @State private var formModel: ItemFormModel?

  var body: some View {
    Group {
      if let formModel {
        ItemFormScreen(model: formModel, onClose: onClose)
      }
    }
    .onAppear {
      if formModel == nil {
        formModel = makeModel(presentation)
      }
    }
  }
}
