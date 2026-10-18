/// Which status segments show beside the camera. Each wing shows its own segments in order while
/// they fit; one that no longer fits moves to the outer end of the other wing when that has room
/// (both wings are as wide as the fuller one anyway). Only then is it dropped, farthest from the
/// camera first.
public enum WingFit {
    /// `leading` and `trailing` are each wing's segments in contribution order with their width,
    /// nil while hidden. Returns the shown segments of each wing, left to right.
    public static func fit<ID: Equatable>(leading: [(ID, Double?)], trailing: [(ID, Double?)],
                                          maxWidth: Double, spacing: Double) -> (leading: [ID], trailing: [ID]) {
        func fill(_ items: [(ID, Double?)]) -> (shown: [ID], overflow: [(ID, Double)], used: Double) {
            var shown: [ID] = [], overflow: [(ID, Double)] = [], used = 0.0
            for case let (id, width?) in items {
                let next = width + (used > 0 ? spacing : 0)
                if used + next > maxWidth { overflow.append((id, width)) } else { shown.append(id); used += next }
            }
            return (shown, overflow, used)
        }
        var left = fill(leading), right = fill(trailing)
        // The left wing's outer end is its start, the right wing's its end.
        var intoLeft: [ID] = [], intoRight: [ID] = []
        for (id, width) in right.overflow {
            let next = width + (left.used > 0 ? spacing : 0)
            guard left.used + next <= maxWidth else { continue }
            left.used += next
            intoLeft.insert(id, at: 0)
        }
        for (id, width) in left.overflow {
            let next = width + (right.used > 0 ? spacing : 0)
            guard right.used + next <= maxWidth else { continue }
            right.used += next
            intoRight.append(id)
        }
        return (intoLeft + left.shown, right.shown + intoRight)
    }
}
