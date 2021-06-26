// Copyright © 2021 Gwynne Raskind <gwynne@darkrainfall.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import struct Foundation.URL
import struct Foundation.URLResourceKey

import ArgumentParser

/// Simplistic wrapper for processing a file URL as an argument.
internal struct FileURL: ExpressibleByArgument {
  /// The file URL.
  public let url: URL

  /// See `ExpressibleByArgument.init?(argument:)`.
  public init?(argument: String) {
    self.url = .init(fileURLWithPath: argument)
  }

  /// A trivial existence check. Returns `false` on any error. Same caveats as
  /// `FileManager.fileExists(atPath:)`.
  // NOTE: this is not safe against TOCTOU
  public var existsOnDisk: Bool {
    return (try? self.url.checkResourceIsReachable()) ?? false
  }

  /// A trivial "is a directory" check. Returns `false` on any error, which is
  /// not terribly helpful.
  // NOTE: this is not safe against TOCTOU
  public var isDirectory: Bool {
    return (try? self.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
  }

  /// A trivial "is a plain file" check. Returns `false` on any error, which is
  /// not terribly helpful.
  // NOTE: this is not safe against TOCTOU
  public var isRegularFile: Bool {
    return (try? self.url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
  }
}
