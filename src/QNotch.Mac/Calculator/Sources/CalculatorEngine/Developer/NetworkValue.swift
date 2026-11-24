import Foundation

enum NetworkForm: Hashable { case address, subnet, prefix, membership }

/// Bounded subnet facts (C# SubnetInfo). Address counts are calculated, never enumerated.
struct SubnetInfo: Hashable {
    let input: IpAddressValue
    let prefix: Int
    let network: IpAddressValue
    let last: IpAddressValue
    let mask: IpAddressValue
    let addressCount: BigInt
    let broadcast: IpAddressValue?
    let hostCount: BigInt?
    let firstHost: IpAddressValue?
    let lastHost: IpAddressValue?
    var cidr: String { network.text + "/" + String(prefix) }
    var range: String { network.text + " – " + last.text }
    var hostAssumption: String {
        input.bitWidth == 128 ? "IPv6 has no broadcast; address allocation is not a general usable-host count. Anycast, reserved interface IDs, routing and assignment policy are not inferred" :
            prefix == 31 ? "IPv4 /31 point-to-point model (RFC 3021): both endpoints are host slots; no directed broadcast. Link capability and actual assignment are not inferred" :
            prefix == 32 ? "IPv4 /32 single-address host route; no directed broadcast. Actual assignment is not inferred" :
            "Conventional IPv4 host slots exclude network and directed broadcast. Reserved/special addresses are not filtered; routability and assignment are not inferred"
    }
    var summary: String {
        "Mask: " + mask.text + "; /" + String(prefix) + "\n" + addressCount.description + " addresses" +
            (hostCount.map { "; " + $0.description + " host slots\nHosts: " + firstHost!.text + " – " + lastHost!.text } ?? "\nIPv6 host assignment not inferred")
    }
    var details: String {
        "IPv" + (input.bitWidth == 32 ? "4" : "6") + " subnet: " + cidr + "\nInput: " + input.text +
            (input.number != network.number ? " (host bits normalized)" : "") + "\nRange: " + range + "\n" + summary +
            (broadcast.map { "\nBroadcast: " + $0.text } ?? "") + "\n" + hostAssumption
    }
    init(_ input: IpAddressValue, _ prefix: Int) throws {
        if prefix < 0 || prefix > input.bitWidth { throw CalcError.arithmetic("Prefix is outside the address family's bit width") }
        self.input = input; self.prefix = prefix
        let hostBits = input.bitWidth - prefix
        let wildcard = (BigInt.one << hostBits) - .one
        mask = try IpAddressValue(((BigInt.one << input.bitWidth) - .one) ^ wildcard, input.bitWidth)
        network = try IpAddressValue(input.number & mask.number, input.bitWidth); last = try IpAddressValue(network.number | wildcard, input.bitWidth)
        addressCount = BigInt.one << hostBits
        if input.bitWidth == 32 {
            broadcast = prefix < 31 ? last : nil
            hostCount = prefix < 31 ? addressCount - BigInt(2) : addressCount
            firstHost = try IpAddressValue(network.number + BigInt(prefix < 31 ? 1 : 0), 32)
            lastHost = try IpAddressValue(last.number - BigInt(prefix < 31 ? 1 : 0), 32)
        } else { broadcast = nil; hostCount = nil; firstHost = nil; lastHost = nil }
    }
    func contains(_ candidate: IpAddressValue) -> Bool { candidate.bitWidth == input.bitWidth && candidate.number >= network.number && candidate.number <= last.number }
}

/// IP addresses, subnet ranges, prefix lengths and membership remain distinct from numeric quantities (C# NetworkValue).
struct NetworkValue: Hashable {
    let form: NetworkForm
    let address: IpAddressValue
    let subnet: SubnetInfo?
    let prefix: Int?
    let candidate: IpAddressValue?
    var isMember: Bool? { form == .membership ? subnet!.contains(candidate!) : nil }
    var display: String {
        get throws {
            switch form {
            case .subnet: return subnet!.range
            case .prefix: return "/" + String(prefix!)
            case .membership: return isMember == true ? "yes" : "no"
            case .address: return address.text
            }
        }
    }
    var copyText: String {
        get throws {
            switch form {
            case .subnet: return "(" + subnet!.input.text + "/" + String(subnet!.prefix) + ")"
            case .prefix: return "cidr(" + address.text + ")"
            case .membership: return "contains(" + subnet!.input.text + "/" + String(subnet!.prefix) + "," + candidate!.text + ")"
            case .address: return address.text
            }
        }
    }
    var details: String {
        switch form {
        case .subnet: return subnet!.details
        case .membership:
            return candidate!.text + (isMember == true ? " belongs to " : " does not belong to ") + subnet!.cidr +
                (candidate!.bitWidth != address.bitWidth ? " (different address families)" : "") + "\n" + subnet!.details
        case .prefix: return "Contiguous IPv" + (address.bitWidth == 32 ? "4" : "6") + " netmask: " + address.text + "; prefix /" + String(prefix!)
        case .address: return "IPv" + (address.bitWidth == 32 ? "4" : "6") + " address: " + address.text
        }
    }
    init(_ address: IpAddressValue) { form = .address; self.address = address; subnet = nil; prefix = nil; candidate = nil }
    init(_ subnet: SubnetInfo, _ candidate: IpAddressValue? = nil) {
        self.subnet = subnet; address = subnet.input; prefix = subnet.prefix; self.candidate = candidate; form = candidate == nil ? .subnet : .membership
    }
    init(_ mask: IpAddressValue, _ prefix: Int) { form = .prefix; address = mask; self.prefix = prefix; subnet = nil; candidate = nil }
}
