import InventoryCore
import InventoryUI
import SwiftUI

/// Теги на iPhone (IOS.06): список с количеством, сортировка, переименование с объединением, объединение и удаление.
struct TagsScreen: View {
  @ObservedObject var model: AppModel

  var body: some View {
    Group {
      if let tags = model.tagsModel {
        TagsContent(tags: tags)
      }
    }
    .navigationTitle(L10n.string("tags.title"))
  }
}

private struct TagsContent: View {
  @ObservedObject var tags: TagsModel

  var body: some View {
    List {
      Section {
        ForEach(tags.sortedTags) { tag in
          NavigationLink {
            TagDetailView(tags: tags, tagId: tag.id)
          } label: {
            HStack(spacing: 6) {
              Text(tag.name)
                .foregroundColor(.primary)
              Spacer(minLength: 6)
              Text(L10n.format("tags.itemCount", tag.itemCount))
                .font(.caption)
                .foregroundColor(.secondary)
            }
          }
        }
      } footer: {
        Text(L10n.format("tags.count", tags.tags.count))
      }
    }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Picker(L10n.string("tags.sort"), selection: $tags.sortMode) {
            Text(L10n.string("tags.sort.name")).tag(TagSortMode.name)
            Text(L10n.string("tags.sort.count")).tag(TagSortMode.count)
          }
        } label: {
          Label(L10n.string("tags.sort"), systemImage: "arrow.up.arrow.down")
        }
      }
    }
    .task { await tags.start() }
  }
}

private struct TagDetailView: View {
  @ObservedObject var tags: TagsModel
  let tagId: String
  @Environment(\.dismiss) private var dismiss
  @State private var showsRename = false
  @State private var showsDelete = false
  @State private var mergeTargetId: String?
  @State private var mergeResultName = ""

  var body: some View {
    Group {
      if let tag = tags.tags.first(where: { $0.id == tagId }) {
        List {
          Section {
            Text(tag.name)
              .font(.title3.weight(.semibold))
            Text(L10n.format("tags.itemCount", tag.itemCount))
              .foregroundColor(.secondary)
          }

          Section {
            Button(L10n.string("tags.rename")) {
              showsRename = true
            }
            Button(L10n.string("tags.delete"), role: .destructive) {
              showsDelete = true
            }
          } footer: {
            Text(L10n.string("tags.renameHint"))
          }

          Section {
            Picker(L10n.string("tags.mergeTarget"), selection: $mergeTargetId) {
              Text(L10n.string("tags.mergeTargetNone")).tag(String?.none)
              ForEach(tags.tags.filter { $0.id != tagId }) { other in
                Text(other.name).tag(Optional(other.id))
              }
            }
            TextField(L10n.string("tags.mergeResultName"), text: $mergeResultName)
            Button(L10n.string("tags.merge")) {
              guard let targetId = mergeTargetId else { return }
              let trimmed = mergeResultName.trimmingCharacters(in: .whitespacesAndNewlines)
              Task {
                if await tags.merge(
                  sourceId: tagId,
                  into: targetId,
                  resultName: trimmed.isEmpty ? nil : trimmed
                ) {
                  dismiss()
                }
              }
            }
            .disabled(mergeTargetId == nil)
          } header: {
            Text(L10n.string("tags.merge"))
          } footer: {
            Text(L10n.string("tags.mergeHint"))
          }
        }
        .navigationTitle(tag.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsRename) {
          NameFormScreen(
            title: L10n.string("tags.renameTitle"),
            fieldTitle: L10n.string("tags.name"),
            initialName: tag.name,
            alertMessage: $tags.alertMessage,
            onSave: { name in
              let saved = await tags.rename(tag.id, to: name)
              if !saved, tags.renameSuggestion != nil {
                showsRename = false
              }
              return saved
            },
            onClose: { showsRename = false }
          )
        }
        .alert(
          L10n.string("tags.deleteTitle"),
          isPresented: $showsDelete
        ) {
          Button(L10n.string("tags.delete"), role: .destructive) {
            Task {
              if await tags.delete(tag.id) {
                dismiss()
              }
            }
          }
          Button(L10n.string("places.cancel"), role: .cancel) {}
        } message: {
          Text(L10n.format("tags.deleteMessage", tag.name, tag.itemCount))
        }
        .alert(
          L10n.string("tags.renameMergeTitle"),
          isPresented: Binding(
            get: { tags.renameSuggestion != nil },
            set: { if !$0 { tags.renameSuggestion = nil } }
          )
        ) {
          Button(L10n.string("tags.mergeConfirm")) {
            Task {
              await tags.confirmRenameMerge()
              dismiss()
            }
          }
          Button(L10n.string("places.cancel"), role: .cancel) {
            tags.renameSuggestion = nil
          }
        } message: {
          if let suggestion = tags.renameSuggestion {
            Text(
              L10n.format(
                "tags.renameMergeMessage",
                suggestion.sourceName,
                suggestion.targetName
              )
            )
          }
        }
        .errorAlert($tags.alertMessage)
      } else {
        ProgressView()
      }
    }
  }
}
