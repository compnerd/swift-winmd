# Swift/WinMD

An ECMA 335 parser

## Build Requirements

- Windows SDK 10.0.17763.0 or newer
- development release of Swift

## Build Instructions

```cmd
set SDKROOT=%SystemDrive%\Library\Developer\Platforms\Windows.platform\Developer\SDKs\Windows.sdk
swift build -Xmanifest -resource-dir -Xmanifest %SDKROOT%\usr\lib\swift -Xmanifest -L%SDKROOT%\usr\lib\swift\windows -Xmanifest -libc -Xmanifest MD -Xswiftc -resource-dir -Xswiftc %SDKROOT%\usr\lib\swift -Xswiftc -L%SDKROOT%\usr\lib\swift\windows -Xswiftc -libc -Xswiftc MD
```
