// Minimal round-trip executable importing ONLY DecantJSON (self-contained,
// no Foundation). For the code-size comparison.

import Decant
import DecantMacros
import DecantJSON

@Serializable @Deserializable
struct Record: Equatable {
  var id: Int32
  var x: Double
  var y: Double
  var active: Bool
  var name: String
}

let value = Record(id: 42, x: 1.5, y: -2.25, active: true, name: "hello")
let bytes = try DecantJSON.bytes(json: value)
let back: Record = try DecantJSON.decode(Record.self, json: bytes)
// Consume so nothing is stripped.
print(bytes.count, back == value)
