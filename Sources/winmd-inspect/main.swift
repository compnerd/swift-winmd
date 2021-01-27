/**
 * Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>
 * All rights reserved.
 *
 * SPDX-License-Identifier: BSD-3-Clause
 **/

import struct Foundation.URL
import struct Foundation.URLResourceKey
import ArgumentParser
import WinMD

/// A very quick and simplistic implementation of parsing a string argument as a file URL.
public struct FileURL: ExpressibleByArgument {
    /// The actual URL.
    public let url: URL
    
    /// See `ExpressibleByArgument.init?(argument:)`.
    public init?(argument: String) {
        self.url = .init(fileURLWithPath: argument)
    }
    
    /// A trivial "does exist" check. Returns `false` on any error. Same caveats as `FileManager.fileExists(atPath:)`.
    public var existsOnDiskRightNow: Bool {
        return (try? self.url.checkResourceIsReachable()) ?? false
    }
    
    /// A trivial "is a directory" check. Returns `false` on any error, which is not terribly helpful.
    public var isDirectoryRightNow: Bool {
        return (try? self.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    /// A trivial "is a plain file" check. Returns `false` on any error, which is not terribly helpful.
    public var isRegularFileRightNow: Bool {
        return (try? self.url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
    }
}

struct Inspect: ParsableCommand {
  @Argument
  var database: FileURL

  func validate() throws {
    guard self.database.existsOnDiskRightNow && self.database.isRegularFileRightNow else {
      throw ValidationError("Database must be an existing file.")
    }
  }
    
  func run() throws {
    // "C:\\Windows\\System32\\WinMetadata\\Windows.Foundation.winmd"
    print("inspect: \(self.database)")
    if let database = try? WinMD.Database(at: self.database.url) {
      database.dump()
    }
  }
}

Inspect.main()
