import Foundation

/// IP literals, CIDR subnets, masks and membership (C# NetworkArithmetic).
final class NetworkArithmetic {
    static let convention = "Numeric addresses only; CIDR host bits are normalized; counts describe address space, not reachability. IPv4 /31 uses the point-to-point host model; IPv6 host assignment is not inferred"
    static func isFunction(_ name: String) -> Bool {
        ["subnet", "contains", "netmask", "cidr", "network", "firstip", "lastip", "ipcount", "hostcount", "firsthost", "lasthost", "broadcast", "subnetmask"].contains(name.netLower)
    }
    static func validateArity(_ name: String, _ count: Int) throws {
        let expected = ["subnet", "contains", "netmask"].contains(name.netLower) ? 2 : 1
        if count != expected { throw CalcError.format("\(name) expects \(expected) argument(s)") }
    }
    private let budget: ExecutionBudget
    private let token: CancellationToken
    init(_ budget: ExecutionBudget, _ token: CancellationToken) { self.budget = budget; self.token = token }
    private func step() throws { try budget.step(token) }
    private static func address(_ value: SheetValue) throws -> IpAddressValue {
        guard case .network(let network) = value, network.form == .address else { throw CalcError.arithmetic("Expected an IP address literal/value") }
        return network.address
    }
    private static func subnet(_ value: SheetValue) throws -> SubnetInfo {
        guard case .network(let network) = value, network.form == .subnet else { throw CalcError.arithmetic("Expected a CIDR subnet") }
        return network.subnet!
    }
    private static func smallInteger(_ value: SheetValue, _ maximum: Int) throws -> Int {
        let number = try IntegerArithmetic.require(value)
        if number.sign < 0 || number > BigInt(maximum) { throw CalcError.arithmetic("Integer is outside the network parameter's range") }
        return number.intValue!
    }
    private static func prefix(_ value: SheetValue, _ width: Int) throws -> Int {
        if case .network(let network) = value, network.form == .prefix {
            if network.address.bitWidth != width { throw CalcError.arithmetic("Prefix and address families must match; use an explicit numeric length to change family") }
            return network.prefix!
        }
        return try smallInteger(value, width)
    }
    func literal(_ text: String) throws -> SheetValue { try step(); return .network(NetworkValue(try IpAddressValue.parse(text))) }
    func prefixMask(_ prefix: Int, _ family: Int) throws -> SheetValue { try function("netmask", [SheetValue(Rational(prefix)), SheetValue(Rational(family))]) }
    func attach(_ address: SheetValue, _ prefix: SheetValue) throws -> SheetValue {
        try step(); let ip = try NetworkArithmetic.address(address)
        return .network(NetworkValue(try SubnetInfo(ip, try NetworkArithmetic.prefix(prefix, ip.bitWidth))))
    }
    func contains(_ address: SheetValue, _ subnet: SheetValue) throws -> SheetValue {
        try step(); let info = try NetworkArithmetic.subnet(subnet)
        return .network(NetworkValue(info, try NetworkArithmetic.address(address)))
    }
    func function(_ name: String, _ args: [SheetValue]) throws -> SheetValue {
        try step(); try NetworkArithmetic.validateArity(name, args.count)
        switch name.netLower {
        case "subnet": return try attach(args[0], args[1])
        case "contains": return try contains(args[1], args[0])
        case "netmask":
            let family = try NetworkArithmetic.smallInteger(args[1], 6)
            if family != 4 && family != 6 { throw CalcError.arithmetic("Address family must be 4 or 6") }
            let width = family == 4 ? 32 : 128; let prefix = try NetworkArithmetic.prefix(args[0], width)
            return .network(NetworkValue(try IpAddressValue(((BigInt.one << prefix) - .one) << (width - prefix), width)))
        case "subnetmask":
            if case .network(let network) = args[0], network.form == .prefix { return .network(NetworkValue(network.address)) }
            return .network(NetworkValue(try NetworkArithmetic.subnet(args[0]).mask))
        case "cidr":
            if case .network(let network) = args[0], network.form == .prefix { return args[0] }
            if case .network(let network) = args[0], network.form == .subnet { let subnet = network.subnet!; return .network(NetworkValue(subnet.mask, subnet.prefix)) }
            let mask = try NetworkArithmetic.address(args[0]); var count = 0; var zero = false
            var bit = mask.bitWidth - 1
            while bit >= 0 {
                try step(); let one = !(mask.number & (BigInt.one << bit)).isZero
                if one && zero { throw CalcError.arithmetic("Netmask must have contiguous leading one bits") }
                if one { count += 1 } else { zero = true }
                bit -= 1
            }
            return .network(NetworkValue(mask, count))
        default:
            let info = try NetworkArithmetic.subnet(args[0])
            switch name.netLower {
            case "network", "firstip": return .network(NetworkValue(info.network))
            case "lastip": return .network(NetworkValue(info.last))
            case "ipcount": return SheetValue(try Rational(info.addressCount))
            case "hostcount":
                guard let hosts = info.hostCount else { throw CalcError.arithmetic("A general IPv6 usable-host count is not inferred") }
                return SheetValue(try Rational(hosts))
            case "firsthost":
                guard let host = info.firstHost else { throw CalcError.arithmetic("A general IPv6 usable-host range is not inferred") }
                return .network(NetworkValue(host))
            case "lasthost":
                guard let host = info.lastHost else { throw CalcError.arithmetic("A general IPv6 usable-host range is not inferred") }
                return .network(NetworkValue(host))
            case "broadcast":
                guard let broadcast = info.broadcast else { throw CalcError.arithmetic("This subnet model has no directed broadcast") }
                return .network(NetworkValue(broadcast))
            default: throw CalcError.format("Unknown network function")
            }
        }
    }
}
