// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import struct Foundation.UUID
import typealias Foundation.uuid_t

// MARK: - Decoding

/// A cursor decoding a custom-attribute `Value` blob (ECMA-335 §II.23.3).
///
/// A custom-attribute value opens with a `0x0001` prolog, then the
/// constructor's fixed arguments serialised in declaration order, then any
/// named arguments. This cursor reads the leaves the `[Guid(...)]` constructor
/// needs — the fixed-size integers spelling a GUID — mirroring
/// `SignatureDecoder`'s shape: it borrows the blob's bytes and advances a
/// position, and is `~Escapable` because it holds a `RawSpan`. Only the GUID
/// path is decoded today; the general §II.23.3 grammar can extend this later.
internal struct AttributeDecoder: ~Escapable {
  private let bytes: RawSpan
  private var position: Int

  @_lifetime(copy bytes)
  internal init(_ bytes: RawSpan) {
    self.bytes = bytes
    self.position = 0
  }

  /// Reads a little-endian fixed-width value and advances past it.
  private mutating func read<T: BitwiseCopyable>(as _: T.Type = T.self)
      throws(WinMDError) -> T {
    let width = MemoryLayout<T>.size
    guard position + width <= bytes.byteCount else { throw .BadImageFormat }
    let value = bytes.read(at: position, as: T.self)
    position = position + width
    return value
  }

  /// Reads the fixed `0x0001` prolog and advances past it.
  private mutating func prolog() throws(WinMDError) {
    guard try read(as: UInt16.self) == 0x0001 else { throw .BadImageFormat }
  }

  /// Decodes a `GuidAttribute` value: the prolog, then the GUID as the
  /// constructor serialises it — `u32, u16, u16, u8×8` (ECMA-335 §II.23.3).
  ///
  /// The constructor serialises `data1`/`data2`/`data3` little-endian, but a
  /// COM GUID's canonical spelling shows those three fields big-endian — which
  /// is exactly the byte order `UUID` stores. Swap the integer fields to
  /// big-endian and carry `data4` in order so `description` renders the
  /// canonical `[Guid(...)]` form.
  internal mutating func guid() throws(WinMDError) -> UUID {
    try prolog()
    let data1: UInt32 = try read()
    let data2: UInt16 = try read()
    let data3: UInt16 = try read()
    let uuid: uuid_t = try (
      UInt8(truncatingIfNeeded: data1 >> 24),
      UInt8(truncatingIfNeeded: data1 >> 16),
      UInt8(truncatingIfNeeded: data1 >> 8),
      UInt8(truncatingIfNeeded: data1),
      UInt8(truncatingIfNeeded: data2 >> 8),
      UInt8(truncatingIfNeeded: data2),
      UInt8(truncatingIfNeeded: data3 >> 8),
      UInt8(truncatingIfNeeded: data3),
      read(), read(), read(), read(),
      read(), read(), read(), read())
    let value = UUID(uuid: uuid)
    guard try read(as: UInt16.self) == 0 else { throw .BadImageFormat }
    guard position == bytes.byteCount else { throw .BadImageFormat }
    return value
  }
}

// MARK: - GuidAttribute value

/// The UUID a `GuidAttribute` `CustomAttribute` value blob names, decoding the
/// raw `bytes` as an ECMA-335 §II.23.3 `GuidAttribute` value.
///
/// This is the escapable, value → value form of `Tuple.iid(_:)`: a caller that
/// has already copied a `CustomAttribute.Value` blob out of the borrowed scan
/// (the SQL adapter's `.blob` cell) decodes it here, without a `Tuple`. A blob
/// that is not a GUID-shaped `GuidAttribute` value throws.
public func iid(decoding bytes: Array<UInt8>) throws(WinMDError) -> UUID {
  var decoder = AttributeDecoder(bytes.span.bytes)
  return try decoder.guid()
}

extension Tuple {
  /// The UUID a `GuidAttribute` `CustomAttribute` row's `Value` blob names, by
  /// decoding the `#Blob` heap cell at `column` as an ECMA-335 §II.23.3
  /// `GuidAttribute` value.
  ///
  /// A `Row`/`Tuple` is a borrowed view that cannot escape the scan, so the
  /// blob's bytes are copied out and run through `AttributeDecoder` after. This
  /// is the codec the SQL adapter's `guid` virtual column on `CustomAttribute`
  /// reads (mapping a failure to SQL `NULL`); `Row<TypeDef>.iid` performs the
  /// equivalent decode inline as it navigates to the attribute. A malformed
  /// `Value` blob throws.
  public func iid(_ column: Int) throws(WinMDError) -> UUID {
    let blob = try blob(column)
    var bytes = Array<UInt8>()
    bytes.reserveCapacity(blob.count)
    for i in 0 ..< blob.count {
      bytes.append(blob.load(at: i, as: UInt8.self))
    }
    return try WinMD.iid(decoding: bytes)
  }
}
