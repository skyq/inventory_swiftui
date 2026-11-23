import InventoryCore
import InventoryPlatform
import InventoryUI
import SwiftUI
import UniformTypeIdentifiers

/// Раздел «Данные» на iPhone (IOS.07): экспорт в «Файлы», импорт с подтверждением, откат,
/// папка данных, копии безопасности и напоминание о копии.
struct DataScreen: View {
  @ObservedObject var model: AppModel

  private let preferences = UserDefaultsPreferencesStore()
  @State private var showArchivePicker = false
  @State private var showFolderPicker = false
  @State private var folderKind: PendingFolderChange.Kind = .move
  @State private var exportedFile: URL?
  @State private var showExporter = false

  var body: some View {
    Form {
      Section(L10n.string("data.export.section")) {
        Text(L10n.string("data.export.hint"))
          .font(.caption)
          .foregroundStyle(.secondary)
        Button(L10n.string("data.export.button")) {
          exportToFiles()
        }
      }

      Section(L10n.string("data.import.section")) {
        Text(L10n.string("data.import.hint"))
          .font(.caption)
          .foregroundStyle(.secondary)
        Button(L10n.string("data.import.button")) {
          showArchivePicker = true
        }
        Button(L10n.string("data.rollback.button")) {
          model.pendingRollback = true
        }
        .disabled(!model.safetyUsage.hasBeforeImport)
        if !model.safetyUsage.hasBeforeImport {
          Text(L10n.string("data.rollback.unavailable"))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Section(L10n.string("data.storage.section")) {
        Text(model.storePath ?? "—")
          .font(.callout)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
        Button(L10n.string("data.storage.move")) {
          folderKind = .move
          showFolderPicker = true
        }
        Button(L10n.string("data.storage.open")) {
          folderKind = .open
          showFolderPicker = true
        }
      }

      Section(L10n.string("data.safety.section")) {
        Text(
          L10n.format(
            "data.safety.beforeImport",
            sizeText(model.safetyUsage.beforeImportBytes)
          )
        )
        Button(L10n.string("data.safety.clearBefore"), role: .destructive) {
          model.pendingSafetyClear = .beforeImport
        }
        .disabled(!model.safetyUsage.hasBeforeImport)
      }

      Section(L10n.string("data.reminder.section")) {
        Toggle(
          L10n.string("data.reminder.toggle"),
          isOn: Binding(
            get: { model.backupReminderEnabled },
            set: { model.setBackupReminderEnabled($0) }
          )
        )
        if model.reminderDue {
          Text(L10n.string("data.reminder.due"))
            .foregroundStyle(.orange)
        }
        Text(lastExportText)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .navigationTitle("Данные")
    .disabled(model.dataActivity != nil)
    .overlay {
      if let activity = model.dataActivity {
        activityOverlay(activity)
      }
    }
    .fileImporter(isPresented: $showArchivePicker, allowedContentTypes: [.zip]) { result in
      guard case .success(let url) = result else { return }
      Task { await importArchive(url) }
    }
    .background {
      Color.clear
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
          guard case .success(let url) = result else { return }
          _ = url.startAccessingSecurityScopedResource()
          model.requestFolderChange(folderKind, url: url)
        }
    }
    .fileMover(isPresented: $showExporter, file: exportedFile) { _ in
      removeExportedFile()
    }
    .sheet(item: $model.pendingImport, onDismiss: { model.cancelImport() }) { pending in
      ImportConfirmSheet(
        pending: pending,
        onCancel: { model.cancelImport() },
        onConfirm: { Task { await model.confirmImport() } }
      )
    }
    .alert(
      L10n.string("data.rollback.title"),
      isPresented: $model.pendingRollback
    ) {
      Button(L10n.string("data.rollback.confirm"), role: .destructive) {
        Task { await model.rollbackLastImport() }
      }
      Button(L10n.string("data.cancel"), role: .cancel) {}
    } message: {
      Text(L10n.string("data.rollback.message"))
    }
    .alert(
      L10n.string("data.safety.clearTitle"),
      isPresented: Binding(
        get: { model.pendingSafetyClear != nil },
        set: { if !$0 { model.pendingSafetyClear = nil } }
      )
    ) {
      Button(L10n.string("data.safety.clearConfirm"), role: .destructive) {
        if let kind = model.pendingSafetyClear {
          Task { await model.clearSafetyCopy(kind) }
        }
      }
      Button(L10n.string("data.cancel"), role: .cancel) {}
    } message: {
      Text(L10n.string("data.safety.clearMessage"))
    }
    .alert(
      folderTitle,
      isPresented: Binding(
        get: { model.pendingFolderChange != nil },
        set: { if !$0 { model.pendingFolderChange = nil } }
      )
    ) {
      Button(L10n.string("data.folder.confirm")) {
        if let change = model.pendingFolderChange {
          confirmFolder(change)
        }
      }
      Button(L10n.string("data.cancel"), role: .cancel) {}
    } message: {
      Text(folderMessage)
    }
    .alert(item: $model.alert) { alert in
      switch alert {
      case .failure(let message):
        Alert(title: Text(L10n.string("common.error")), message: Text(message))
      }
    }
    .onAppear { model.refreshDataState() }
  }

  private func activityOverlay(_ activity: DataActivity) -> some View {
    ZStack {
      Color.black.opacity(0.25)
        .ignoresSafeArea()
      VStack(alignment: .leading, spacing: 12) {
        Text(activity.title)
          .font(.headline)
        if let fraction = activity.fraction {
          ProgressView(value: fraction)
        } else {
          ProgressView()
        }
      }
      .padding(24)
      .frame(width: 300)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
  }

  private func exportToFiles() {
    Task {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "export-\(UUID().uuidString)", isDirectory: true)
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      guard let url = await model.exportBackup(to: directory) else {
        try? FileManager.default.removeItem(at: directory)
        return
      }
      exportedFile = url
      showExporter = true
    }
  }

  private func removeExportedFile() {
    if let exportedFile {
      try? FileManager.default.removeItem(at: exportedFile.deletingLastPathComponent())
    }
    exportedFile = nil
  }

  private func importArchive(_ url: URL) async {
    let granted = url.startAccessingSecurityScopedResource()
    defer {
      if granted { url.stopAccessingSecurityScopedResource() }
    }
    await model.prepareImport(archiveAt: url)
  }

  private func confirmFolder(_ change: PendingFolderChange) {
    Task {
      await model.confirmFolderChange(change)
      guard let path = model.storePath else { return }
      if path == DefaultStoreLocation.url().path {
        ExternalStoreAccess.forget(in: preferences)
      } else {
        ExternalStoreAccess.remember(change.url, in: preferences)
      }
    }
  }

  private var folderTitle: String {
    guard let change = model.pendingFolderChange else { return "" }
    return change.kind == .move
      ? L10n.string("data.folder.moveTitle")
      : L10n.string("data.folder.openTitle")
  }

  private var folderMessage: String {
    guard let change = model.pendingFolderChange else { return "" }
    var lines: [String] = []
    if change.kind == .move {
      lines.append(L10n.format("data.folder.moveBody", change.url.path))
    } else {
      lines.append(L10n.format("data.folder.openBody", change.url.path))
    }
    if let provider = change.cloudProvider {
      lines.append(L10n.format("data.folder.cloudWarning", provider))
    }
    return lines.joined(separator: "\n\n")
  }

  private var lastExportText: String {
    guard let date = model.lastBackupExportDate else {
      return L10n.string("data.reminder.never")
    }
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return L10n.format("data.reminder.last", formatter.string(from: date))
  }

  private func sizeText(_ bytes: Int64?) -> String {
    guard let bytes else { return L10n.string("data.safety.none") }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}

/// Подтверждение импорта на iPhone: пользователь вводит число вещей из архива.
private struct ImportConfirmSheet: View {
  let pending: PendingImport
  let onCancel: () -> Void
  let onConfirm: () -> Void

  @State private var typedCount = ""

  var body: some View {
    let expected = pending.validated.itemCount
    NavigationStack {
      Form {
        Section {
          Text(
            L10n.format(
              "data.import.confirmBody",
              expected,
              pending.currentItemCount
            )
          )
          TextField(L10n.string("data.import.confirmField"), text: $typedCount)
            .keyboardType(.numberPad)
        } header: {
          Text(L10n.string("data.import.confirmTitle"))
        }
      }
      .navigationTitle(L10n.string("data.import.confirmTitle"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.string("data.cancel"), action: onCancel)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.string("data.import.confirm"), action: onConfirm)
            .disabled(Int(typedCount.trimmingCharacters(in: .whitespaces)) != expected)
        }
      }
    }
    .presentationDetents([.medium])
  }
}
