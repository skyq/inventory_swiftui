import InventoryCore
import SwiftUI

/// Раздел «Статусы»: справочник и три настройки назначения.
struct StatusesWorkspaceView: View {
  @ObservedObject var model: StatusesModel

  @State private var nameSheet: StatusNameSheetMode?
  @State private var archivingStatus: Status?
  @State private var unusedArchiveConfirmation: Status?
  @State private var replacementId: String?

  @State private var defaultStatusId: String?
  @State private var transferStatusId: String?
  @State private var returnStatusId: String?

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
      .frame(minWidth: 320, idealWidth: 360, maxWidth: 460)

      detail
        .frame(minWidth: 360, maxWidth: .infinity)
    }
    .task {
      await model.start()
      syncSettingsFields()
    }
    .onChange(of: model.settings) { _ in syncSettingsFields() }
    .sheet(item: $nameSheet) { mode in
      StatusNameSheet(
        mode: mode,
        existingNames: model.statuses.map(\.name),
        onSave: { name in
          switch mode {
          case .create:
            return await model.create(name: name) != nil
          case .rename(let status):
            return await model.rename(status.id, to: name)
          }
        },
        onClose: { nameSheet = nil }
      )
    }
    .sheet(item: $archivingStatus) { status in
      StatusArchiveSheet(
        status: status,
        slots: model.settingsSlots(using: status.id),
        candidates: model.replacementCandidates(excluding: status.id),
        replacementId: $replacementId,
        onConfirm: {
          Task {
            if await model.archive(status.id, replacementId: replacementId) {
              archivingStatus = nil
            }
          }
        },
        onClose: {
          archivingStatus = nil
          replacementId = nil
        }
      )
    }
    .alert(
      L10n.string("statuses.archiveTitle"),
      isPresented: Binding(
        get: { unusedArchiveConfirmation != nil },
        set: { if !$0 { unusedArchiveConfirmation = nil } }
      )
    ) {
      Button(L10n.string("statuses.archive"), role: .destructive) {
        guard let status = unusedArchiveConfirmation else { return }
        unusedArchiveConfirmation = nil
        Task { _ = await model.archive(status.id, replacementId: nil) }
      }
      Button(L10n.string("places.cancel"), role: .cancel) {
        unusedArchiveConfirmation = nil
      }
    } message: {
      Text(L10n.string("statuses.archiveMessage"))
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
      Text(L10n.format("statuses.count", model.activeStatuses.count))
        .font(.callout)
        .foregroundColor(.secondary)
      Spacer()
      Toggle(L10n.string("statuses.showArchived"), isOn: $model.includeArchived)
        .toggleStyle(.checkbox)
        .controlSize(.small)
      Button {
        nameSheet = .create
      } label: {
        Label(L10n.string("statuses.add"), systemImage: "plus")
      }
      .buttonStyle(.bordered)
      .help(L10n.string("statuses.add"))
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  private var list: some View {
    List(selection: $model.selectedStatusId) {
      if model.includeArchived {
        Section(L10n.string("statuses.activeSection")) {
          ForEach(model.activeStatuses) { status in
            row(status)
          }
        }
        if !model.archivedStatuses.isEmpty {
          Section(L10n.string("statuses.archivedSection")) {
            ForEach(model.archivedStatuses) { status in
              row(status)
            }
          }
        }
      } else {
        ForEach(model.activeStatuses) { status in
          row(status)
        }
      }
    }
    .listStyle(.inset)
  }

  private func row(_ status: Status) -> some View {
    HStack(spacing: 6) {
      Text(status.name)
      Spacer(minLength: 6)
      if status.isArchived {
        Text(L10n.string("gallery.archived"))
          .font(.caption2)
          .foregroundColor(.secondary)
      } else if !model.settingsSlots(using: status.id).isEmpty {
        Image(systemName: "pin.fill")
          .font(.caption2)
          .foregroundColor(.secondary)
          .help(L10n.string("statuses.usedInSettings"))
      }
    }
    .tag(status.id)
    .contextMenu {
      Button(L10n.string("statuses.rename")) { nameSheet = .rename(status) }
      if status.isArchived {
        Button(L10n.string("statuses.restore")) {
          Task { _ = await model.restore(status.id) }
        }
      } else {
        Button(L10n.string("statuses.archive")) {
          beginArchive(status)
        }
      }
    }
  }

  @ViewBuilder
  private var detail: some View {
    if let status = model.selectedStatus {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          VStack(alignment: .leading, spacing: 4) {
            Text(status.name)
              .font(.title3)
              .fontWeight(.semibold)
            Text(
              status.isArchived
                ? L10n.string("statuses.archivedHint")
                : L10n.string("statuses.activeHint")
            )
            .font(.caption)
            .foregroundColor(.secondary)
          }

          if !model.settingsSlots(using: status.id).isEmpty {
            VStack(alignment: .leading, spacing: 4) {
              Text(L10n.string("statuses.usedInSettings"))
                .font(.caption)
                .foregroundColor(.secondary)
              Text(slotNames(model.settingsSlots(using: status.id)).joined(separator: ", "))
                .font(.callout)
            }
          }

          HStack(spacing: 8) {
            Button(L10n.string("statuses.rename")) {
              nameSheet = .rename(status)
            }
            if status.isArchived {
              Button(L10n.string("statuses.restore")) {
                Task { _ = await model.restore(status.id) }
              }
            } else {
              Button(L10n.string("statuses.archive")) {
                beginArchive(status)
              }
            }
          }
          .buttonStyle(.bordered)

          Divider()

          settingsForm
        }
        .padding(18)
      }
    } else {
      settingsForm
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  private var settingsForm: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(L10n.string("statuses.settingsTitle"))
        .font(.headline)
      Text(L10n.string("statuses.settingsHint"))
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Picker(L10n.string("statuses.setting.default"), selection: $defaultStatusId) {
        Text(L10n.string("items.statusDefault")).tag(String?.none)
        ForEach(model.activeStatuses) { status in
          Text(status.name).tag(Optional(status.id))
        }
      }
      Picker(L10n.string("statuses.setting.transfer"), selection: $transferStatusId) {
        Text(L10n.string("items.statusDefault")).tag(String?.none)
        ForEach(model.activeStatuses) { status in
          Text(status.name).tag(Optional(status.id))
        }
      }
      Picker(L10n.string("statuses.setting.return"), selection: $returnStatusId) {
        Text(L10n.string("items.statusDefault")).tag(String?.none)
        ForEach(model.activeStatuses) { status in
          Text(status.name).tag(Optional(status.id))
        }
      }

      Button(L10n.string("statuses.settingsSave")) {
        guard let defaultStatusId, let transferStatusId, let returnStatusId else { return }
        Task {
          _ = await model.updateSettings(
            defaultStatusId: defaultStatusId,
            transferStatusId: transferStatusId,
            returnStatusId: returnStatusId
          )
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(
        defaultStatusId == nil || transferStatusId == nil || returnStatusId == nil
          || !settingsDirty
      )
    }
  }

  private var settingsDirty: Bool {
    guard let settings = model.settings else { return true }
    return settings.defaultStatusId != defaultStatusId
      || settings.transferStatusId != transferStatusId
      || settings.returnStatusId != returnStatusId
  }

  private func syncSettingsFields() {
    guard let settings = model.settings else { return }
    defaultStatusId = settings.defaultStatusId
    transferStatusId = settings.transferStatusId
    returnStatusId = settings.returnStatusId
  }

  private func beginArchive(_ status: Status) {
    if model.settingsSlots(using: status.id).isEmpty {
      unusedArchiveConfirmation = status
    } else {
      replacementId = model.replacementCandidates(excluding: status.id).first?.id
      archivingStatus = status
    }
  }

  private func slotNames(_ slots: [StatusSettingSlot]) -> [String] {
    slots.map { slot in
      switch slot {
      case .defaultStatus: return L10n.string("statuses.setting.default")
      case .transferStatus: return L10n.string("statuses.setting.transfer")
      case .returnStatus: return L10n.string("statuses.setting.return")
      }
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

enum StatusNameSheetMode: Identifiable, Equatable {
  case create
  case rename(Status)

  var id: String {
    switch self {
    case .create: return "create"
    case .rename(let status): return "rename-\(status.id)"
    }
  }
}

/// Создание или переименование статуса.
struct StatusNameSheet: View {
  let mode: StatusNameSheetMode
  let existingNames: [String]
  let onSave: (String) async -> Bool
  let onClose: () -> Void

  @State private var name: String
  @State private var isSaving = false
  @State private var errorMessage: String?

  init(
    mode: StatusNameSheetMode,
    existingNames: [String],
    onSave: @escaping (String) async -> Bool,
    onClose: @escaping () -> Void
  ) {
    self.mode = mode
    self.existingNames = existingNames
    self.onSave = onSave
    self.onClose = onClose
    switch mode {
    case .create:
      _name = State(initialValue: "")
    case .rename(let status):
      _name = State(initialValue: status.name)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      sheetHeader(title)
      Divider()
      Form {
        TextField(L10n.string("statuses.name"), text: $name)
          .onSubmit { Task { await save() } }
        Text(L10n.format("statuses.nameMaxLength", NameKey.maxLength))
          .font(.caption)
          .foregroundColor(.secondary)
        if let errorMessage {
          Text(errorMessage)
            .font(.caption)
            .foregroundColor(.red)
        }
      }
      Divider()
      sheetFooter(
        saveTitle: L10n.string("places.save"),
        canSave: canSave,
        isSaving: isSaving,
        onSave: { Task { await save() } },
        onClose: onClose
      )
    }
    .frame(width: 420)
    .onExitCommand { onClose() }
  }

  private var title: String {
    switch mode {
    case .create: return L10n.string("statuses.newTitle")
    case .rename: return L10n.string("statuses.renameTitle")
    }
  }

  private var trimmed: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canSave: Bool {
    !trimmed.isEmpty && trimmed.count <= NameKey.maxLength && !isSaving
  }

  private func save() async {
    guard canSave else { return }
    let normalized = trimmed.lowercased()
    switch mode {
    case .create:
      if existingNames.contains(where: { $0.lowercased() == normalized }) {
        errorMessage = L10n.string("statuses.nameDuplicate")
        return
      }
    case .rename(let status):
      let duplicate = existingNames.contains {
        $0.lowercased() == normalized && $0.lowercased() != status.name.lowercased()
      }
      if duplicate {
        errorMessage = L10n.string("statuses.nameDuplicate")
        return
      }
    }
    isSaving = true
    let saved = await onSave(trimmed)
    isSaving = false
    if saved {
      onClose()
    } else {
      errorMessage = L10n.string("statuses.nameDuplicate")
    }
  }
}

/// Архивация статуса из настроек: замена обязательна.
struct StatusArchiveSheet: View {
  let status: Status
  let slots: [StatusSettingSlot]
  let candidates: [Status]
  @Binding var replacementId: String?
  let onConfirm: () -> Void
  let onClose: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      sheetHeader(L10n.string("statuses.archiveTitle"))
      Divider()
      Form {
        Text(L10n.format("statuses.archiveReplaceMessage", status.name))
          .font(.callout)
          .fixedSize(horizontal: false, vertical: true)
        if !slots.isEmpty {
          Picker(L10n.string("statuses.replacement"), selection: $replacementId) {
            Text(L10n.string("statuses.replacementRequired")).tag(String?.none)
            ForEach(candidates) { candidate in
              Text(candidate.name).tag(Optional(candidate.id))
            }
          }
        }
        if candidates.isEmpty && !slots.isEmpty {
          Text(L10n.string("statuses.noReplacement"))
            .font(.caption)
            .foregroundColor(.orange)
        }
      }
      Divider()
      sheetFooter(
        saveTitle: L10n.string("statuses.archive"),
        canSave: slots.isEmpty || replacementId != nil,
        isSaving: false,
        onSave: onConfirm,
        onClose: onClose
      )
    }
    .frame(width: 440)
    .onExitCommand { onClose() }
  }
}
