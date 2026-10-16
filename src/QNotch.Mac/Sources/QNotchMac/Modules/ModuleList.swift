import Foundation

enum ModuleList {
    // The only composition file that names a concrete module. Disabled modules aren't created.
    static func make(timerEnabled: Bool) -> [NotchModule] {
        timerEnabled ? [TimerModule()] : []
    }
}
