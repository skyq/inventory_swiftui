#if os(macOS)
  import AppKit
  import SwiftUI

  /// Нативное поле поиска AppKit: нужно для Cmd+K и постоянного места в тулбаре.
  struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var focusToken: Int

    func makeCoordinator() -> Coordinator {
      Coordinator(self)
    }

    func makeNSView(context: Context) -> NSSearchField {
      let field = NSSearchField()
      field.placeholderString = L10n.string("search.placeholder")
      field.delegate = context.coordinator
      field.sendsSearchStringImmediately = true
      field.controlSize = .regular
      return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
      context.coordinator.parent = self
      if field.stringValue != text {
        field.stringValue = text
      }
      if context.coordinator.lastFocusToken != focusToken {
        context.coordinator.lastFocusToken = focusToken
        DispatchQueue.main.async {
          field.window?.makeFirstResponder(field)
        }
      }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
      var parent: SearchField
      var lastFocusToken = 0

      init(_ parent: SearchField) {
        self.parent = parent
      }

      func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField else { return }
        parent.text = field.stringValue
      }
    }
  }

  /// Превью фото из папки данных. Чтение и декодирование — вне главного потока.
  struct PhotoThumbnailView: View {
    let url: URL?
    let side: CGFloat

    @State private var image: NSImage?

    var body: some View {
      ZStack {
        if let image {
          Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
        } else {
          Rectangle()
            .fill(Color(nsColor: .quaternaryLabelColor))
            .overlay {
              Image(systemName: "photo")
                .font(.system(size: max(14, side / 5)))
                .foregroundColor(.secondary)
            }
        }
      }
      .frame(width: side, height: side)
      .clipped()
      .cornerRadius(5)
      .task(id: url) {
        image = nil
        guard let url else { return }
        let data = try? await Task.detached(
          priority: .utility,
          operation: {
            try Data(contentsOf: url)
          }
        ).value
        if let data {
          image = NSImage(data: data)
        }
      }
    }
  }

  /// Полное фото без обрезки: используется в карточке вещи.
  struct PhotoFitView: View {
    let url: URL?

    @State private var image: NSImage?

    var body: some View {
      ZStack {
        RoundedRectangle(cornerRadius: 6)
          .fill(Color(nsColor: .quaternaryLabelColor))
        if let image {
          Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .padding(4)
        } else {
          Image(systemName: "photo")
            .font(.system(size: 34))
            .foregroundColor(.secondary)
        }
      }
      .frame(maxWidth: .infinity)
      .frame(height: 240)
      .clipShape(RoundedRectangle(cornerRadius: 6))
      .task(id: url) {
        image = nil
        guard let url else { return }
        let data = try? await Task.detached(
          priority: .utility,
          operation: {
            try Data(contentsOf: url)
          }
        ).value
        if let data {
          image = NSImage(data: data)
        }
      }
    }
  }
#endif
