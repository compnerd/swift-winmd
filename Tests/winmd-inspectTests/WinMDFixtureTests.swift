import Testing
@testable import winmd_inspect
@testable import WinMD

/// Validates the `WinMDFixture` assembler by rebuilding the inner-shadow
/// scenario (its hand-built byte-array twin is `RenderInnerShadowTests`) and
/// confirming the identical `.collision("B")` fault — proof the assembler emits
/// metadata a fixture behaves the same over, at a fraction of the source.
@Suite struct WinMDFixtureTests {
  @Test func `the assembler rebuilds the inner-shadow fixture`() {
    let f = WinMDFixture()
    let gaNs = f.string("Windows.Win32.Foundation.Metadata")
    let ga = f.string("GuidAttribute")
    let system = f.string("System"); let valueType = f.string("ValueType")
    let nsR = f.string("R"); let iroot = f.string("IRoot")
    let nsAB = f.string("A.B"); let point = f.string("Point"); let nsC = f.string("C")
    let nb = f.string("B")
    let ctor = f.string(".ctor"); let get = f.string("Get")
    let tip = f.string("tip"); let edge = f.string("edge")

    let vt = Coded.index(1, 2)                              // System.ValueType
    let getSig = f.blob([0x20, 0x00, 0x11, UInt8(Coded.index(0, 2))])  // A.B.Point
    let ctorSig = f.blob([0x20, 0x02, 0x01, 0x08, 0x0f])
    let tipSig = f.blob([0x06, 0x11, UInt8(Coded.index(0, 3))])  // tip  : C.Point
    let edgeSig = f.blob([0x06, 0x11, UInt8(Coded.index(1, 3))]) // edge : ext B
    let guid = f.blob([0x01, 0x00, 0xef, 0xbe, 0xad, 0xde, 0xfe, 0xca, 0xbe,
                       0xba, 0xf0, 0x0d, 0x12, 0x34, 0x56, 0x78, 0x90, 0xab,
                       0x00, 0x00])

    f.row(1, Coded.u16(0) + Coded.u16(ga) + Coded.u16(gaNs))
    f.row(1, Coded.u16(0) + Coded.u16(valueType) + Coded.u16(system))
    f.row(1, Coded.u16(Coded.index(2, 1)) + Coded.u16(nb) + Coded.u16(0))
    f.row(2, Coded.u32(0x21) + Coded.u16(iroot) + Coded.u16(nsR)
            + Coded.u16(0) + Coded.u16(1) + Coded.u16(1))
    f.row(2, Coded.u32(0x08) + Coded.u16(point) + Coded.u16(nsAB)
            + Coded.u16(vt) + Coded.u16(1) + Coded.u16(2))
    f.row(2, Coded.u32(0x08) + Coded.u16(point) + Coded.u16(nsC)
            + Coded.u16(vt) + Coded.u16(3) + Coded.u16(2))
    f.row(4, Coded.u16(0) + Coded.u16(tip) + Coded.u16(tipSig))
    f.row(4, Coded.u16(0) + Coded.u16(edge) + Coded.u16(edgeSig))
    f.row(6, Coded.u32(0) + Coded.u16(0) + Coded.u16(0x05C6)
            + Coded.u16(get) + Coded.u16(getSig) + Coded.u16(1))
    f.row(10, Coded.u16(Coded.index(1, 1, bits: 3))
             + Coded.u16(ctor) + Coded.u16(ctorSig))
    f.row(12, Coded.u16(Coded.index(3, 1, bits: 5))
             + Coded.u16(Coded.index(3, 1, bits: 3)) + Coded.u16(guid))
    f.row(0x23, Array(repeating: 0, count: 20))

    f.with { catalog in
      let shell = Shell(catalog)
      #expect(throws: Shell.RenderError.collision("B")) {
        _ = try shell.render(closure: "IRoot", template: "com")
      }
    }
  }
}
