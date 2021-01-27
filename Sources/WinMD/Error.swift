/**
 * Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>
 * All rights reserved.
 *
 * SPDX-License-Identifier: BSD-3-Clause
 **/

public enum WinMDError: Error {
  case BadImageFormat

  case invalidStream
  case tableNotFound
}
