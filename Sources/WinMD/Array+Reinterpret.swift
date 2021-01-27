/**
 * Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>
 * All rights reserved.
 *
 * SPDX-License-Identifier: BSD-3-Clause
 **/

import Foundation

extension Collection where Element == UInt8 {
  /// Unsafely reinterprets the individual bytes of the collection, starting at a specific byte offset, as being of type
  /// `T` and returns the resulting instance. `T` pretty much has to be a value type for this to have any chance of
  /// working right.
  internal subscript<T>(offset offset: Self.Index, unsafelyCastTo _: T.Type = T.self) -> T {
    get { self.unsafeCastRead(T.self, offset: offset) }
  }

  /// Same as the `subscript(offset:unsafelyCastTo:)` accessor above, but rather than a byte offset, the index is
  /// interpreted as "the `index`th value of type `T`". In other words, if `T` is a 3-byte type, index 0 reads from byte
  /// offset 0, index 1 reads from byte offset 3, index 2 reads from byte offset 6, and so on.
  internal subscript<T>(unsafelyCasting index: Array<T>.Index, to _: T.Type = T.self) -> T {
    get { self[offset: self.index(self.startIndex, offsetBy: MemoryLayout<T>.stride * index), unsafelyCastTo: T.self] }
  }
}

extension MutableCollection where Element == UInt8 {
  /// Same as `Collection.subscript(offset:unsafelyCastTo:)`, except that it can also overwrite the appropriate number
  /// of bytes at the given offset with the raw bytes of the provided value. It is the caller's responsibility to make
  /// sure the collection has at least `MemoryLayout<T>.size` bytes starting at the given `offset`.
  internal subscript<T>(offset offset: Self.Index, unsafelyCastTo _: T.Type = T.self) -> T {
    get { self.unsafeCastRead(T.self, offset: offset) }
    set { self.unsafeCastWrite(value: newValue, offset: offset) }
  }

  /// Same as `Collection.subscript(_:unsafelyCastTo:)`, but also provides the setter. The same semantics apply to this
  /// setter as to the `offset`-based version above.
  internal subscript<T>(unsafelyCasting index: Array<T>.Index, to _: T.Type = T.self) -> T {
    get { self[offset: self.index(self.startIndex, offsetBy: MemoryLayout<T>.stride * index), unsafelyCastTo: T.self] }
    set { self[offset: self.index(self.startIndex, offsetBy: MemoryLayout<T>.stride * index), unsafelyCastTo: T.self] = newValue }
  }
}

// TODO: Specializations for `Array` and `ContiguousArray` that don't bother with the "if available" check on storage.
// TODO: Specialization for `RangeReplaceableCollection` which does the entire range of bytes in the setter at once.
// TODO: `RangeExpression`-taking versions of the indexing subscripts.

extension Collection where Element == UInt8 {
  /// A private utility method so `Collection` and `MutableCollection` don't have to have duplicate getters.
  ///
  /// - Note: This weird mess of an implementation happens because only `Array` and `ContiguousArray` have direct
  ///   underlying storage accessor methods; generic `Collection`s have no requirement that their data is contiguous in
  ///   memory; at most you can ask "do you have contiguous data?" and get an unsafe pointer to it if so. In case it
  ///   doesn't (and it does happen!) the slow/expensive path copies the appropriate slice of `self` to an `Array` and
  ///   performs the cast on that.
  fileprivate func unsafeCastRead<T>(_: T.Type, offset: Self.Index) -> T {
    return
      self[offset...].withContiguousStorageIfAvailable { $0.withMemoryRebound(to: T.self) { $0[0] } }
      ??
      Array(self[offset..<self.index(offset, offsetBy: MemoryLayout<T>.stride)])
        .withUnsafeBufferPointer { $0.withMemoryRebound(to: T.self) { $0[0] } }
  }
}

extension MutableCollection where Element == UInt8 {
  /// The setter counterpart to `unsafeCaseRead(_:offset:)` above. This doesn't really need to be separate, but we do so
  /// anyway for symmetry's sake.
  fileprivate mutating func unsafeCastWrite<T>(value: T, offset: Self.Index) {
    withUnsafeBytes(of: value) {
      $0.enumerated().forEach { n, byte in self[self.index(offset, offsetBy: n)] = byte }
    }
  }
}
