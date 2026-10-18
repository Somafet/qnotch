import Foundation

/// User order for Home cards and tabs (Windows CardLayout and TabReorder): saved ids first, in
/// their saved order; items never placed follow in their default order. Ids of items that are gone
/// (a module turned off) stay in the saved list, so the item returns to its place.
public enum LayoutOrder {
    public static func apply(saved: [String], defaults: [String]) -> [String] {
        let present = Set(defaults)
        let placed = saved.filter(present.contains)
        return placed + defaults.filter { !placed.contains($0) }
    }

    /// Writes the new order of the shown items into the saved list; ids not shown keep their slots.
    public static func reorder(_ shown: [String], saved: [String]) -> [String] {
        var queue = shown[...]
        var result: [String] = []
        for id in saved {
            if shown.contains(id) { if let next = queue.popFirst() { result.append(next) } } else { result.append(id) }
        }
        return result + queue
    }

    /// Moves `id` to where `target` is now, within the full saved list (gone ids included).
    public static func move(_ id: String, to target: String, saved: [String], defaults: [String]) -> [String] {
        var list = saved
        for item in apply(saved: saved, defaults: defaults) where !list.contains(item) { list.append(item) }
        guard id != target, let from = list.firstIndex(of: id), let to = list.firstIndex(of: target) else { return list }
        list.remove(at: from)
        list.insert(id, at: to)
        return list
    }
}
