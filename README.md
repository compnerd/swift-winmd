# Swift/WinMD

An ECMA 335 parser in Swift

<p align="center">
  <a href="https://github.com/compnerd/swift-winmd/actions?query=workflow%3Awindows"><img alt="Windows Status" src="https://github.com/compnerd/swift-winmd/workflows/windows/badge.svg"></a>
</p>

[Windows Metadata](https://docs.microsoft.com/en-us/uwp/winrt-cref/winmd-files) provides the necessary metadata for Windows APIs to enable generating bindings for different languages.  In order to generate the bindings, one must be able to process the metadata.  [Swift/WinMD](https://github.com/compnerd/swift-winmd) provides an implementation of such a parser in Swift.

## Build Requirements

- Swift 5.5 or newer

## Debugging

### Debugging on Windows

For debugging the Swift application code, it is easier to debug using LLDB and
DWARF.  In such a case, you will need to build the application as follows to
enable the debug information:

```cmd
swift build -Xlinker -debug:dwarf
```
