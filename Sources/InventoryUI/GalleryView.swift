#if os(macOS)
  import InventoryCore
  import SwiftUI

  struct GalleryWorkspaceView: View {
    @ObservedObject var model: GalleryModel
    let onAddItem: () -> Void
    let onEditItem: (ItemDetails) -> Void
    let onChangeStatus: (ItemDetails) -> Void
    let onGive: (ItemDetails) -> Void
    let onReturn: (ItemDetails) -> Void
    let onOpenPlace: (String) -> Void
    let onOpenPerson: (String) -> Void

    var body: some View {
      HSplitView {
        VStack(spacing: 0) {
          header
          Divider()
          if let error = model.loadError {
            errorBanner(error)
            Divider()
          }
          content
        }
        .frame(minWidth: 420, maxWidth: .infinity)

        if model.showsInspector, let details = model.selected {
          ItemInspectorView(
            details: details,
            photoURL: model.photoURL(for: details),
            history: model.selectedHistory,
            onEdit: { onEditItem(details) },
            onChangeStatus: { onChangeStatus(details) },
            onGive: { onGive(details) },
            onReturn: { onReturn(details) },
            onOpenPlace: onOpenPlace,
            onOpenPerson: onOpenPerson,
            onClose: { model.clearSelection() }
          )
          .frame(minWidth: 260, idealWidth: 320, maxWidth: 460)
        }
      }
      .alert(
        L10n.string("common.error"),
        isPresented: Binding(
          get: { model.alertMessage != nil },
          set: { presented in
            if !presented { model.alertMessage = nil }
          }
        )
      ) {
        Button(L10n.string("common.ok"), role: .cancel) {
          model.alertMessage = nil
        }
      } message: {
        Text(model.alertMessage ?? "")
      }
    }

    private var header: some View {
      HStack(spacing: 10) {
        Text(
          model.isSearchActive
            ? L10n.format("search.count", model.entries.count)
            : L10n.format("gallery.count", model.entries.count)
        )
        .font(.callout)
        .foregroundColor(.secondary)

        Spacer(minLength: 8)

        Menu {
          ForEach(GalleryTileSize.allCases, id: \.self) { size in
            Button {
              model.setTileSize(size)
            } label: {
              if model.state.tileSize == size {
                Label(tileSizeTitle(size), systemImage: "checkmark")
              } else {
                Text(tileSizeTitle(size))
              }
            }
          }
        } label: {
          Image(systemName: "square.grid.3x3")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L10n.string("gallery.tileSize"))

        Menu {
          ForEach(GallerySort.allCases, id: \.self) { sort in
            Button {
              Task { await model.setSort(sort) }
            } label: {
              if model.state.sort == sort {
                Label(sortTitle(sort), systemImage: "checkmark")
              } else {
                Text(sortTitle(sort))
              }
            }
          }
          Divider()
          ForEach(GalleryDirection.allCases, id: \.self) { direction in
            Button {
              Task { await model.setDirection(direction) }
            } label: {
              if model.state.direction == direction {
                Label(directionTitle(direction), systemImage: "checkmark")
              } else {
                Text(directionTitle(direction))
              }
            }
          }
        } label: {
          Image(systemName: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L10n.string("gallery.sort"))

        Button {
          GalleryFiltersWindow.toggle(model: model)
        } label: {
          Image(
            systemName: model.hasActiveFilters
              ? "line.3.horizontal.decrease.circle.fill"
              : "line.3.horizontal.decrease.circle"
          )
        }
        .buttonStyle(.borderless)
        .help(L10n.string("gallery.filters"))

        if model.hasActiveFilters {
          Button(L10n.string("gallery.filters.reset")) {
            Task { await model.resetFilters() }
          }
          .buttonStyle(.link)
        }

        Button {
          onAddItem()
        } label: {
          Label(L10n.string("items.add"), systemImage: "plus")
        }
        .buttonStyle(.bordered)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
      if model.isLoading && model.entries.isEmpty {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if model.entries.isEmpty {
        emptyState
      } else {
        ScrollView {
          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: model.state.tileSize.side), spacing: 16)],
            alignment: .leading,
            spacing: 18
          ) {
            ForEach(model.entries) { entry in
              ItemTile(
                entry: entry,
                thumbnailURL: model.thumbnailURL(for: entry),
                side: model.state.tileSize.side
              ) {
                Task { await model.select(entry) }
              }
            }
          }
          .padding(16)
        }
      }
    }

    private var emptyState: some View {
      VStack(spacing: 12) {
        Image(
          systemName: emptyStateSymbol
        )
        .font(.system(size: 40))
        .foregroundColor(.secondary)
        Text(
          L10n.string(emptyStateMessage)
        )
        .font(.title3)
        Text(
          L10n.string(emptyStateHint)
        )
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 380)

        if model.hasActiveFilters {
          Button(L10n.string("gallery.filters.reset")) {
            Task { await model.resetFilters() }
          }
        } else if !model.isSearchActive {
          Button {
            onAddItem()
          } label: {
            Label(L10n.string("items.add"), systemImage: "plus")
          }
          .buttonStyle(.borderedProminent)
          .padding(.top, 4)
        }
      }
      .padding(32)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateSymbol: String {
      if model.isSearchActive { return "magnifyingglass" }
      return model.hasActiveFilters
        ? "line.3.horizontal.decrease.circle" : "photo.on.rectangle.angled"
    }

    private var emptyStateMessage: String {
      if model.isSearchActive { return "search.noResults" }
      return model.hasActiveFilters ? "gallery.noMatches" : "gallery.empty"
    }

    private var emptyStateHint: String {
      if model.isSearchActive { return "search.noResultsHint" }
      return model.hasActiveFilters ? "gallery.noMatchesHint" : "gallery.emptyHint"
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

    private func tileSizeTitle(_ size: GalleryTileSize) -> String {
      switch size {
      case .small: return L10n.string("gallery.tileSize.small")
      case .medium: return L10n.string("gallery.tileSize.medium")
      case .large: return L10n.string("gallery.tileSize.large")
      }
    }

    private func sortTitle(_ sort: GallerySort) -> String {
      switch sort {
      case .createdAt: return L10n.string("gallery.sort.createdAt")
      case .name: return L10n.string("gallery.sort.name")
      }
    }

    private func directionTitle(_ direction: GalleryDirection) -> String {
      switch direction {
      case .asc: return L10n.string("gallery.sort.asc")
      case .desc: return L10n.string("gallery.sort.desc")
      }
    }
  }

  /// Общая плитка вещи: квадратное превью, название и метка статуса.
  struct ItemTile: View {
    let entry: GalleryEntry
    let thumbnailURL: URL?
    let side: CGFloat
    let onOpen: () -> Void

    var body: some View {
      VStack(alignment: .leading, spacing: 6) {
        PhotoThumbnailView(url: thumbnailURL, side: side)
        Text(entry.item.name)
          .font(.body)
          .lineLimit(2)
          .multilineTextAlignment(.leading)
        Text(statusLabel)
          .font(.caption2)
          .foregroundColor(.secondary)
          .lineLimit(1)
      }
      .frame(width: side, alignment: .leading)
      .contentShape(Rectangle())
      .onTapGesture(perform: onOpen)
      .help("\(entry.item.name)\n\(statusLabel)")
    }

    private var statusLabel: String {
      entry.statusArchived
        ? "\(entry.statusName) (\(L10n.string("gallery.archived")))"
        : entry.statusName
    }
  }
#endif
