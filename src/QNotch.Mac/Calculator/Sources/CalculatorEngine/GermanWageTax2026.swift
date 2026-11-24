import Foundation

// Port of GermanWageTax2026.cs. All arithmetic is NetDecimal (System.Decimal) so every scale, truncation and
// rounding point matches the C# program, which follows the PAP's explicit scales and rounding directions.

/// Inputs of the BMF 2026 machine wage-tax program used by Calc (current wage only).
/// Names in comments are the official PAP parameters. Statutory pension, unemployment, health and care
/// insurance are fixed (KRV = ALV = PKV = 0).
struct GermanWageTaxInput {
    var period: Int                          // LZZ: 1 year, 2 month, 3 week, 4 day
    var wageCents: NetDecimal                // RE4, whole cents for the period
    var taxClass = 1                         // STKL 1..6
    var childAllowances = NetDecimal.zero    // ZKF, one decimal place
    var healthSurchargePercent = NetDecimal.zero // KVZ, full kassenindividueller Zusatzbeitragssatz
    var saxony = false                       // PVS
    var childlessSurcharge = false           // PVZ
    var careDiscounts = 0                    // PVA 0..4
    var church = false                       // R > 0
}

struct GermanWageTaxResult: Equatable {
    let wageTaxCents: NetDecimal, solidarityCents: NetDecimal, churchBaseCents: NetDecimal
    let annualWage: NetDecimal, annualTableAllowances: NetDecimal, annualProvisionAllowance: NetDecimal, annualTaxableIncome: NetDecimal, annualTax: NetDecimal
}

/// Hand port of "Programmablaufplan für die maschinelle Berechnung der vom Arbeitslohn einzubehaltenden Lohnsteuer,
/// des Solidaritätszuschlags und der Maßstabsteuer für die Kirchenlohnsteuer für 2026" (BMF 12.11.2025,
/// BStBl 2025 I S. 1948, Anlage 1; pseudo-code Lohnsteuer2026.xml version 1.0). Only the current-wage path:
/// no Versorgungsbezüge, Altersentlastungsbetrag, Freibetrag/Hinzurechnung, factor method or sonstige Bezüge.
enum GermanWageTax2026 {
    /// A C# decimal literal: `d(93, 3)` is `0.093m`.
    private static func d(_ mantissa: Int64, _ scale: Int = 0) -> NetDecimal { NetDecimal(mantissa, scale: scale) }
    private static let bbgrvalv = d(101400), avsatzan = d(13, 3), rvsatzan = d(93, 3), bbgkvpv = d(69750)
    private static let w1stkl5 = d(14071), w2stkl5 = d(34939), w3stkl5 = d(222260), gfb = d(12348), solzfreiBase = d(20350)

    private static func down(_ value: NetDecimal, _ scale: Int) throws -> NetDecimal {
        let factor = try pow10(scale); return try (try value * factor).truncated / factor
    }
    private static func up(_ value: NetDecimal, _ scale: Int) throws -> NetDecimal {
        let factor = try pow10(scale); let scaled = try value * factor; let whole = scaled.truncated
        return try (whole == scaled ? whole : try whole + NetDecimal(scaled.sign)) / factor
    }
    private static func pow10(_ scale: Int) throws -> NetDecimal {
        switch scale {
        case 0: return d(1)
        case 2: return d(100)
        case 6: return d(1000000)
        default: throw CalcError.argument("Specified argument was out of the range of valid values. (Parameter 'scale')")
        }
    }

    private final class State {
        let input: GermanWageTaxInput
        var kvsatzan = NetDecimal.zero, pvsatzan = NetDecimal.zero, solzfrei = NetDecimal.zero, zre4j = NetDecimal.zero, zre4 = NetDecimal.zero
        var zre4vp = NetDecimal.zero, ztabfb = NetDecimal.zero, anp = NetDecimal.zero, sap = NetDecimal.zero, efa = NetDecimal.zero, kfb = NetDecimal.zero
        var vsp = NetDecimal.zero, vspr = NetDecimal.zero, vspkvpv = NetDecimal.zero, zve = NetDecimal.zero, x = NetDecimal.zero, st = NetDecimal.zero
        var kztab = 1
        init(_ input: GermanWageTaxInput) { self.input = input }
    }

    static func calculate(_ input: GermanWageTaxInput) throws -> GermanWageTaxResult {
        if input.period < 1 || input.period > 4 || input.taxClass < 1 || input.taxClass > 6 || input.wageCents.sign < 0 || input.careDiscounts < 0 || input.careDiscounts > 4 || input.childAllowances.sign < 0 {
            throw CalcError.argument("Specified argument was out of the range of valid values. (Parameter 'input')")
        }
        let s = State(input)
        // MPARA
        s.kvsatzan = try (try input.healthSurchargePercent / d(2)) / d(100) + d(7, 2)
        s.pvsatzan = input.saxony ? d(23, 3) : d(18, 3)
        s.pvsatzan = input.childlessSurcharge ? try s.pvsatzan + d(6, 3) : try s.pvsatzan - (try NetDecimal(input.careDiscounts) * d(25, 4))
        s.solzfrei = solzfreiBase
        // MRE4JL (VBEZ, LZZFREIB, LZZHINZU are zero in Calc's profile)
        switch input.period {
        case 1: s.zre4j = try down(try input.wageCents / d(100), 2)
        case 2: s.zre4j = try down(try (try input.wageCents * d(12)) / d(100), 2)
        case 3: s.zre4j = try down(try (try input.wageCents * d(360)) / d(700), 2)
        default: s.zre4j = try down(try (try input.wageCents * d(360)) / d(100), 2)
        }
        // MRE4 / MRE4ALTE: no pension payments and no age relief; MRE4ABZ
        try mre4abz(s)
        // MBERECH
        try mztabfb(s)
        try mlstjahr(s)
        let lstjahr = try down(s.st, 0)
        let wageTax = try anteil(input.period, try lstjahr * d(100))
        let taxable = s.zve, tableAllowances = s.ztabfb, provision = s.vsp
        let jbmg: NetDecimal
        if input.childAllowances.sign > 0 {
            s.ztabfb = try s.ztabfb + s.kfb; try mre4abz(s); try mlstjahr(s); jbmg = try down(s.st, 0)
        } else { jbmg = lstjahr }
        // MSOLZ
        s.solzfrei = try s.solzfrei * NetDecimal(s.kztab)
        var solidarity = NetDecimal.zero
        if jbmg > s.solzfrei {
            var solzj = try down(try (try jbmg * d(55, 1)) / d(100), 2)
            let solzmin = try down(try (try (try jbmg - s.solzfrei) * d(119, 1)) / d(100), 2)
            if solzmin < solzj { solzj = solzmin }
            solidarity = try anteil(input.period, try down(try solzj * d(100), 0))
        }
        let churchBase = input.church ? try anteil(input.period, try jbmg * d(100)) : NetDecimal.zero
        return GermanWageTaxResult(wageTaxCents: wageTax, solidarityCents: solidarity, churchBaseCents: churchBase, annualWage: s.zre4j,
                                   annualTableAllowances: tableAllowances, annualProvisionAllowance: provision, annualTaxableIncome: taxable, annualTax: lstjahr)
    }
    private static func mre4abz(_ s: State) throws {
        s.zre4 = try down(s.zre4j, 2); if s.zre4.sign < 0 { s.zre4 = .zero }
        s.zre4vp = s.zre4j
    }
    private static func mztabfb(_ s: State) throws {
        s.anp = .zero; let klass = s.input.taxClass
        if klass < 6 && s.zre4.sign > 0 { s.anp = s.zre4 < d(1230) ? try up(try s.anp + s.zre4, 0) : try s.anp + d(1230) }
        s.kztab = 1
        switch klass {
        case 1: s.sap = d(36); s.kfb = try down(try s.input.childAllowances * d(9756), 0)
        case 2: s.efa = d(4260); s.sap = d(36); s.kfb = try down(try s.input.childAllowances * d(9756), 0)
        case 3: s.kztab = 2; s.sap = d(36); s.kfb = try down(try s.input.childAllowances * d(9756), 0)
        case 4: s.sap = d(36); s.kfb = try down(try s.input.childAllowances * d(4878), 0)
        case 5: s.sap = d(36); s.kfb = .zero
        default: s.kfb = .zero
        }
        s.ztabfb = try down(try (try s.efa + s.anp) + s.sap, 2)
    }
    private static func mlstjahr(_ s: State) throws {
        try upevp(s)
        s.zve = try (try s.zre4 - s.ztabfb) - s.vsp
        // UPMLST
        if s.zve < d(1) { s.zve = .zero; s.x = .zero } else { s.x = try down(try s.zve / NetDecimal(s.kztab), 0) }
        if s.input.taxClass < 5 { try uptab26(s) } else { try mst56(s) }
    }
    private static func upevp(_ s: State) throws {
        s.vspr = try down(try NetDecimal.minimum(s.zre4vp, bbgrvalv) * rvsatzan, 2)
        // MVSPKVPV, statutory health/care insurance (PKV = 0)
        s.vspkvpv = try down(try NetDecimal.minimum(s.zre4vp, bbgkvpv) * (try s.kvsatzan + s.pvsatzan), 2)
        s.vsp = try up(try s.vspkvpv + s.vspr, 0)
        if s.input.taxClass == 6 { return } // ALV = 0; MVSPHB is skipped only in class VI
        // MVSPHB
        let vspalv = try down(try avsatzan * NetDecimal.minimum(s.zre4vp, bbgrvalv), 2)
        var vsphb = try down(try vspalv + s.vspkvpv, 2); if vsphb > d(1900) { vsphb = d(1900) }
        let vspn = try up(try s.vspr + vsphb, 0)
        if vspn > s.vsp { s.vsp = vspn }
    }
    private static func mst56(_ s: State) throws {
        let zzx = s.x
        if zzx > w2stkl5 {
            try up56(s, w2stkl5)
            s.st = zzx > w3stkl5
                ? try down(try (try down(try s.st + (try (try w3stkl5 - w2stkl5) * d(42, 2)), 0)) + (try (try zzx - w3stkl5) * d(45, 2)), 0)
                : try down(try s.st + (try (try zzx - w2stkl5) * d(42, 2)), 0)
        } else {
            try up56(s, zzx)
            if zzx > w1stkl5 {
                let vergl = s.st; try up56(s, w1stkl5)
                let hoch = try down(try s.st + (try (try zzx - w1stkl5) * d(42, 2)), 0)
                s.st = hoch < vergl ? hoch : vergl
            }
        }
    }
    private static func up56(_ s: State, _ zx: NetDecimal) throws {
        s.x = try down(try zx * d(125, 2), 0); try uptab26(s); let st1 = s.st
        s.x = try down(try zx * d(75, 2), 0); try uptab26(s); let st2 = s.st
        let diff = try (try st1 - st2) * d(2); let mist = try down(try zx * d(14, 2), 0)
        s.st = mist > diff ? mist : diff
    }
    private static func uptab26(_ s: State) throws {
        let x = s.x
        if x < (try gfb + d(1)) { s.st = .zero }
        else if x < d(17800) {
            let y = try down(try (try x - gfb) / d(10000), 6)
            s.st = try down(try (try (try y * d(91451, 2)) + d(1400)) * y, 0)
        } else if x < d(69879) {
            let y = try down(try (try x - d(17799)) / d(10000), 6)
            s.st = try down(try (try (try (try y * d(1731, 1)) + d(2397)) * y) + d(103487, 2), 0)
        } else if x < d(277826) { s.st = try down(try (try x * d(42, 2)) - d(1113563, 2), 0) }
        else { s.st = try down(try (try x * d(45, 2)) - d(1947038, 2), 0) }
        s.st = try s.st * NetDecimal(s.kztab)
    }
    private static func anteil(_ period: Int, _ jw: NetDecimal) throws -> NetDecimal {
        switch period {
        case 1: return jw
        case 2: return try down(try jw / d(12), 0)
        case 3: return try down(try (try jw * d(7)) / d(360), 0)
        default: return try down(try jw / d(360), 0)
        }
    }
}
