// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing

@testable import winmd_inspect

import SQLEngine

private struct Display: Sendable, CustomTestStringConvertible {
  internal let value: Value
  internal let expected: String

  internal var testDescription: String { expected }
}

private let kBooleans: Array<Display> = [
  Display(value: .boolean(true), expected: "TRUE"),
  Display(value: .boolean(false), expected: "FALSE"),
]

private let kDoubles: Array<Display> = [
  Display(value: .double(3.14), expected: "3.14"),
  Display(value: .double(2.5), expected: "2.5"),
  Display(value: .double(1.0), expected: "1.0"),
  Display(value: .double(1000.0), expected: "1000.0"),
]

private let kBlobs: Array<Display> = [
  Display(value: .blob([0x53, 0x51, 0x4c]), expected: "x'53514c'"),
  Display(value: .blob([0x00, 0x0f, 0xab, 0xff]), expected: "x'000fabff'"),
  Display(value: .blob([]), expected: "x''"),
]

// MARK: - Boolean

@Suite
private struct BooleanDisplayTests {
  @Test(arguments: kBooleans)
  fileprivate func renders(_ test: Display) {
    #expect(test.value.display == test.expected)
  }
}

// MARK: - Double

@Suite
private struct DoubleDisplayTests {
  @Test(arguments: kDoubles)
  fileprivate func renders(_ test: Display) {
    #expect(test.value.display == test.expected)
  }
}

// MARK: - Blob

@Suite
private struct BlobDisplayTests {
  @Test(arguments: kBlobs)
  fileprivate func renders(_ test: Display) {
    #expect(test.value.display == test.expected)
  }
}
