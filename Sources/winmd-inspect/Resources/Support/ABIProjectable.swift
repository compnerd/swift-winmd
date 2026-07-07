// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

// The runtime support the generated WinRT generic-interface projection depends
// on — the Swift analogue of windows-rs's `windows_core::Type` trait and its
// associated `Abi` type. It is bundled as a resource (`Resources/Support`) and
// emitted alongside the projected interfaces, NOT compiled into the tool: it is
// what the generated `struct IVector<Element: ABIProjectable>` and its
// `IVectorABI<Element>` protocol project a generic slot through.

/// A type that projects to an ABI representation as it crosses the WinRT vtable
/// — the Swift analogue of windows-rs's `Type` trait, whose `Abi` associated
/// type is the slot's ABI form.
///
/// A WinRT parameterised interface (`IVector<T>`, `IReference<T>`) erases a
/// generic slot by its ARGUMENT's kind, not uniformly: `IVector<Int32>` carries
/// an `Int32` value (4 bytes) across the vtable, `IVector<IFoo>` an opaque
/// interface pointer (8 bytes). A fixed-size raw-pointer cast of the slot
/// therefore traps for a value argument — it reads 8 bytes of a 4-byte value.
/// `ABIProjectable` replaces that cast: the ABI form of a slot is the element's
/// OWN `ABI` type (`CInt` for a value, `UnsafeMutableRawPointer` for a
/// reference), and the conversion is size-correct by construction for both.
///
/// A value type conforms with `ABI == Self` and identity conversions (the
/// windows-rs `CopyType`/`CloneType`, whose `Type::Abi` is `Self`); a
/// reference type conforms with `ABI == UnsafeMutableRawPointer` and the
/// opaque-pointer conversion (the windows-rs `InterfaceType`, whose `Type::Abi`
/// is `*mut c_void`).
public protocol ABIProjectable {
  /// The slot's ABI representation as it crosses the WinRT vtable — `Self` for
  /// a value, the opaque interface pointer for a reference.
  associatedtype ABI

  /// The ABI form of `self`, to pass across the vtable.
  func toABI() -> ABI

  /// The value an ABI form `abi` names, coming back across the vtable.
  static func fromABI(_ abi: ABI) -> Self
}

/// A value type projects to ITSELF: its ABI form is its own representation, so
/// both conversions are the identity — no cast, and size-correct because the
/// slot type IS the value type (windows-rs `Type::Abi == Self`).
extension ABIProjectable where ABI == Self {
  public func toABI() -> Self { self }
  public static func fromABI(_ abi: Self) -> Self { abi }
}

// The WinRT-blittable primitives that appear as generic arguments project by
// value (`ABI == Self`), so a value instantiation (`IVector<Int32>`) crosses
// the vtable as the value itself — never a raw pointer.
extension Int8: ABIProjectable {}
extension UInt8: ABIProjectable {}
extension Int16: ABIProjectable {}
extension UInt16: ABIProjectable {}
extension Int32: ABIProjectable {}
extension UInt32: ABIProjectable {}
extension Int64: ABIProjectable {}
extension UInt64: ABIProjectable {}
extension Int: ABIProjectable {}
extension UInt: ABIProjectable {}
extension Float: ABIProjectable {}
extension Double: ABIProjectable {}
extension Bool: ABIProjectable {}

/// A reference (interface) type projects to the opaque COM interface pointer:
/// its ABI form is `UnsafeMutableRawPointer` (windows-rs `Type::Abi == *mut
/// c_void`). The conversion is the pointer round-trip the projection performs
/// through this protocol rather than through a bare fixed-size `unsafeBitCast`.
public protocol ABIReference: ABIProjectable
    where ABI == UnsafeMutableRawPointer {
  /// The opaque interface pointer backing this reference.
  var pointer: UnsafeMutableRawPointer { get }

  /// Wraps an opaque interface pointer as this reference.
  init(pointer: UnsafeMutableRawPointer)
}

extension ABIReference {
  public func toABI() -> UnsafeMutableRawPointer { pointer }
  public static func fromABI(_ abi: UnsafeMutableRawPointer) -> Self {
    Self(pointer: abi)
  }
}
