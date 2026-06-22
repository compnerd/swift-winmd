// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

internal import CPE

/// A borrowed view over a DOS/PE image.
///
/// Used transiently during database parsing. It operates on the whole-buffer
/// span; the MS-DOS stub begins at offset zero.
internal struct DOSFile: ~Escapable {
  internal let bytes: RawSpan

  @_lifetime(copy bytes)
  internal init(_ bytes: RawSpan) throws(WinMDError) {
    self.bytes = bytes

    // Must have enough data to even contain a DOS stub.
    guard bytes.byteCount >= MemoryLayout<IMAGE_DOS_HEADER>.size else {
      throw .BadImageFormat
    }

    // Bad signature? Not a DOS file.
    guard Header.e_magic == IMAGE_DOS_SIGNATURE else {
      throw .BadImageFormat
    }

    // The LFA of the PE signature (if there is one) must be within the file's
    // bounds.
    guard Header.e_lfanew < bytes.byteCount else {
      throw .BadImageFormat
    }
  }

  /// The raw MS-DOS stub image header.
  internal var Header: IMAGE_DOS_HEADER {
    bytes.load(at: 0, as: IMAGE_DOS_HEADER.self)
  }

  /// The absolute byte offset, within the buffer, of the contents following the
  /// MS-DOS stub. This unwraps the MS-DOS stub envelope on a PE/COFF file.
  internal var NewExecutable: Int {
    numericCast(Header.e_lfanew)
  }
}
