// Timing + memory measurement support for the benchmark.

import Darwin

// MARK: - Dead-code-elimination defeat

/// A sink that folds a value's bytes into a running hash so the optimizer
/// cannot elide the work that produced it. `@inline(never)` + the global keep
/// the accumulation observable across the whole run.
nonisolated(unsafe) var blackHoleAccumulator: UInt64 = 0xcbf29ce484222325

@inline(never)
func blackHole(_ byte: UInt8) {
  blackHoleAccumulator =
      (blackHoleAccumulator ^ UInt64(byte)) &* 0x100000001b3
}

@inline(never)
func blackHole(_ bytes: Array<UInt8>) {
  var h = blackHoleAccumulator
  for b in bytes { h = (h ^ UInt64(b)) &* 0x100000001b3 }
  blackHoleAccumulator = h
}

// MARK: - Monotonic timing

/// Runs `body` `iterations` times after `warmup` discarded iterations and
/// returns the per-iteration wall times in nanoseconds. Uses the monotonic
/// `ContinuousClock`.
func measure(warmup: Int, iterations: Int,
             _ body: () -> Void) -> Array<Double> {
  for _ in 0 ..< warmup { body() }
  let clock = ContinuousClock()
  var samples = Array<Double>()
  samples.reserveCapacity(iterations)
  for _ in 0 ..< iterations {
    let start = clock.now
    body()
    let elapsed = clock.now - start
    samples.append(Double(elapsed.components.attoseconds) / 1e9
                   + Double(elapsed.components.seconds) * 1e9)
  }
  return samples
}

struct Stats {
  var min: Double
  var median: Double
  var count: Int
}

func stats(_ samples: Array<Double>) -> Stats {
  let sorted = samples.sorted()
  let median = sorted[sorted.count / 2]
  return Stats(min: sorted.first!, median: median, count: sorted.count)
}

// MARK: - Memory measurement

/// Peak resident memory (bytes) of this task, from the kernel.
func peakResident() -> UInt64 {
  var info = mach_task_basic_info()
  var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size
                                     / MemoryLayout<natural_t>.size)
  let result = withUnsafeMutablePointer(to: &info) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
      task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO),
                $0, &count)
    }
  }
  return result == KERN_SUCCESS ? info.resident_size_max : 0
}

