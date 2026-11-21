import Foundation

public struct ChangeStatusCommand: Sendable, Equatable {
  public let itemId: String
  public let toStatusId: String
  public let comment: String

  public init(itemId: String, toStatusId: String, comment: String = "") {
    self.itemId = itemId
    self.toStatusId = toStatusId
    self.comment = comment
  }
}

/// Человек для передачи: существующий либо создаваемый в той же транзакции (D08).
public enum PersonChoice: Sendable, Equatable {
  case existing(id: String)
  case new(name: String, phone: String, notes: String, duplicateConfirmed: Bool)
}

public struct GiveCommand: Sendable, Equatable {
  public let itemId: String
  public let person: PersonChoice
  public let comment: String
  /// Включённый флажок при уже текущем статусе не создаёт запись истории (D02).
  public let changeStatus: Bool
  /// nil при включённом флажке — взять transfer_status_id из settings.
  public let statusId: String?
  public let clearPlace: Bool

  public init(
    itemId: String,
    person: PersonChoice,
    comment: String = "",
    changeStatus: Bool = true,
    statusId: String? = nil,
    clearPlace: Bool = true
  ) {
    self.itemId = itemId
    self.person = person
    self.comment = comment
    self.changeStatus = changeStatus
    self.statusId = statusId
    self.clearPlace = clearPlace
  }
}

/// D04: «оставить текущее» и «без места» — разные намерения.
public enum ReturnPlaceChange: Sendable, Equatable {
  case keep
  case clear
  case place(String)
}

public struct ReturnCommand: Sendable, Equatable {
  public let itemId: String
  public let personId: String
  public let comment: String
  /// nil — оставить текущий статус без записи истории.
  public let statusId: String?
  public let place: ReturnPlaceChange

  public init(
    itemId: String,
    personId: String,
    comment: String = "",
    statusId: String? = nil,
    place: ReturnPlaceChange = .keep
  ) {
    self.itemId = itemId
    self.personId = personId
    self.comment = comment
    self.statusId = statusId
    self.place = place
  }
}

public protocol ItemActions: Sendable {
  func changeStatus(_ command: ChangeStatusCommand) throws -> ItemDetails
  /// Передача, необязательная смена статуса и снятие места — одной транзакцией.
  func give(_ command: GiveCommand) throws -> ItemDetails
  /// Возврат, необязательная смена статуса и места — одной транзакцией.
  func returnItem(_ command: ReturnCommand) throws -> ItemDetails
}
