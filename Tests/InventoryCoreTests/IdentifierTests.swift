import Foundation
import Testing

@testable import InventoryCore

struct FixedClock: Clock {
  let value: Int64
  func nowMilliseconds() -> Int64 { value }
}

struct SequenceIdGenerator: IdGenerator {
  let ids: [String]
  private let counter = Counter()

  func next() -> String {
    ids[counter.advance() % ids.count]
  }

  private final class Counter: @unchecked Sendable {
    private var value = 0
    func advance() -> Int {
      defer { value += 1 }
      return value
    }
  }
}

@Suite("Clock и IdGenerator")
struct IdentifierTests {
  @Test("FixedClock отдаёт значение, переданное в тест")
  func fixedClockReturnsInjectedTime() {
    let clock: any Clock = FixedClock(value: 1_700_000_000_000)
    #expect(clock.nowMilliseconds() == 1_700_000_000_000)
  }

  @Test("SequenceIdGenerator отдаёт идентификаторы по порядку")
  func sequenceGeneratorIsDeterministic() {
    let ids: any IdGenerator = SequenceIdGenerator(ids: ["a", "b"])
    #expect(ids.next() == "a")
    #expect(ids.next() == "b")
    #expect(ids.next() == "a")
  }
}
