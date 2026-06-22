// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension RawSpan {
  /// Reads a packed, possibly unaligned, value at a byte offset.
  ///
  /// The metadata fields are packed and therefore unaligned, so the value must
  /// be read with an unaligned load.
  internal func read<T: BitwiseCopyable>(at offset: Int,
                                         as _: T.Type = T.self) -> T {
    unsafeLoadUnaligned(fromByteOffset: offset, as: T.self)
  }

  /// Reads a packed, possibly unaligned, C structure at a byte offset.
  ///
  /// Imported C structures that contain anonymous unions are not
  /// `BitwiseCopyable`, so they cannot be read via `read(at:as:)`. They are
  /// nonetheless trivially copyable, so they can be loaded through a raw buffer
  /// pointer.
  internal func load<T>(at offset: Int, as _: T.Type = T.self) -> T {
    withUnsafeBytes {
      $0.loadUnaligned(fromByteOffset: offset, as: T.self)
    }
  }
}
