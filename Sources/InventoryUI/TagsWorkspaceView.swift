import InventoryCore
import SwiftUI

/// Раздел «Теги»: количества, переименование с объединением и удаление.
struct TagsWorkspaceView: View {
  @ObservedObject var model: TagsModel

  @State private var newName = ""
  @State private var mergeTargetId: String?
  @State private var mergeResultName = ""
  @State private var pendingDelete: TagSuggestion?

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
      .frame(minWidth: 240, idealWidth: 300, maxWidth: 380)

      detail
        .frame(minWidth: 360, maxWidth: .infinity)
    }
    .task { await model.start() }
    .onChange(of: model.selectedTagId) { _ in
      newName = model.selectedTag?.name ?? ""
      mergeTargetId = model.tags.first { $0.id != model.selectedTagId }?.id
      mergeResultName = ""
    }
    .alert(
      L10n.string("tags.renameMergeTitle"),
      isPresented: Binding(
        get: { model.renameSuggestion != nil },
        set: { if !$0 { model.renameSuggestion = nil } }
      )
    ) {
      Button(L10n.string("tags.mergeConfirm")) {
        Task { await model.confirmRenameMerge() }
      }
      Button(L10n.string("places.cancel"), role: .cancel) {
        model.renameSuggestion = nil
      }
    } message: {
      if let suggestion = model.renameSuggestion {
        Text(
          L10n.format(
            "tags.renameMergeMessage",
            suggestion.sourceName,
            suggestion.targetName
          )
        )
      }
    }
    .alert(
      L10n.string("tags.deleteTitle"),
      isPresented: Binding(
        get: { pendingDelete != nil },
        set: { if !$0 { pendingDelete = nil } }
      )
    ) {
      Button(L10n.string("tags.delete"), role: .destructive) {
        guard let tag = pendingDelete else { return }
        pendingDelete = nil
        Task { _ = await model.delete(tag.id) }
      }
      Button(L10n.string("places.cancel"), role: .cancel) {
        pendingDelete = nil
      }
    } message: {
      if let tag = pendingDelete {
        Text(L10n.format("tags.deleteMessage", tag.name, tag.itemCount))
      }
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
      Text(L10n.format("tags.count", model.tags.count))
        .font(.callout)
        .foregroundColor(.secondary)
      Spacer()
      Menu {
        Button {
          model.sortMode = .name
        } label: {
          if model.sortMode == .name {
            Label(L10n.string("tags.sort.name"), systemImage: "checkmark")
          } else {
            Text(L10n.string("tags.sort.name"))
          }
        }
        Button {
          model.sortMode = .count
        } label: {
          if model.sortMode == .count {
            Label(L10n.string("tags.sort.count"), systemImage: "checkmark")
          } else {
            Text(L10n.string("tags.sort.count"))
          }
        }
      } label: {
        Image(systemName: "arrow.up.arrow.down")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help(L10n.string("tags.sort"))
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  private var list: some View {
    List(selection: $model.selectedTagId) {
      ForEach(model.sortedTags) { tag in
        HStack(spacing: 8) {
          Text(tag.name)
          Spacer(minLength: 6)
          Text("\(tag.itemCount)")
            .font(.caption)
            .foregroundColor(.secondary)
            .monospacedDigit()
        }
        .tag(tag.id)
        .contextMenu {
          Button(L10n.string("tags.delete")) { pendingDelete = tag }
        }
      }
    }
    .listStyle(.inset)
  }

  @ViewBuilder
  private var detail: some View {
    if let tag = model.selectedTag {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          VStack(alignment: .leading, spacing: 4) {
            Text(tag.name)
              .font(.title3)
              .fontWeight(.semibold)
            Text(L10n.format("tags.itemCount", tag.itemCount))
              .font(.caption)
              .foregroundColor(.secondary)
          }

          VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string("tags.rename"))
              .font(.headline)
            HStack(spacing: 8) {
              TextField(L10n.string("tags.name"), text: $newName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
                .onSubmit { Task { await rename(tag) } }
              Button(L10n.string("tags.rename")) {
                Task { await rename(tag) }
              }
              .disabled(!canRename(tag))
            }
            Text(L10n.format("tags.nameMaxLength", TagKey.maxLength))
              .font(.caption)
              .foregroundColor(.secondary)
            Text(L10n.string("tags.renameHint"))
              .font(.caption)
              .foregroundColor(.secondary)
          }

          Divider()

          VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string("tags.merge"))
              .font(.headline)
            Text(L10n.string("tags.mergeHint"))
              .font(.caption)
              .foregroundColor(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            Picker(L10n.string("tags.mergeTarget"), selection: $mergeTargetId) {
              Text(L10n.string("tags.mergeTargetNone")).tag(String?.none)
              ForEach(model.sortedTags.filter { $0.id != tag.id }) { candidate in
                Text(candidate.name).tag(Optional(candidate.id))
              }
            }
            .frame(maxWidth: 320)
            TextField(L10n.string("tags.mergeResultName"), text: $mergeResultName)
              .textFieldStyle(.roundedBorder)
              .frame(maxWidth: 280)
            Button(L10n.string("tags.merge")) {
              guard let mergeTargetId else { return }
              let result = mergeResultName.trimmingCharacters(in: .whitespacesAndNewlines)
              Task {
                _ = await model.merge(
                  sourceId: tag.id,
                  into: mergeTargetId,
                  resultName: result.isEmpty ? nil : result
                )
              }
            }
            .disabled(mergeTargetId == nil)
          }

          Divider()

          VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string("tags.delete"))
              .font(.headline)
            Text(L10n.format("tags.deleteMessage", tag.name, tag.itemCount))
              .font(.caption)
              .foregroundColor(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            Button(L10n.string("tags.delete"), role: .destructive) {
              pendingDelete = tag
            }
          }
        }
        .padding(18)
      }
    } else {
      VStack(spacing: 10) {
        Image(systemName: "tag")
          .font(.system(size: 36))
          .foregroundColor(.secondary)
        Text(L10n.string("tags.selectHint"))
          .foregroundColor(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func canRename(_ tag: TagSuggestion) -> Bool {
    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && trimmed.count <= TagKey.maxLength && trimmed != tag.name
  }

  private func rename(_ tag: TagSuggestion) async {
    guard canRename(tag) else { return }
    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    if await model.rename(tag.id, to: trimmed) {
      newName = trimmed
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
