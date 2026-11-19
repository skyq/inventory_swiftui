import Foundation

public struct Place: Sendable, Equatable, Identifiable {
  public let id: String
  public let parentId: String?
  public let name: String
  public let description: String
  /// Относительный путь `photos/<uuid>.jpg`; nil — фото нет.
  public let photoFile: String?
  /// Относительный путь `thumbs/<uuid>.jpg`; nil — фото нет.
  public let thumbFile: String?
  public let createdAt: Int64
  public let updatedAt: Int64

  public init(
    id: String,
    parentId: String?,
    name: String,
    description: String,
    photoFile: String?,
    thumbFile: String?,
    createdAt: Int64,
    updatedAt: Int64
  ) {
    self.id = id
    self.parentId = parentId
    self.name = name
    self.description = description
    self.photoFile = photoFile
    self.thumbFile = thumbFile
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct PlacePath: Sendable, Equatable {
  /// От корня к элементу, последний — сам элемент.
  public let segments: [Place]

  public init(segments: [Place]) {
    self.segments = segments
  }

  public var display: String {
    segments.map(\.name).joined(separator: " / ")
  }
}

public struct PlaceCreate: Sendable {
  public let name: String
  public let description: String
  public let parentId: String?
  /// Фото обязательно при создании места (ТЗ §6.1).
  public let photo: ProcessedPhoto?

  public init(name: String, description: String, parentId: String?, photo: ProcessedPhoto?) {
    self.name = name
    self.description = description
    self.parentId = parentId
    self.photo = photo
  }
}

public struct PlaceDetailsUpdate: Sendable {
  public let id: String
  public let name: String
  public let description: String
  /// Итоговый родитель; nil — корень.
  public let parentId: String?
  /// nil — оставить текущее фото.
  public let newPhoto: ProcessedPhoto?

  public init(
    id: String,
    name: String,
    description: String,
    parentId: String?,
    newPhoto: ProcessedPhoto?
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.parentId = parentId
    self.newPhoto = newPhoto
  }
}
