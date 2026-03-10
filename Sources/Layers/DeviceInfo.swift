import Foundation

#if os(iOS) || os(tvOS)
import UIKit
#endif

/// Provides hardware device information.
/// The React Native bridge can call `DeviceInfo.modelIdentifier` to get the real
/// hardware model string (e.g. "iPhone15,2", "iPad13,4") instead of the generic
/// "iPhone" / "iPad" returned by `UIDevice.model`.
public enum DeviceInfo {
    /// Returns the hardware model identifier (e.g. "iPhone15,2", "iPad13,4").
    /// Falls back to `sysctlbyname("hw.model")` on macOS.
    public static var modelIdentifier: String {
        #if os(iOS) || os(tvOS) || os(watchOS)
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingUTF8: $0) ?? "Unknown"
            }
        }
        #elseif os(macOS)
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
        #else
        return "Unknown"
        #endif
    }
}
