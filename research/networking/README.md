# Networking

HTTP and protocol tooling — evaluated primarily against VPN routing guarantees.

| Package | Verdict | Note file |
|---|---|---|
| SwiftNIO | **Hold** | [swift-nio.md](swift-nio.md) — raw sockets bypass the tunnel route |
| AsyncHTTPClient | **Hold** | [async-http-client.md](async-http-client.md) — NIO-based |
| swift-nio-ssl | **Hold** | [swift-nio-ssl.md](swift-nio-ssl.md) — vendored BoringSSL |
| swift-openapi-generator | **Assess** | [swift-openapi-generator.md](swift-openapi-generator.md) — regenerated Mullvad client |
| swift-openapi-runtime | **Assess** | [swift-openapi-runtime.md](swift-openapi-runtime.md) — generator companion |
