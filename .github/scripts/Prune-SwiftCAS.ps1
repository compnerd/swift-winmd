# Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>
# SPDX-License-Identifier: BSD-3-Clause

param([Parameter(Mandatory)]
      [string] $Path,

      [Parameter(Mandatory)]
      [long] $SizeLimit)

$ErrorActionPreference = "Stop"

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class SwiftScanCAS {
  [StructLayout(LayoutKind.Sequential)]
  public struct StringRef {
    public IntPtr Data;
    public UIntPtr Length;
  }

  [DllImport("_InternalSwiftScan", CallingConvention = CallingConvention.Cdecl)]
  public static extern IntPtr swiftscan_cas_options_create();

  [DllImport("_InternalSwiftScan", CallingConvention = CallingConvention.Cdecl)]
  public static extern void swiftscan_cas_options_dispose(IntPtr options);

  [DllImport("_InternalSwiftScan", CallingConvention = CallingConvention.Cdecl)]
  public static extern void
  swiftscan_cas_options_set_ondisk_path(IntPtr options,
                                        [MarshalAs(UnmanagedType.LPUTF8Str)]
                                        string path);

  [DllImport("_InternalSwiftScan", CallingConvention = CallingConvention.Cdecl)]
  public static extern IntPtr
  swiftscan_cas_create_from_options(IntPtr options, out StringRef error);

  [DllImport("_InternalSwiftScan", CallingConvention = CallingConvention.Cdecl)]
  public static extern long
  swiftscan_cas_get_ondisk_size(IntPtr cas, out StringRef error);

  [DllImport("_InternalSwiftScan", CallingConvention = CallingConvention.Cdecl)]
  [return: MarshalAs(UnmanagedType.I1)]
  public static extern bool
  swiftscan_cas_set_ondisk_size_limit(IntPtr cas, long sizeLimit,
                                      out StringRef error);

  [DllImport("_InternalSwiftScan", CallingConvention = CallingConvention.Cdecl)]
  [return: MarshalAs(UnmanagedType.I1)]
  public static extern bool
  swiftscan_cas_prune_ondisk_data(IntPtr cas, out StringRef error);

  [DllImport("_InternalSwiftScan", CallingConvention = CallingConvention.Cdecl)]
  public static extern void swiftscan_cas_dispose(IntPtr cas);

  [DllImport("_InternalSwiftScan", CallingConvention = CallingConvention.Cdecl)]
  public static extern void swiftscan_string_dispose(StringRef value);
}
'@

function Get-SwiftScanError([SwiftScanCAS+StringRef] $ErrorRef) {
  if ($ErrorRef.Data -eq [IntPtr]::Zero) { return $null }

  try {
    $length = [int]$ErrorRef.Length.ToUInt64()
    $bytes = [byte[]]::new($length)
    [Runtime.InteropServices.Marshal]::Copy($ErrorRef.Data, $bytes, 0, $length)
    return [Text.Encoding]::UTF8.GetString($bytes)
  } finally {
    [SwiftScanCAS]::swiftscan_string_dispose($ErrorRef)
  }
}

function Assert-SwiftScanSuccess([bool] $Failed,
                                 [SwiftScanCAS+StringRef] $ErrorRef) {
  $message = Get-SwiftScanError $ErrorRef
  if ($Failed) {
    if (!$message) { $message = "SwiftScan CAS operation failed" }
    throw $message
  }
}

$options = [SwiftScanCAS]::swiftscan_cas_options_create()
if ($options -eq [IntPtr]::Zero) { throw "Unable to create SwiftScan CAS options" }

$cas = [IntPtr]::Zero
try {
  [SwiftScanCAS]::swiftscan_cas_options_set_ondisk_path($options, $Path)
  $err = [SwiftScanCAS+StringRef]::new()
  $cas = [SwiftScanCAS]::swiftscan_cas_create_from_options($options, [ref]$err)
  $message = Get-SwiftScanError $err
  if ($cas -eq [IntPtr]::Zero) {
    if (!$message) { $message = "Unable to open Swift CAS at $Path" }
    throw $message
  }

  $err = [SwiftScanCAS+StringRef]::new()
  Assert-SwiftScanSuccess `
      ([SwiftScanCAS]::swiftscan_cas_set_ondisk_size_limit($cas, $SizeLimit, [ref]$err)) `
      $err

  $err = [SwiftScanCAS+StringRef]::new()
  $size = [SwiftScanCAS]::swiftscan_cas_get_ondisk_size($cas, [ref]$err)
  Assert-SwiftScanSuccess ($size -eq -2) $err

  $err = [SwiftScanCAS+StringRef]::new()
  Assert-SwiftScanSuccess `
      ([SwiftScanCAS]::swiftscan_cas_prune_ondisk_data($cas, [ref]$err)) `
      $err

  $err = [SwiftScanCAS+StringRef]::new()
  $pruned = [SwiftScanCAS]::swiftscan_cas_get_ondisk_size($cas, [ref]$err)
  Assert-SwiftScanSuccess ($pruned -eq -2) $err

  Write-Host "Swift CAS pruned from $size to $pruned bytes (limit: $SizeLimit bytes)"
} finally {
  if ($cas -ne [IntPtr]::Zero) { [SwiftScanCAS]::swiftscan_cas_dispose($cas) }
  [SwiftScanCAS]::swiftscan_cas_options_dispose($options)
}
