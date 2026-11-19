import InventoryCore
import SwiftUI

struct PlaceWorkspaceView: View {
  @ObservedObject var browser: PlaceBrowserModel
  let onAddPlace: () -> Void
  let onEditPlace: (Place) -> Void

  var body: some View {
    HSplitView {
      PlacesBrowserView(
        model: browser,
        onAddPlace: onAddPlace,
        onEditPlace: onEditPlace
      )
      .frame(minWidth: 420, maxWidth: .infinity)

      if browser.showsInspector, let place = browser.selectedPlace {
        PlaceInspectorView(
          place: place,
          path: browser.selectedPath,
          photoURL: browser.photoURL(for: place),
          onEdit: { onEditPlace(place) },
          onDelete: { browser.requestDeleteSelected() },
          onClose: { browser.clearSelection() }
        )
        .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
      }
    }
  }
}

struct PlacesBrowserView: View {
  @ObservedObject var model: PlaceBrowserModel
  let onAddPlace: () -> Void
  let onEditPlace: (Place) -> Void

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if let error = model.loadError {
        errorBanner(error)
        Divider()
      }
      content
    }
    .alert(item: $model.alert) { alert in
      switch alert {
      case .delete(let place):
        return Alert(
          title: Text(L10n.string("places.deleteTitle")),
          message: Text(L10n.format("places.deleteMessage", place.name)),
          primaryButton: .destructive(Text(L10n.string("places.delete"))) {
            Task { await model.confirmDelete(place) }
          },
          secondaryButton: .cancel(Text(L10n.string("places.cancel")))
        )
      case .failure(let message):
        return Alert(
          title: Text(L10n.string("common.error")),
          message: Text(message),
          dismissButton: .default(Text(L10n.string("common.ok")))
        )
      }
    }
  }

  private var header: some View {
    HStack(spacing: 6) {
      Button {
        Task { await model.openRoot() }
      } label: {
        Text(L10n.string("places.root"))
          .fontWeight(model.currentPath.isEmpty ? .semibold : .regular)
      }
      .buttonStyle(.plain)
      .foregroundColor(model.currentPath.isEmpty ? .primary : .accentColor)

      ForEach(Array(model.currentPath.enumerated()), id: \.element.id) { index, place in
        Image(systemName: "chevron.compact.right")
          .foregroundColor(.secondary)
        if index == model.currentPath.count - 1 {
          Text(place.name)
            .fontWeight(.semibold)
            .lineLimit(1)
            .help(place.name)
        } else {
          Button {
            Task { await model.navigate(to: place) }
          } label: {
            Text(place.name).lineLimit(1)
          }
          .buttonStyle(.plain)
          .foregroundColor(.accentColor)
          .help(place.name)
        }
      }

      Spacer(minLength: 8)

      Button {
        model.toggleInspector()
      } label: {
        Image(systemName: "sidebar.right")
      }
      .buttonStyle(.borderless)
      .disabled(model.selectedPlace == nil)
      .help(L10n.string("places.inspector.toggle"))

      Button {
        onAddPlace()
      } label: {
        Label(L10n.string("places.add"), systemImage: "plus")
      }
      .buttonStyle(.bordered)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  @ViewBuilder
  private var content: some View {
    if model.isLoading && model.children.isEmpty {
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if model.children.isEmpty {
      emptyState
    } else {
      ScrollView {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 148), spacing: 16)],
          alignment: .leading,
          spacing: 18
        ) {
          ForEach(model.children) { place in
            PlaceCell(
              place: place,
              thumbnailURL: model.thumbnailURL(for: place)
            ) {
              Task { await model.open(place) }
            }
          }
        }
        .padding(16)
      }
    }
  }

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "folder")
        .font(.system(size: 40))
        .foregroundColor(.secondary)
      Text(L10n.string("places.empty"))
        .font(.title3)
      Text(L10n.string("places.emptyHint"))
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 360)
      Button {
        onAddPlace()
      } label: {
        Label(L10n.string("places.add"), systemImage: "plus")
      }
      .buttonStyle(.borderedProminent)
      .padding(.top, 4)
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func errorBanner(_ error: AppException) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundColor(.orange)
      Text(ErrorPresenter.message(for: error))
        .font(.callout)
      Spacer()
      Button(L10n.string("storage.retry")) {
        Task { await model.reload() }
      }
      .buttonStyle(.link)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(Color(nsColor: .controlBackgroundColor))
  }
}

private struct PlaceCell: View {
  let place: Place
  let thumbnailURL: URL?
  let onOpen: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      PhotoThumbnailView(url: thumbnailURL, side: 132)
      Text(place.name)
        .font(.body)
        .lineLimit(2)
        .multilineTextAlignment(.leading)
      if !place.description.isEmpty {
        Text(place.description)
          .font(.caption)
          .foregroundColor(.secondary)
          .lineLimit(1)
      }
    }
    .frame(width: 132, alignment: .leading)
    .contentShape(Rectangle())
    .onTapGesture(perform: onOpen)
    .help(place.description.isEmpty ? place.name : "\(place.name)\n\(place.description)")
  }
}

struct PlaceInspectorView: View {
  let place: Place
  let path: [Place]
  let photoURL: URL?
  let onEdit: () -> Void
  let onDelete: () -> Void
  let onClose: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Text(L10n.string("places.details"))
            .font(.headline)
          Spacer()
          Button {
            onClose()
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundColor(.secondary)
          }
          .buttonStyle(.plain)
          .help(L10n.string("common.close"))
        }

        PhotoThumbnailView(url: photoURL, side: 220)
          .frame(maxWidth: .infinity, alignment: .center)

        Text(place.name)
          .font(.title3)
          .fontWeight(.semibold)
          .textSelection(.enabled)

        if !place.description.isEmpty {
          Text(place.description)
            .foregroundColor(.secondary)
            .textSelection(.enabled)
        }

        Divider()

        detailRow(
          title: L10n.string("places.path"),
          value: path.isEmpty ? "—" : path.map(\.name).joined(separator: " / ")
        )
        detailRow(title: L10n.string("places.created"), value: format(place.createdAt))
        detailRow(title: L10n.string("places.updated"), value: format(place.updatedAt))

        Divider()

        HStack(spacing: 8) {
          Button(L10n.string("places.edit"), action: onEdit)
            .buttonStyle(.borderedProminent)
          Button(L10n.string("places.delete"), role: .destructive, action: onDelete)
            .buttonStyle(.bordered)
        }
      }
      .padding(16)
    }
  }

  private func detailRow(title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.caption)
        .foregroundColor(.secondary)
      Text(value)
        .font(.callout)
        .textSelection(.enabled)
    }
  }

  private func format(_ milliseconds: Int64) -> String {
    let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    return date.formatted(date: .abbreviated, time: .shortened)
  }
}
