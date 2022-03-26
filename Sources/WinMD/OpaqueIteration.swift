
public struct AnyRecord {
  internal let row: [Int]
  internal let heaps: Database.Heaps
  internal let Table: Table.Type

  internal init(_ type: Table.Type, _ row: [Int], _ heaps: Database.Heaps) {
    self.row = row
    self.heaps = heaps
    self.Table = type
  }
}

extension AnyRecord: CustomDebugStringConvertible {
  public var debugDescription: String {
    return row.enumerated().map { (column, value) in
      switch Table.columns[column].type {
      case let .index(.heap(heap)) where heap == .string:
        return "\(Table.columns[column].name): \(heaps.string[value])"
      default:
        return "\(Table.columns[column].name): \(value)"
      }
    }.joined(separator: ", ")
  }
}

public struct AnyTableIterator: IteratorProtocol, Sequence {
  public typealias Element = AnyRecord

  private let table: Table
  private let decoder: DatabaseDecoder
  private let heaps: Database.Heaps
  private let Table: Table.Type

  private var cursor: Int

  public init(_ table: Table, _ decoder: DatabaseDecoder,
              _ heaps: Database.Heaps, from row: Int = 0) {
    self.table = table
    self.decoder = decoder
    self.heaps = heaps
    self.cursor = row
    self.Table = Swift.type(of: table)
  }

  /// See `IteratorProtocol.next`
  public mutating func next() -> Self.Element? {
    guard self.cursor < self.table.rows else { return nil }

    defer { self.cursor = self.cursor + 1}

    var scan: Int = 0
    let layout: [(Int, Int)] = Table.columns.map {
      let width = decoder.width(of: $0.type)
      defer { scan = scan + width }
      return (scan, width)
    }

    let begin: ArraySlice<UInt8>.Index =
        self.table.data.index(self.table.data.startIndex,
                              offsetBy: self.cursor * scan)
    let end: ArraySlice<UInt8>.Index =
        self.table.data.index(begin, offsetBy: scan)
    let data: ArraySlice<UInt8> = self.table.data[begin ..< end]

    let record: [Int] = layout.map { (offset, size) in
      switch size {
      case 1: return Int(data[offset, UInt8.self])
      case 2: return Int(data[offset, UInt16.self])
      case 4: return Int(data[offset, UInt32.self])
      default: fatalError("unsupported column size '\(size)'")
      }
    }

    return AnyRecord(Table, record, self.heaps)
  }
}
