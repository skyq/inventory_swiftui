#if os(macOS)
  import AppKit
  import InventoryCore
  import SwiftUI

  public struct SettingsView: View {
    @ObservedObject private var model: AppModel
    @State private var statuses: [Status] = []
    @State private var defaultId = ""
    @State private var transferId = ""
    @State private var returnId = ""
    @State private var loaded = false

    public init(model: AppModel) {
      self.model = model
    }

    public var body: some View {
      Form {
        Section(L10n.string("settings.folder")) {
          Text(model.storePath ?? "—")
            .font(.callout)
            .foregroundColor(.secondary)
            .textSelection(.enabled)
            .lineLimit(3)
          Text(L10n.string("settings.folderHint"))
            .font(.caption)
            .foregroundColor(.secondary)
          HStack(spacing: 10) {
            Button(L10n.string("settings.showInFinder")) {
              guard let path = model.storePath else { return }
              NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            .disabled(model.storePath == nil)
            Button(L10n.string("data.storage.open")) {
              model.chooseOpenFolder()
            }
          }
        }

        Section(L10n.string("settings.statuses")) {
          if loaded {
            statusPicker(L10n.string("settings.status.default"), selection: $defaultId)
            statusPicker(L10n.string("settings.status.transfer"), selection: $transferId)
            statusPicker(L10n.string("settings.status.return"), selection: $returnId)
            Button(L10n.string("settings.save")) {
              Task { await save() }
            }
            .disabled(defaultId.isEmpty || transferId.isEmpty || returnId.isEmpty)
          } else {
            Text(L10n.string("settings.statusesUnavailable"))
              .foregroundColor(.secondary)
          }
        }

        Section(L10n.string("settings.reminder")) {
          Toggle(
            L10n.string("data.reminder.toggle"),
            isOn: Binding(
              get: { model.backupReminderEnabled },
              set: { model.setBackupReminderEnabled($0) }
            )
          )
        }
      }
      .padding(20)
      .frame(width: 480, height: 460)
      .onAppear { reload() }
    }

    private func statusPicker(_ title: String, selection: Binding<String>) -> some View {
      Picker(title, selection: selection) {
        ForEach(statuses, id: \.id) { status in
          Text(status.name).tag(status.id)
        }
      }
    }

    private func reload() {
      guard let snapshot = model.statusSettingsSnapshot() else {
        loaded = false
        return
      }
      statuses = snapshot.statuses
      defaultId = snapshot.settings.defaultStatusId
      transferId = snapshot.settings.transferStatusId
      returnId = snapshot.settings.returnStatusId
      loaded = true
    }

    private func save() async {
      let settings = StatusSettings(
        defaultStatusId: defaultId,
        transferStatusId: transferId,
        returnStatusId: returnId
      )
      await model.saveStatusSettings(settings)
      reload()
    }
  }
#endif
