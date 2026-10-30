import QNotchMac

// Command-line verbs run and exit before AppKit starts.
ConsumerClient.runIfRequested()  // cached read-only consumer; never starts AppKit
NotifyClient.runIfRequested()   // QNotch notify …
AgentHookCommand.runIfRequested() // QNotch agent [codex], run by Claude Code and Codex hooks
DebugClient.runIfRequested()      // QNotch debug …, for a QNotch started with --debug-control
QNotchApplication.run()
