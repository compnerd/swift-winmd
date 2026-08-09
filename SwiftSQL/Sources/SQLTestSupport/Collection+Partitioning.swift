// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Collection {
  /// The partition point of a collection already partitioned by `predicate` —
  /// the first index whose element satisfies it, or `endIndex` if none does.
  ///
  /// This is the standard `lower_bound` primitive: given a collection whose
  /// elements are ordered so that every element failing the predicate precedes
  /// every element satisfying it, a binary search reports the boundary between
  /// the two runs in `O(log n)` comparisons.
  func partitioning(by predicate: (Element) -> Bool) -> Index {
    var lower = startIndex
    var span = count
    while span > 0 {
      let half = span / 2
      let middle = index(lower, offsetBy: half)
      if predicate(self[middle]) {
        span = half
      } else {
        lower = index(after: middle)
        span -= half + 1
      }
    }
    return lower
  }
}
