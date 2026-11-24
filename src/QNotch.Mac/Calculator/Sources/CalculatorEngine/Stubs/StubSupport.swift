/// Identity-based equality for placeholder values (replaced by value equality in the real ports).
protocol IdentityHashable: AnyObject, Hashable {}
extension IdentityHashable {
    static func == (a: Self, b: Self) -> Bool { a === b }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
func notPorted(_ what: String) -> CalcError { .notPorted(what) }
