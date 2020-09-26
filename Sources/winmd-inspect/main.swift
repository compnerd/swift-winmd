/**
 * Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>
 * All rights reserved.
 *
 * SPDX-License-Identifier: BSD-3-Clause
 **/

import ArgumentParser
import WinMD

struct Inspect: ParsableCommand {
  @Argument
  var database: String

  func run() throws {
    // "C:\\Windows\\System32\\WinMetadata\\Windows.Foundation.winmd"
    print("inspect: \(self.database)")
    if let database = try? WinMD.Database(atPath: self.database) {
      database.dump()
    }
  }
}

Inspect.main()
