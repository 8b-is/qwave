import os

/// Central loggers, one per subsystem area, all under the app's subsystem so
/// `log stream --predicate 'subsystem == "is.8b.qwave"'` captures everything.
public enum QwaveLog {
    public static let subsystem = "is.8b.qwave"

    public static let browser = Logger(subsystem: subsystem, category: "browser")
    public static let shields = Logger(subsystem: subsystem, category: "shields")
    public static let energy = Logger(subsystem: subsystem, category: "energy")
    public static let features = Logger(subsystem: subsystem, category: "features")
    public static let vpn = Logger(subsystem: subsystem, category: "vpn")
    public static let persistence = Logger(subsystem: subsystem, category: "persistence")
    public static let tunnel = Logger(subsystem: subsystem, category: "tunnel")
}
