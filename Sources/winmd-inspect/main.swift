/**
 * Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>
 * All rights reserved.
 *
 * SPDX-License-Identifier: BSD-3-Clause
 **/

import Foundation
import WinMD

if let database = try? WinMD.Database(atPath: "C:\\Windows\\System32\\WinMetadata\\Windows.Foundation.winmd") {
  database.dump()
}
