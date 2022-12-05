// Copyright © 2022 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

internal struct AssemblyVersion {
  let MajorVersion: UInt16
  let MinorVersion: UInt16
  let BuildNumber: UInt16
  let RevisionNumber: UInt16

  internal init(_ major: UInt16, _ minor: UInt16, _ build: UInt16,
                _ patch: UInt16) {
    self.MajorVersion = major
    self.MinorVersion = minor
    self.BuildNumber = build
    self.RevisionNumber = patch
  }

  internal init(_ value: UInt64) {
    self.MajorVersion = UInt16((value >>  0) & 0xffff)
    self.MinorVersion = UInt16((value >> 16) & 0xffff)
    self.BuildNumber = UInt16((value >> 32) & 0xffff)
    self.RevisionNumber = UInt16((value >> 48) & 0xffff)
  }
}

extension AssemblyVersion: CustomStringConvertible {
  internal var description: String {
    "\(MajorVersion).\(MinorVersion).\(BuildNumber).\(RevisionNumber)"
  }
}
