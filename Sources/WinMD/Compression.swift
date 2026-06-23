// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension RawSpan {
  /// Decodes a compressed unsigned integer length prefix (ECMA-335 §II.23.2).
  ///
  /// The leading bits of the first byte — i.e. its value range — select a 1-,
  /// 2-, or 4-byte encoding. Returns the offset at which the payload begins and
  /// its length in bytes.
  internal func compressed(at offset: Int) -> (begin: Int, length: Int) {
    let first = read(at: offset, as: UInt8.self)
    let width = (~first).leadingZeroBitCount        // 0, 1, 2 → 1/2/4 bytes
    guard width < 3 else { fatalError("invalid compressed integer") }

    let count = 1 << width
    var value = Int(first & (0x7f >> width))
    for i in 1 ..< count {
      value = value << 8 | Int(read(at: offset + i, as: UInt8.self))
    }
    return (offset + count, value)
  }
}
