// Minimal round-trip executable using ONLY Foundation Codable
// (JSONEncoder/JSONDecoder). For the code-size comparison.

import Foundation

struct Record: Codable, Equatable {
  var id: Int32
  var x: Double
  var y: Double
  var active: Bool
  var name: String
}

let value = Record(id: 42, x: 1.5, y: -2.25, active: true, name: "hello")
let data = try JSONEncoder().encode(value)
let back = try JSONDecoder().decode(Record.self, from: data)
// Consume so nothing is stripped.
print(data.count, back == value)
