import OSLog

/// Subsystem-scoped loggers.
///
/// `os.Logger` rather than `NSLog`: `NSLog` output from a Developer-ID-signed
/// app launched outside Xcode does not reliably surface in `log show`, which
/// makes it useless for exactly the case it is most needed — diagnosing the
/// installed build. `Logger` lands in the unified log every time and is
/// filterable by subsystem:
///
/// ```bash
/// log show --predicate 'subsystem == "com.bloo.diskdrama"' --last 5m --style compact
/// log stream --predicate 'subsystem == "com.bloo.diskdrama"'
/// ```
///
/// Note that `Logger` redacts interpolated values as `<private>` by default.
/// Anything that should be readable in the log needs an explicit
/// `privacy: .public`. **File paths stay redacted** — they carry the home-folder
/// username and project/client names (preflight §Privacy names this exactly),
/// and the unified log is readable by anything on the machine.
enum Log {
    private static let subsystem = "com.bloo.diskdrama"

    static let app     = Logger(subsystem: subsystem, category: "app")
    static let scan    = Logger(subsystem: subsystem, category: "scan")
    static let deleted = Logger(subsystem: subsystem, category: "deletion")
}
