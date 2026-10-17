import QNotchMac

// Command-line verbs run and exit before AppKit starts.
NotifyClient.runIfRequested()   // QNotch notify …
AgentHookCommand.runIfRequested() // QNotch agent [codex], run by Claude Code and Codex hooks
QNotchApplication.run()
