import QNotchMac

// `QNotch notify …` sends a notification and exits before AppKit starts.
NotifyClient.runIfRequested()
QNotchApplication.run()
