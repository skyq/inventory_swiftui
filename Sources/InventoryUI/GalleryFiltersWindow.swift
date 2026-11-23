import AppKit
import SwiftUI

/// Отдельное окно фильтров галереи. Popover на macOS нельзя растянуть,
/// поэтому фильтры живут в обычном изменяемом окне.
@MainActor
enum GalleryFiltersWindow {
  private static var window: NSWindow?
  private static weak var model: GalleryModel?

  static func toggle(model: GalleryModel) {
    if let window, self.model === model {
      if window.isVisible {
        window.close()
      } else {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
      }
      return
    }
    window?.close()
    let created = makeWindow(model: model)
    window = created
    self.model = model
    created.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private static func makeWindow(model: GalleryModel) -> NSWindow {
    let hosting = NSHostingController(rootView: GalleryFiltersView(model: model))
    let window = NSWindow(contentViewController: hosting)
    window.title = L10n.string("gallery.filters")
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 320, height: 420)
    window.setContentSize(NSSize(width: 360, height: 560))
    if !window.setFrameUsingName("GalleryFiltersWindow") {
      window.center()
    }
    window.setFrameAutosaveName("GalleryFiltersWindow")
    return window
  }
}
