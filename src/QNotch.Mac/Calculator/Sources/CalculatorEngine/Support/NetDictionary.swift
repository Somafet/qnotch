/// System.Collections.Generic.Dictionary with .NET's enumeration order: insertion order, except that a
/// removed slot is reused by the next insertion (most recently freed first). Swift's Dictionary has no
/// stable order, and the C# engine's output sometimes follows its dictionaries' order.
///
/// `normalize` maps a key to the identity C# hashes it by (for StringComparer.OrdinalIgnoreCase use
/// `NetDictionary.ignoringCase()`); the first spelling inserted is the one enumerated, as in C#.
struct NetDictionary<Key: Hashable, Value>: Sequence {
    private struct Entry { var key: Key; var value: Value; var used: Bool }
    private var entries: [Entry] = []
    private var index: [Key: Int] = [:]
    private var freeList: [Int] = []
    private let normalize: ((Key) -> Key)?

    init(normalize: ((Key) -> Key)? = nil) { self.normalize = normalize }

    @inline(__always) private func identity(_ key: Key) -> Key { normalize?(key) ?? key }
    var count: Int { index.count }
    var isEmpty: Bool { index.isEmpty }
    func containsKey(_ key: Key) -> Bool { index[identity(key)] != nil }

    subscript(key: Key) -> Value? {
        get { index[identity(key)].map { entries[$0].value } }
        set {
            if let newValue { set(key, newValue) } else { remove(key) }
        }
    }
    /// The C# indexer setter: replaces the value, keeping the original key spelling and position.
    mutating func set(_ key: Key, _ value: Value) {
        let id = identity(key)
        if let i = index[id] { entries[i].value = value; return }
        insert(key, id, value)
    }
    /// Dictionary.TryAdd.
    @discardableResult mutating func tryAdd(_ key: Key, _ value: Value) -> Bool {
        let id = identity(key)
        if index[id] != nil { return false }
        insert(key, id, value); return true
    }
    private mutating func insert(_ key: Key, _ id: Key, _ value: Value) {
        if let free = freeList.popLast() { entries[free] = Entry(key: key, value: value, used: true); index[id] = free }
        else { index[id] = entries.count; entries.append(Entry(key: key, value: value, used: true)) }
    }
    @discardableResult mutating func remove(_ key: Key) -> Bool {
        guard let i = index.removeValue(forKey: identity(key)) else { return false }
        entries[i].used = false; freeList.append(i)
        return true
    }
    mutating func removeAll() { entries.removeAll(); index.removeAll(); freeList.removeAll() }
    /// The key as first inserted (C# keeps that spelling).
    func storedKey(_ key: Key) -> Key? { index[identity(key)].map { entries[$0].key } }
    func value(_ key: Key, default fallback: Value) -> Value { self[key] ?? fallback }

    var keys: [Key] { entries.filter(\.used).map(\.key) }
    var values: [Value] { entries.filter(\.used).map(\.value) }
    func makeIterator() -> AnyIterator<(key: Key, value: Value)> {
        var i = 0; let entries = self.entries
        return AnyIterator {
            while i < entries.count { defer { i += 1 }; if entries[i].used { return (entries[i].key, entries[i].value) } }
            return nil
        }
    }
}

extension NetDictionary where Key == String {
    /// `new Dictionary<string, T>(StringComparer.OrdinalIgnoreCase)`.
    static func ignoringCase() -> NetDictionary { NetDictionary(normalize: { $0.ordinalKey }) }
}

/// System.Collections.Generic.HashSet with .NET's enumeration order (see NetDictionary).
struct NetHashSet<Element: Hashable>: Sequence {
    private var storage: NetDictionary<Element, Void>
    init(normalize: ((Element) -> Element)? = nil) { storage = NetDictionary(normalize: normalize) }
    init<S: Sequence>(_ items: S, normalize: ((Element) -> Element)? = nil) where S.Element == Element {
        self.init(normalize: normalize); for item in items { insert(item) }
    }
    var count: Int { storage.count }
    var isEmpty: Bool { storage.isEmpty }
    func contains(_ item: Element) -> Bool { storage.containsKey(item) }
    /// HashSet.Add: false when already present.
    @discardableResult mutating func insert(_ item: Element) -> Bool { storage.tryAdd(item, ()) }
    @discardableResult mutating func remove(_ item: Element) -> Bool { storage.remove(item) }
    mutating func removeAll() { storage.removeAll() }
    var elements: [Element] { storage.keys }
    func makeIterator() -> IndexingIterator<[Element]> { storage.keys.makeIterator() }
    /// HashSet.SetEquals.
    func setEquals(_ other: NetHashSet) -> Bool { count == other.count && allSatisfy(other.contains) }
}

extension NetHashSet where Element == String {
    /// `new HashSet<string>(StringComparer.OrdinalIgnoreCase)`.
    static func ignoringCase<S: Sequence>(_ items: S) -> NetHashSet where S.Element == String { NetHashSet(items, normalize: { $0.ordinalKey }) }
    static func ignoringCase() -> NetHashSet { NetHashSet(normalize: { $0.ordinalKey }) }
}
