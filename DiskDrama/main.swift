import AppKit

// AppKit owns the application lifecycle rather than a SwiftUI `App`.
//
// DiskDrama is menubar-resident: its windows are summoned from a status item and
// dismissed again, and the app keeps running with no window at all. A SwiftUI
// `App` models the opposite shape — scenes as the primary surface, with
// activation policy and window restoration handled on its terms — and there is
// no Scene type that represents `NSStatusItem` plus the popover the design
// handoff specifies. The blueprint's call that "the menubar stays AppKit per v0"
// is followed here at the lifecycle level too.
//
// SwiftUI still renders essentially every pixel of the main window from Step 6
// on; it is hosted inside AppKit windows via `NSHostingView` rather than owning
// the app.

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
