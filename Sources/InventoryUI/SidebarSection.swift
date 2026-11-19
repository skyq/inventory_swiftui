import Foundation

public enum SidebarSection: String, CaseIterable, Identifiable, Sendable {
  case gallery
  case places
  case people
  case statuses
  case tags
  case data

  public var id: String { rawValue }

  public var titleKey: String { "sidebar.\(rawValue)" }

  public var systemImage: String {
    switch self {
    case .gallery: return "photo.on.rectangle.angled"
    case .places: return "folder"
    case .people: return "person.2"
    case .statuses: return "checkmark.circle"
    case .tags: return "tag"
    case .data: return "externaldrive"
    }
  }
}
