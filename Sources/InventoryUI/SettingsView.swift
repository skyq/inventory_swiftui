import AppKit
import SwiftUI

public struct SettingsView: View {
  @ObservedObject private var model: AppModel

  public init(model: AppModel) {
    self.model = model
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(L10n.string("settings.data"))
        .font(.headline)

      VStack(alignment: .leading, spacing: 6) {
        Text(L10n.string("settings.folder"))
        Text(model.storePath ?? "—")
          .font(.callout)
          .foregroundColor(.secondary)
          .textSelection(.enabled)
          .lineLimit(3)
        Text(L10n.string("settings.folderHint"))
          .font(.caption)
          .foregroundColor(.secondary)
      }

      HStack(spacing: 10) {
        Button(L10n.string("settings.showInFinder")) {
          guard let path = model.storePath else { return }
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        .disabled(model.storePath == nil)

        Button(L10n.string("storage.chooseFolder")) {
          Task { await model.chooseExistingStore() }
        }
      }

      Divider()

      Text(L10n.string("settings.comingSoon"))
        .font(.caption)
        .foregroundColor(.secondary)

      Spacer(minLength: 0)
    }
    .padding(24)
    .frame(width: 460, height: 300, alignment: .topLeading)
  }
}
