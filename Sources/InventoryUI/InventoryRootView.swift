import InventoryCore
import SwiftUI

public struct InventoryRootView: View {
  @ObservedObject private var model: AppModel

  public init(model: AppModel) {
    self.model = model
  }

  public var body: some View {
    Group {
      switch model.loadState {
      case .idle, .opening:
        OpeningView()
      case .failed(let error):
        StorageFailureView(model: model, error: error)
      case .ready:
        HSplitView {
          SidebarView(selection: $model.selectedSection)
            .frame(minWidth: 180, idealWidth: 200, maxWidth: 260)

          if isSearching, let gallery = model.gallery {
            galleryWorkspace(gallery)
              .frame(minWidth: 480, maxWidth: .infinity)
          } else if let gallery = model.gallery,
            (model.selectedSection ?? .gallery) == .gallery
          {
            galleryWorkspace(gallery)
              .frame(minWidth: 480, maxWidth: .infinity)
          } else if let browser = model.browser,
            (model.selectedSection ?? .places) == .places
          {
            PlaceWorkspaceView(
              browser: browser,
              onAddPlace: { model.presentCreatePlace() },
              onEditPlace: { model.presentEditPlace($0) },
              onAddItem: { model.presentCreateItem(placeId: browser.creationPlaceId) },
              onEditItem: { model.presentEditItem($0) },
              onChangeStatus: { model.presentChangeStatus($0) },
              onGive: { model.presentGive($0) },
              onReturn: { model.presentReturn($0) },
              onOpenPlace: { model.openPlaceInPlaces($0) },
              onOpenPerson: { model.openPerson($0) }
            )
            .frame(minWidth: 480, maxWidth: .infinity)
          } else if let statuses = model.statusesModel,
            (model.selectedSection ?? .gallery) == .statuses
          {
            StatusesWorkspaceView(model: statuses)
              .frame(minWidth: 480, maxWidth: .infinity)
          } else if let people = model.peopleModel,
            (model.selectedSection ?? .gallery) == .people
          {
            PeopleWorkspaceView(
              model: people,
              onOpenItem: { model.openItemInGallery($0) }
            )
            .frame(minWidth: 480, maxWidth: .infinity)
          } else if let tags = model.tagsModel,
            (model.selectedSection ?? .gallery) == .tags
          {
            TagsWorkspaceView(model: tags)
              .frame(minWidth: 480, maxWidth: .infinity)
          } else {
            PlaceholderSectionView(
              section: model.selectedSection ?? .gallery
            )
            .frame(minWidth: 480, maxWidth: .infinity)
          }
        }
      }
    }
    .frame(minWidth: 900, minHeight: 560)
    .toolbar {
      ToolbarItem(placement: .automatic) {
        SearchField(text: $model.searchText, focusToken: model.searchFocusToken)
          .frame(width: 240)
      }
      ToolbarItemGroup(placement: .automatic) {
        Button {
          model.presentCreateItemFromCurrentContext()
        } label: {
          Label(L10n.string("items.add"), systemImage: "plus")
        }
        .disabled(!model.canCreateItem)
        .help(L10n.string("items.add"))
      }
    }
    .task {
      await model.start()
    }
    .onExitCommand {
      model.closeInspector()
    }
    .sheet(item: $model.placeForm) { presentation in
      if let formModel = model.makePlaceFormModel(for: presentation) {
        PlaceFormView(model: formModel, onClose: { model.dismissPlaceForm() })
      }
    }
    .sheet(item: $model.itemForm) { presentation in
      if let formModel = model.makeItemFormModel(for: presentation) {
        ItemFormView(model: formModel, onClose: { model.dismissItemForm() })
      }
    }
    .sheet(item: $model.itemAction) { presentation in
      itemActionSheet(presentation)
    }
    .alert(item: $model.alert) { alert in
      Alert(
        title: Text(L10n.string("common.error")),
        message: Text(alert.message),
        dismissButton: .default(Text(L10n.string("common.ok")))
      )
    }
  }

  private var isSearching: Bool {
    !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  @ViewBuilder
  private func galleryWorkspace(_ gallery: GalleryModel) -> some View {
    GalleryWorkspaceView(
      model: gallery,
      onAddItem: { model.presentCreateItemFromCurrentContext() },
      onEditItem: { model.presentEditItem($0) },
      onChangeStatus: { model.presentChangeStatus($0) },
      onGive: { model.presentGive($0) },
      onReturn: { model.presentReturn($0) },
      onOpenPlace: { model.openPlaceInPlaces($0) },
      onOpenPerson: { model.openPerson($0) }
    )
  }

  @ViewBuilder
  private func itemActionSheet(_ presentation: ItemActionPresentation) -> some View {
    switch presentation.mode {
    case .changeStatus(let details):
      if let sheetModel = model.makeChangeStatusModel(for: details) {
        ChangeStatusSheet(model: sheetModel, onClose: { model.dismissItemAction() })
      }
    case .give(let details):
      if let sheetModel = model.makeGiveModel(for: details) {
        GiveSheet(model: sheetModel, onClose: { model.dismissItemAction() })
      }
    case .returnItem(let details):
      if let sheetModel = model.makeReturnModel(for: details) {
        ReturnSheet(model: sheetModel, onClose: { model.dismissItemAction() })
      }
    }
  }
}

private struct SidebarView: View {
  @Binding var selection: SidebarSection?

  var body: some View {
    List(selection: $selection) {
      Section {
        ForEach(SidebarSection.allCases) { section in
          // Тег без Optional: List(selection:) сопоставляет его с SidebarSection?.
          // С Optional(section) строки не выделялись и не переключали раздел.
          Label(L10n.string(section.titleKey), systemImage: section.systemImage)
            .tag(section)
        }
      }
    }
    .listStyle(.sidebar)
  }
}

private struct OpeningView: View {
  var body: some View {
    VStack(spacing: 12) {
      ProgressView()
      Text(L10n.string("storage.opening"))
        .foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct StorageFailureView: View {
  @ObservedObject var model: AppModel
  let error: AppException

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "externaldrive.badge.exclamationmark")
        .font(.system(size: 44))
        .foregroundColor(.secondary)
      Text(L10n.string("storage.failedTitle"))
        .font(.title2)
      Text(ErrorPresenter.message(for: error))
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 460)
      HStack(spacing: 10) {
        Button(L10n.string("storage.retry")) {
          Task { await model.retry() }
        }
        .keyboardShortcut(.defaultAction)

        Button(L10n.string("storage.chooseFolder")) {
          Task { await model.chooseExistingStore() }
        }

        Button(L10n.string("storage.createFolder")) {
          Task { await model.chooseNewStore() }
        }
      }
    }
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct PlaceholderSectionView: View {
  let titleKey: String
  let messageKey: String
  let systemImage: String

  init(section: SidebarSection) {
    self.titleKey = section.titleKey
    self.messageKey = "section.comingSoon"
    self.systemImage = section.systemImage
  }

  init(titleKey: String, messageKey: String, systemImage: String) {
    self.titleKey = titleKey
    self.messageKey = messageKey
    self.systemImage = systemImage
  }

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: systemImage)
        .font(.system(size: 40))
        .foregroundColor(.secondary)
      Text(L10n.string(titleKey))
        .font(.title2)
      Text(L10n.format(messageKey, L10n.string(titleKey)))
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
    }
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
