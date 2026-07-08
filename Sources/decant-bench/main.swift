// DecantJSON vs Foundation Codable benchmark driver.
//
// Correctness first (round-trip + cross-codec JSON equivalence), then speed,
// then memory. Emits a Markdown-ish report to stdout.

import Foundation
import Decant
import DecantJSON

// MARK: - Subprocess memory-probe mode
//
// resident_size_max is a MONOTONE high-watermark on Darwin (it never falls when
// memory is freed), so the only rigorous way to attribute peak RSS to one codec
// is to run that codec — and nothing else heavy — in its own fresh process and
// read the watermark at exit. When invoked as `decant-bench mem <codec> <op>`
// the binary does exactly one codec's work over the large payload and prints
// its own peak RSS, then exits. The parent (normal mode) spawns these.

if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "mem" {
  let codec = CommandLine.arguments[2]   // "decant" | "codable"
  let op = CommandLine.arguments[3]      // "encode" | "decode"
  let n = 100_000
  let value = (0 ..< n).map { i in
    Small(a_id: Int32(i), b_x: Double(i) * 1.5, c_y: Double(i) * -2.25,
          d_active: i % 2 == 0, e_name: "item-\(i)")
  }
  let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
  let decantBytesIn = (try? DecantJSON.bytes(json: value)) ?? []
  let codableDataIn = Data(decantBytesIn)
  let baseline = Double(peakResident()) / 1_048_576.0
  switch (codec, op) {
  case ("decant", "encode"):
    let out = (try? DecantJSON.bytes(json: value)) ?? []
    withExtendedLifetime(out) { blackHole(out.last ?? 0) }
  case ("codable", "encode"):
    let out = (try? enc.encode(value)) ?? Data()
    withExtendedLifetime(out) { blackHole(out.last ?? 0) }
  case ("decant", "decode"):
    let v = try? DecantJSON.decode(Array<Small>.self, json: decantBytesIn)
    withExtendedLifetime(v) { blackHole(1) }
  case ("codable", "decode"):
    let v = try? JSONDecoder().decode(Array<Small>.self, from: codableDataIn)
    withExtendedLifetime(v) { blackHole(1) }
  default:
    break
  }
  let peak = Double(peakResident()) / 1_048_576.0
  // Report both the absolute peak and the climb over the baseline (which
  // already includes the input payload the op reads).
  print(String(format: "%.2f %.2f %llu", baseline, peak, blackHoleAccumulator))
  exit(0)
}

// MARK: - Fixture builders

func makeSmall(_ i: Int) -> Small {
  Small(a_id: Int32(i), b_x: Double(i) * 1.5, c_y: Double(i) * -2.25,
        d_active: i % 2 == 0, e_name: "item-\(i)")
}

func makeSmallArray(_ n: Int) -> Array<Small> {
  (0 ..< n).map(makeSmall)
}

let cleanDocument = Document(
  a_author: "A. N. Author, Department of Long Prose",
  b_body: String(repeating:
      "Lorem ipsum dolor sit amet consectetur adipiscing elit. ", count: 200),
  c_title: "The quick brown fox jumps over the lazy dog")

let escapedDocument = EscapedDocument(
  a_author: "Name with \"quotes\"\nand newline",
  b_body: String(repeating:
      "He said \"hello\",\n\tthen left.\r\nControl \u{01} here. ", count: 200),
  c_title: "Line one\nLine two\twith \"quotes\" and a backslash \\")

let numbers = Numbers(a: 9_223_372_036_854_775_807, b: -4_242_424_242,
                      c: 1_000_000, d: 3.141592653589793,
                      e: -2.718281828459045, f: 1.0e-9,
                      g: -2_147_483_648, h: 4_294_967_295)

func makeTree(branches: Int, leavesPer: Int) -> Tree {
  var bs = Array<Branch>()
  for b in 0 ..< branches {
    var ls = Array<Leaf>()
    for l in 0 ..< leavesPer {
      ls.append(Leaf(a_tag: "leaf-\(b)-\(l)", b_value: Int32(b * 1000 + l)))
    }
    bs.append(Branch(a_leaves: ls, b_name: "branch-\(b)",
                     c_weight: Double(b) * 0.5))
  }
  return Tree(a_branches: bs, b_root: "root", c_version: 3)
}

// MARK: - Foundation configuration
//
// Match DecantJSON's output as closely as possible: no pretty printing, no
// sorted keys (both emit declaration order), no extra escaping.

let jsonEncoder = JSONEncoder()
jsonEncoder.outputFormatting = .sortedKeys
let jsonDecoder = JSONDecoder()

// MARK: - Correctness harness

func check<T: Codable & Equatable & Serializable & Deserializable>(
    _ label: String, _ value: T) -> Bool {
  do {
    // Decant round-trip.
    let decantBytes = try DecantJSON.bytes(json: value)
    let decantBack: T = try DecantJSON.decode(T.self, json: decantBytes)
    guard decantBack == value else {
      print("  FAIL [\(label)] Decant round-trip mismatch"); return false
    }
    // Codable round-trip.
    let codableBytes = Array(try jsonEncoder.encode(value))
    let codableBack = try jsonDecoder.decode(T.self, from: Data(codableBytes))
    guard codableBack == value else {
      print("  FAIL [\(label)] Codable round-trip mismatch"); return false
    }
    // Cross-codec: Codable can decode Decant's output, and vice-versa.
    let crossA = try jsonDecoder.decode(T.self, from: Data(decantBytes))
    let crossB: T = try DecantJSON.decode(T.self, json: codableBytes)
    guard crossA == value, crossB == value else {
      print("  FAIL [\(label)] cross-codec mismatch"); return false
    }
    let identical = decantBytes == codableBytes
    print("  ok   [\(label)] decant=\(decantBytes.count)B codable=\(codableBytes.count)B bytes-identical=\(identical)")
    return true
  } catch {
    print("  FAIL [\(label)] threw: \(error)"); return false
  }
}

print("## Correctness (round-trip + cross-codec)")
var correctnessFailures = 0
if !check("Small", makeSmall(7)) { correctnessFailures += 1 }
if !check("Array<Small> x100", makeSmallArray(100)) { correctnessFailures += 1 }
if !check("Document(clean)", cleanDocument) { correctnessFailures += 1 }
if !check("EscapedDocument", escapedDocument) { correctnessFailures += 1 }
if !check("Numbers", numbers) { correctnessFailures += 1 }
if !check("Tree(10x10)", makeTree(branches: 10, leavesPer: 10)) { correctnessFailures += 1 }
if correctnessFailures > 0 {
  print("\nABORTING: \(correctnessFailures) correctness failure(s)")
  exit(1)
}
print("All correctness checks passed.\n")

// MARK: - Speed harness

struct SpeedRow {
  var label: String
  var bytes: Int
  var decantEncode: Stats
  var codableEncode: Stats
  var decantDecode: Stats
  var codableDecode: Stats
}

func benchmark<T: Codable & Serializable & Deserializable>(
    _ label: String, _ value: T, warmup: Int, iters: Int) -> SpeedRow {
  let decantBytes = (try? DecantJSON.bytes(json: value)) ?? []
  // Feed the SAME source bytes (Decant's output) to BOTH decoders, so the
  // decode comparison isn't skewed by any encoder formatting difference.
  let codableData = Data(decantBytes)
  let codableBytes = decantBytes

  let decantEncode = measure(warmup: warmup, iterations: iters) {
    let out = (try? DecantJSON.bytes(json: value)) ?? []
    blackHole(out.count == 0 ? 0 : out[out.count - 1])
  }
  let codableEncode = measure(warmup: warmup, iterations: iters) {
    let out = (try? jsonEncoder.encode(value)) ?? Data()
    blackHole(out.isEmpty ? 0 : out[out.count - 1])
  }
  let decantDecode = measure(warmup: warmup, iterations: iters) {
    if let v = try? DecantJSON.decode(T.self, json: decantBytes) {
      withExtendedLifetime(v) { blackHole(UInt8(truncatingIfNeeded: decantBytes.count)) }
    }
  }
  let codableDecode = measure(warmup: warmup, iterations: iters) {
    if let v = try? jsonDecoder.decode(T.self, from: codableData) {
      withExtendedLifetime(v) { blackHole(UInt8(truncatingIfNeeded: codableBytes.count)) }
    }
  }
  return SpeedRow(label: label, bytes: decantBytes.count,
                  decantEncode: stats(decantEncode),
                  codableEncode: stats(codableEncode),
                  decantDecode: stats(decantDecode),
                  codableDecode: stats(codableDecode))
}

// Scale iteration counts down as payloads grow so total run time stays sane.
func iters(for n: Int) -> (Int, Int) {
  switch n {
  case ..<50:      return (2000, 20000)
  case ..<5000:    return (500, 5000)
  case ..<50000:   return (50, 500)
  default:         return (10, 100)
  }
}

var rows = Array<SpeedRow>()

func fmt(_ ns: Double) -> String {
  if ns >= 1e6 { return String(format: "%.2f ms", ns / 1e6) }
  if ns >= 1e3 { return String(format: "%.2f µs", ns / 1e3) }
  return String(format: "%.0f ns", ns)
}

// Small flat struct.
do { let (w, i) = iters(for: 1); rows.append(benchmark("Small (1)", makeSmall(1), warmup: w, iters: i)) }

// Array sweep.
for n in [10, 100, 1_000, 10_000, 100_000] {
  let (w, i) = iters(for: n)
  rows.append(benchmark("Array<Small> (\(n))", makeSmallArray(n), warmup: w, iters: i))
}

// String-heavy.
do { let (w, i) = iters(for: 1); rows.append(benchmark("Document (clean str)", cleanDocument, warmup: w, iters: i)) }
do { let (w, i) = iters(for: 1); rows.append(benchmark("EscapedDocument (esc)", escapedDocument, warmup: w, iters: i)) }

// Number-heavy (as an array to amortize).
do { let (w, i) = iters(for: 1000); rows.append(benchmark("Array<Numbers> (1000)", (0..<1000).map { _ in numbers }, warmup: w, iters: i)) }

// Nested.
do { let (w, i) = iters(for: 100); rows.append(benchmark("Tree (50x50 leaves)", makeTree(branches: 50, leavesPer: 50), warmup: w, iters: i)) }

// MARK: - Speed report

print("## Speed (median | min per iteration; speedup = Codable / Decant, >1 = Decant faster)\n")
print("### Encode")
print("| case | bytes | Decant med | Decant min | Codable med | Codable min | speedup(med) |")
print("|---|--:|--:|--:|--:|--:|--:|")
for r in rows {
  let sp = r.codableEncode.median / r.decantEncode.median
  print("| \(r.label) | \(r.bytes) | \(fmt(r.decantEncode.median)) | \(fmt(r.decantEncode.min)) | \(fmt(r.codableEncode.median)) | \(fmt(r.codableEncode.min)) | \(String(format: "%.2f×", sp)) |")
}
print("\n### Decode")
print("| case | bytes | Decant med | Decant min | Codable med | Codable min | speedup(med) |")
print("|---|--:|--:|--:|--:|--:|--:|")
for r in rows {
  let sp = r.codableDecode.median / r.decantDecode.median
  print("| \(r.label) | \(r.bytes) | \(fmt(r.decantDecode.median)) | \(fmt(r.decantDecode.min)) | \(fmt(r.codableDecode.median)) | \(fmt(r.codableDecode.min)) | \(String(format: "%.2f×", sp)) |")
}

// MARK: - Throughput for the largest array (MB/s)

if let big = rows.first(where: { $0.label.contains("100000") }) {
  let mb = Double(big.bytes) / 1_048_576.0
  print("\n### Throughput — \(big.label) (\(big.bytes) bytes)")
  print("| op | Decant MB/s | Codable MB/s |")
  print("|---|--:|--:|")
  print("| encode | \(String(format: "%.0f", mb / (big.decantEncode.median / 1e9))) | \(String(format: "%.0f", mb / (big.codableEncode.median / 1e9))) |")
  print("| decode | \(String(format: "%.0f", mb / (big.decantDecode.median / 1e9))) | \(String(format: "%.0f", mb / (big.codableDecode.median / 1e9))) |")
}

// MARK: - Memory harness
//
// Isolate encode and decode over the large 100k-element array. We sample
// allocation traffic (malloc_zone max_size_in_use delta) and peak RSS around a
// tight loop of the operation, per codec, in separate phases.

print("\n## Memory (large payload: Array<Small> x100000)")

let memN = 100_000
let memValue = makeSmallArray(memN)
let memDecantBytes = (try? DecantJSON.bytes(json: memValue)) ?? []
let memCodableData = (try? jsonEncoder.encode(memValue)) ?? Data()

func mib(_ b: Int64) -> String {
  String(format: "%+.2f MiB", Double(b) / 1_048_576.0)
}

// Spawn this same binary in `mem <codec> <op>` mode and read back its
// `baseline peak blackhole` line — peak RSS attributed to one codec in a fresh
// process, the only rigorous reading given the monotone watermark.
func probe(_ codec: String, _ op: String) -> (baseline: Double, peak: Double) {
  let proc = Process()
  proc.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
  proc.arguments = ["mem", codec, op]
  let pipe = Pipe()
  proc.standardOutput = pipe
  try? proc.run()
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  proc.waitUntilExit()
  let parts = String(decoding: data, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
  guard parts.count >= 2, let b = Double(parts[0]), let p = Double(parts[1])
  else { return (0, 0) }
  return (b, p)
}

let dEnc = probe("decant", "encode")
let cEnc = probe("codable", "encode")
let dDec = probe("decant", "decode")
let cDec = probe("codable", "decode")

func peakMiB(_ v: Double) -> String { String(format: "%.1f MiB", v) }

print("Payload: Decant=\(memDecantBytes.count)B, Codable=\(memCodableData.count)B input.")
print("Method: each codec runs alone in a FRESH subprocess; peak RSS is its own")
print("resident_size_max watermark at exit (monotone). Baseline = RSS after the")
print("input payload is built, before the op; op-cost ≈ peak − baseline.\n")
print("| op | codec | baseline RSS | peak RSS | op climb |")
print("|---|---|--:|--:|--:|")
print("| encode | Decant  | \(peakMiB(dEnc.baseline)) | \(peakMiB(dEnc.peak)) | \(mib(Int64((dEnc.peak - dEnc.baseline) * 1_048_576))) |")
print("| encode | Codable | \(peakMiB(cEnc.baseline)) | \(peakMiB(cEnc.peak)) | \(mib(Int64((cEnc.peak - cEnc.baseline) * 1_048_576))) |")
print("| decode | Decant  | \(peakMiB(dDec.baseline)) | \(peakMiB(dDec.peak)) | \(mib(Int64((dDec.peak - dDec.baseline) * 1_048_576))) |")
print("| decode | Codable | \(peakMiB(cDec.baseline)) | \(peakMiB(cDec.peak)) | \(mib(Int64((cDec.peak - cDec.baseline) * 1_048_576))) |")
print("\n(blackHole=\(blackHoleAccumulator))")
