import InventoryCore
import InventoryUI
import SwiftUI

/// Статусы на iPhone (IOS.06): активные и архивные, добавление, переименование, архивирование и настройки по умолчанию.
struct StatusesScreen: View {
  @ObservedObject var model: AppModel

  var body: some View {
    Group {
      if let statuses = model.statusesModel {
        StatusesContent(statuses: statuses)
      }
    }
    .navigationTitle(L10n.string("statuses.title"))
  }
}

private struct StatusesContent: View {
  @ObservedObject var statuses: StatusesModel
  @State private var showsNew = false
  @State private var showsSettings = false

  var body: some View {
    List {
      Section {
        ForEach(statuses.activeStatuses) { status in
          statusLink(status)
        }
      } header: {
        Text(L10n.string("statuses.activeSection"))
      } footer: {
        Text(L10n.string("statuses.activeHint"))
      }

      if statuses.includeArchived, !statuses.archivedStatuses.isEmpty {
        Section {
          ForEach(statuses.archivedStatuses) { status in
            statusLink(status)
          }
        } header: {
          Text(L10n.string("statuses.archivedSection"))
        } footer: {
          Text(L10n.string("statuses.archivedHint"))
        }
      }

      Section {
        Button(L10n.string("statuses.settingsTitle")) {
          showsSettings = true
        }
        .disabled(statuses.settings == nil)
      } footer: {
        Text(L10n.string("statuses.settingsHint"))
      }
    }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          showsNew = true
        } label: {
          Label(L10n.string("statuses.add"), systemImage: "plus")
        }
      }
      ToolbarItem(placement: .topBarLeading) {
        Menu {
          Toggle(L10n.string("statuses.showArchived"), isOn: $statuses.includeArchived)
        } label: {
          Label(
            L10n.string("statuses.showArchived"),
            systemImage: statuses.includeArchived ? "archivebox.fill" : "archivebox"
          )
        }
      }
    }
    .sheet(isPresented: $showsNew) {
      NameFormScreen(
        title: L10n.string("statuses.newTitle"),
        fieldTitle: L10n.string("statuses.name"),
        initialName: "",
        alertMessage: $statuses.alertMessage,
        onSave: { name in await statuses.create(name: name) != nil },
        onClose: { showsNew = false }
      )
    }
    .sheet(isPresented: $showsSettings) {
      StatusSettingsScreen(statuses: statuses, onClose: { showsSettings = false })
    }
    .task { await statuses.start() }
  }

  private func statusLink(_ status: Status) -> some View {
    NavigationLink {
      StatusDetailView(statuses: statuses, statusId: status.id)
    } label: {
      HStack(spacing: 6) {
        Text(status.name)
          .foregroundColor(.primary)
        Spacer(minLength: 6)
        if status.isArchived {
          Text(L10n.string("gallery.archived"))
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }
    }
  }
}

private struct StatusDetailView: View {
  @ObservedObject var statuses: StatusesModel
  let statusId: String
  @State private var showsRename = false
  @State private var showsArchive = false

  var body: some View {
    Group {
      if let status = statuses.statuses.first(where: { $0.id == statusId }) {
        List {
          Section {
            Text(status.name)
              .font(.title3.weight(.semibold))
            if status.isArchived {
              Text(L10n.string("statuses.archivedHint"))
                .font(.callout)
                .foregroundColor(.secondary)
            }
          }

          if !statuses.settingsSlots(using: status.id).isEmpty {
            Section(L10n.string("statuses.usedInSettings")) {
              ForEach(statuses.settingsSlots(using: status.id)) { slot in
                Text(slot.title)
              }
            }
          }

          Section {
            Toggle(
              L10n.string("statuses.hidden"),
              isOn: Binding(
                get: { status.isHidden },
                set: { hidden in Task { _ = await statuses.setHidden(status.id, hidden: hidden) } }
              )
            )
          } footer: {
            Text(L10n.string("statuses.hiddenHint"))
          }

          Section {
            Button(L10n.string("statuses.rename")) {
              showsRename = true
            }
            if status.isArchived {
              Button(L10n.string("statuses.restore")) {
                Task { _ = await statuses.restore(status.id) }
              }
            } else {
              Button(L10n.string("statuses.archive"), role: .destructive) {
                showsArchive = true
              }
            }
          }
        }
        .navigationTitle(status.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsRename) {
          NameFormScreen(
            title: L10n.string("statuses.renameTitle"),
            fieldTitle: L10n.string("statuses.name"),
            initialName: status.name,
            alertMessage: $statuses.alertMessage,
            onSave: { name in await statuses.rename(status.id, to: name) },
            onClose: { showsRename = false }
          )
        }
        .sheet(isPresented: $showsArchive) {
          StatusArchiveSheet(
            statuses: statuses,
            status: status,
            onClose: { showsArchive = false }
          )
        }
        .errorAlert($statuses.alertMessage)
      } else {
        ProgressView()
      }
    }
  }
}

private struct StatusArchiveSheet: View {
  @ObservedObject var statuses: StatusesModel
  let status: Status
  let onClose: () -> Void
  @State private var replacementId: String?

  init(statuses: StatusesModel, status: Status, onClose: @escaping () -> Void) {
    _statuses = ObservedObject(wrappedValue: statuses)
    self.status = status
    self.onClose = onClose
    let used = !statuses.settingsSlots(using: status.id).isEmpty
    _replacementId = State(
      initialValue: used ? statuses.replacementCandidates(excluding: status.id).first?.id : nil
    )
  }

  private var usedSlots: [StatusSettingSlot] {
    statuses.settingsSlots(using: status.id)
  }

  private var candidates: [Status] {
    statuses.replacementCandidates(excluding: status.id)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text(
            usedSlots.isEmpty
              ? L10n.string("statuses.archiveMessage")
              : L10n.format("statuses.archiveReplaceMessage", status.name)
          )
        }

        if !usedSlots.isEmpty {
          Section(L10n.string("statuses.replacement")) {
            if candidates.isEmpty {
              Text(L10n.string("statuses.noReplacement"))
                .foregroundColor(.secondary)
            } else {
              Picker(L10n.string("statuses.replacement"), selection: $replacementId) {
                ForEach(candidates) { candidate in
                  Text(candidate.name).tag(Optional(candidate.id))
                }
              }
            }
          }
        }
      }
      .navigationTitle(L10n.string("statuses.archiveTitle"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.string("places.cancel")) {
            onClose()
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.string("statuses.archive"), role: .destructive) {
            Task {
              if await statuses.archive(status.id, replacementId: replacementId) {
                onClose()
              }
            }
          }
          .disabled(!usedSlots.isEmpty && replacementId == nil)
        }
      }
      .errorAlert($statuses.alertMessage)
    }
  }
}

private struct StatusSettingsScreen: View {
  @ObservedObject var statuses: StatusesModel
  let onClose: () -> Void
  @State private var defaultId: String
  @State private var transferId: String
  @State private var returnId: String

  init(statuses: StatusesModel, onClose: @escaping () -> Void) {
    _statuses = ObservedObject(wrappedValue: statuses)
    self.onClose = onClose
    _defaultId = State(initialValue: statuses.statusId(for: .defaultStatus) ?? "")
    _transferId = State(initialValue: statuses.statusId(for: .transferStatus) ?? "")
    _returnId = State(initialValue: statuses.statusId(for: .returnStatus) ?? "")
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          statusPicker(StatusSettingSlot.defaultStatus.title, selection: $defaultId)
          statusPicker(StatusSettingSlot.transferStatus.title, selection: $transferId)
          statusPicker(StatusSettingSlot.returnStatus.title, selection: $returnId)
        } footer: {
          Text(L10n.string("statuses.settingsHint"))
        }
      }
      .navigationTitle(L10n.string("statuses.settingsTitle"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.string("places.cancel")) {
            onClose()
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.string("statuses.settingsSave")) {
            Task {
              if await statuses.updateSettings(
                defaultStatusId: defaultId,
                transferStatusId: transferId,
                returnStatusId: returnId
              ) {
                onClose()
              }
            }
          }
          .disabled(defaultId.isEmpty || transferId.isEmpty || returnId.isEmpty)
        }
      }
      .errorAlert($statuses.alertMessage)
    }
  }

  private func statusPicker(_ title: String, selection: Binding<String>) -> some View {
    Picker(title, selection: selection) {
      ForEach(statuses.activeStatuses) { status in
        Text(status.name).tag(status.id)
      }
    }
  }
}

extension StatusSettingSlot {
  fileprivate var title: String {
    switch self {
    case .defaultStatus: return L10n.string("statuses.setting.default")
    case .transferStatus: return L10n.string("statuses.setting.transfer")
    case .returnStatus: return L10n.string("statuses.setting.return")
    }
  }
}
