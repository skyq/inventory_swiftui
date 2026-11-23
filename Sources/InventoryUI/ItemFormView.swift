import InventoryCore
import SwiftUI

struct ItemFormView: View {
  @ObservedObject var model: ItemFormModel
  let onClose: () -> Void

  @FocusState private var nameFocused: Bool
  @State private var isDropTargeted = false

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
            title: L10n.string("items.name"),
            hint: L10n.format("items.nameMaxLength", NameKey.maxLength)
          ) {
            TextField(L10n.string("items.name"), text: $model.name)
              .textFieldStyle(.roundedBorder)
              .focused($nameFocused)
              .onSubmit {
                Task { await model.save() }
              }
          }

          field(title: L10n.string("items.description"), hint: nil) {
            TextEditor(text: $model.description)
              .font(.body)
              .frame(minHeight: 64, maxHeight: 100)
              .padding(4)
              .overlay {
                RoundedRectangle(cornerRadius: 5)
                  .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
              }
          }

          photoSection

          HStack(alignment: .top, spacing: 16) {
            statusSection
              .frame(maxWidth: .infinity, alignment: .leading)
            placeSection
              .frame(maxWidth: .infinity, alignment: .leading)
          }

          tagsSection
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
    .frame(minWidth: 620, idealWidth: 680, minHeight: 620, idealHeight: 700)
    .task {
      await model.loadReferences()
      nameFocused = true
    }
    .onChange(of: model.didSave) { saved in
      if saved {
        onClose()
      }
    }
    .onChange(of: model.tagInput) { _ in
      Task { await model.refreshTagSuggestions() }
    }
    .onExitCommand {
      onClose()
    }
    .onPasteCommand(of: PhotoDrop.acceptedTypes) { _ in
      Task { await model.pastePhoto() }
    }
    .onDrop(of: PhotoDrop.acceptedTypes, isTargeted: nil) { providers in
      Task { _ = await model.acceptDrop(providers: providers) }
      return true
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

  private var photoSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(L10n.string("items.photo"))
        .font(.headline)
      HStack(alignment: .top, spacing: 16) {
        ZStack {
          RoundedRectangle(cornerRadius: 6)
            .fill(Color(nsColor: .quaternaryLabelColor))
          if let image = model.previewImage {
            Image(nsImage: image)
              .resizable()
              .aspectRatio(contentMode: .fit)
              .padding(2)
          } else {
            Image(systemName: "photo")
              .font(.system(size: 28))
              .foregroundColor(.secondary)
          }
          if isDropTargeted {
            RoundedRectangle(cornerRadius: 6)
              .strokeBorder(Color.accentColor, lineWidth: 2)
            Text(L10n.string("items.drop"))
              .font(.callout)
              .padding(6)
              .background(Color(nsColor: .windowBackgroundColor).opacity(0.9))
              .cornerRadius(5)
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
        .onDrop(of: PhotoDrop.acceptedTypes, isTargeted: $isDropTargeted) { providers in
          Task { _ = await model.acceptDrop(providers: providers) }
          return true
        }

        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 8) {
            Button {
              Task { await model.choosePhoto() }
            } label: {
              Text(L10n.string(model.hasPhoto ? "items.changePhoto" : "items.choosePhoto"))
            }
            .disabled(model.isProcessingPhoto)

            Button {
              Task { await model.pastePhoto() }
            } label: {
              Text(L10n.string("items.paste"))
            }
            .disabled(model.isProcessingPhoto)
          }

          Text(L10n.string("items.photoHint"))
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

          Text(L10n.string("items.dropHint"))
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

          if !model.hasPhoto {
            Text(L10n.string("items.photoRequired"))
              .font(.caption)
              .foregroundColor(.orange)
          }
        }
        Spacer(minLength: 0)
      }
    }
  }

  @ViewBuilder
  private var statusSection: some View {
    field(title: L10n.string("items.status"), hint: nil) {
      if model.isEditing {
        VStack(alignment: .leading, spacing: 3) {
          Text(model.readOnlyStatusName ?? "—")
            .frame(maxWidth: 220, alignment: .leading)
          Text(L10n.string("items.statusReadOnly"))
            .font(.caption)
            .foregroundColor(.secondary)
        }
      } else {
        Picker("", selection: $model.statusId) {
          Text(L10n.string("items.statusDefault")).tag(String?.none)
          ForEach(model.activeStatuses) { status in
            Text(status.name).tag(Optional(status.id))
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: 220, alignment: .leading)
      }
    }
  }

  private var placeSection: some View {
    field(title: L10n.string("items.place"), hint: nil) {
      Picker("", selection: $model.placeId) {
        Text(L10n.string("items.noPlace")).tag(String?.none)
        ForEach(model.placeChoices) { choice in
          Text(choice.path).tag(Optional(choice.id))
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var tagsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(L10n.string("items.tags"))
        .font(.headline)

      if !model.selectedTags.isEmpty {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 90), spacing: 6)],
          alignment: .leading,
          spacing: 6
        ) {
          ForEach(model.selectedTags, id: \.self) { tag in
            HStack(spacing: 4) {
              Text(tag)
                .font(.callout)
                .lineLimit(1)
              Button {
                model.removeTag(tag)
              } label: {
                Image(systemName: "xmark.circle.fill")
                  .foregroundColor(.secondary)
              }
              .buttonStyle(.plain)
              .help(L10n.string("items.removeTag"))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
              RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .quaternaryLabelColor))
            )
          }
        }
      }

      TextField(L10n.string("items.tagPlaceholder"), text: $model.tagInput)
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 320)
        .onSubmit {
          model.addTagFromInput()
        }

      if !model.tagSuggestions.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(model.tagSuggestions) { suggestion in
            Button {
              model.selectTagSuggestion(suggestion)
            } label: {
              HStack {
                Text(suggestion.name)
                Spacer(minLength: 12)
                Text("\(suggestion.itemCount)")
                  .foregroundColor(.secondary)
              }
              .contentShape(Rectangle())
              .padding(.vertical, 4)
              .padding(.horizontal, 6)
            }
            .buttonStyle(.plain)
          }
        }
        .frame(maxWidth: 320, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 5)
            .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
          RoundedRectangle(cornerRadius: 5)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
      }

      Text(L10n.format("items.tagHint", TagKey.maxLength))
        .font(.caption)
        .foregroundColor(.secondary)
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
            model.nameIsTooLong && title == L10n.string("items.name") ? .orange : .secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
