#if canImport(AppKit)
import AppKit
/// The platform's native bitmap image type: `NSImage` on macOS, `UIImage` on iOS.
/// Lets the cross-platform tab model carry a snapshot/favicon without importing
/// a specific UI framework.
public typealias PlatformImage = NSImage
#elseif canImport(UIKit)
import UIKit
public typealias PlatformImage = UIImage
#endif
