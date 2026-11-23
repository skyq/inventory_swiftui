import InventoryCore
import SwiftUI

/// Раздел «Данные»: экспорт, импорт, откат, папка данных, копии безопасности и напоминание.
struct DataWorkspaceView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    Form {
      Section(L10n.string("data.export.section")) {
        Text(L10n.string("data.export.hint"))
          .font(.caption)
          .foregroundColor(.secondary)
        Button(L10n.string("data.export.button")) {
          Task { await model.exportWithDialog() }
        }
        .disabled(model.dataActivity != nil)
      }

      Section(L10n.string("data.import.section")) {
        Text(L10n.string("data.import.hint"))
          .font(.caption)
          .foregroundColor(.secondary)
        Button(L10n.string("data.import.button")) {
          Task { await model.chooseImportArchive() }
        }
        .disabled(model.dataActivity != nil)

        Button(L10n.string("data.rollback.button")) {
          model.pendingRollback = true
        }
        .disabled(!model.safetyUsage.hasBeforeImport || model.dataActivity != nil)
        if !model.safetyUsage.hasBeforeImport {
          Text(L10n.string("data.rollback.unavailable"))
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }

      Section(L10n.string("data.storage.section")) {
        Text(model.storePath ?? "—")
          .font(.callout)
          .foregroundColor(.secondary)
          .textSelection(.enabled)
          .lineLimit(3)
        HStack {
          Button(L10n.string("data.storage.move")) {
            model.chooseMoveDestination()
          }
          Button(L10n.string("data.storage.open")) {
            model.chooseOpenFolder()
          }
        }
        .disabled(model.dataActivity != nil)
      }

      Section(L10n.string("data.safety.section")) {
        Text(
          L10n.format(
            "data.safety.beforeImport",
            sizeText(model.safetyUsage.beforeImportBytes)
          )
        )
        Button(L10n.string("data.safety.clearBefore")) {
          model.pendingSafetyClear = .beforeImport
        }
        .disabled(!model.safetyUsage.hasBeforeImport || model.dataActivity != nil)
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
            .foregroundColor(.orange)
        }
        Text(lastExportText)
          .font(.caption)
          .foregroundColor(.secondary)
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .alert(
      item: $model.pendingFolderChange
    ) { change in
      Alert(
        title: Text(
          change.kind == .move
            ? L10n.string("data.folder.moveTitle")
            : L10n.string("data.folder.openTitle")),
        message: Text(folderMessage(change)),
        primaryButton: .default(Text(L10n.string("data.folder.confirm"))) {
          Task { await model.confirmFolderChange(change) }
        },
        secondaryButton: .cancel(Text(L10n.string("data.cancel")))
      )
    }
    .alert(
      isPresented: $model.pendingRollback
    ) {
      Alert(
        title: Text(L10n.string("data.rollback.title")),
        message: Text(L10n.string("data.rollback.message")),
        primaryButton: .destructive(Text(L10n.string("data.rollback.confirm"))) {
          Task { await model.rollbackLastImport() }
        },
        secondaryButton: .cancel(Text(L10n.string("data.cancel")))
      )
    }
    .alert(
      item: $model.pendingSafetyClear
    ) { kind in
      Alert(
        title: Text(L10n.string("data.safety.clearTitle")),
        message: Text(L10n.string("data.safety.clearMessage")),
        primaryButton: .destructive(Text(L10n.string("data.safety.clearConfirm"))) {
          Task { await model.clearSafetyCopy(kind) }
        },
        secondaryButton: .cancel(Text(L10n.string("data.cancel")))
      )
    }
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

  private func folderMessage(_ change: PendingFolderChange) -> String {
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

  private func sizeText(_ bytes: Int64?) -> String {
    guard let bytes else { return L10n.string("data.safety.none") }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}

/// Подтверждение импорта: пользователь вводит число вещей из архива.
struct ImportConfirmView: View {
  let pending: PendingImport
  let onCancel: () -> Void
  let onConfirm: (Int) -> Void

  @State private var typedCount = ""

  var body: some View {
    let expected = pending.validated.itemCount
    VStack(alignment: .leading, spacing: 14) {
      Text(L10n.string("data.import.confirmTitle"))
        .font(.headline)
      Text(
        L10n.format(
          "data.import.confirmBody",
          expected,
          pending.currentItemCount
        )
      )
      .fixedSize(horizontal: false, vertical: true)
      TextField(L10n.string("data.import.confirmField"), text: $typedCount)
        .textFieldStyle(.roundedBorder)
      HStack {
        Spacer()
        Button(L10n.string("data.cancel")) { onCancel() }
          .keyboardShortcut(.cancelAction)
        Button(L10n.string("data.import.confirm")) { onConfirm(expected) }
          .keyboardShortcut(.defaultAction)
          .disabled(Int(typedCount.trimmingCharacters(in: .whitespaces)) != expected)
      }
    }
    .padding(24)
    .frame(width: 440)
  }
}

/// Модальный прогресс длительной операции. Закрыть нельзя до завершения.
struct DataActivityView: View {
  let activity: DataActivity

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(activity.title)
        .font(.headline)
      if let fraction = activity.fraction {
        ProgressView(value: fraction)
      } else {
        ProgressView()
          .progressViewStyle(.linear)
      }
    }
    .padding(24)
    .frame(width: 360)
  }
}
