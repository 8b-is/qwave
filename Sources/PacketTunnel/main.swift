import Foundation
import NetworkExtension

// System-extension entry point: hand control to the NetworkExtension
// machinery, which instantiates PacketTunnelProvider (per Info.plist
// NEProviderClasses) when the tunnel starts.
autoreleasepool {
    NEProvider.startSystemExtensionMode()
}
dispatchMain()
