/**
 * Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>
 * All rights reserved.
 *
 * SPDX-License-Identifier: BSD-3-Clause
 **/

import ArgumentParser
import WinMD

@main
struct Inspect: ParsableCommand {
  @Argument
  var database: FileURL

  func validate() throws {
    guard self.database.existsOnDisk && self.database.isRegularFile else {
      throw ValidationError("Database must be an existing file.")
    }
  }

  func run() throws {
    // "C:\\Windows\\System32\\WinMetadata\\Windows.Foundation.winmd"
    print("Database: \(self.database.url.path)")
    if let database = try? WinMD.Database(at: self.database.url) {
      database.dump()
    }
  }
}
