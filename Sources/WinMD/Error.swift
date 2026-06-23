// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

public enum WinMDError: Error {
  case BadImageFormat
  case BlobsHeapNotFound
  case GUIDHeapNotFound
  case InvalidColumn
  case InvalidIndex
  case MissingTableStream
  case StringsHeapNotFound
  case TableNotFound
  case UserStringsHeapNotFound
}
