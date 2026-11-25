import Foundation

/// Immutable sampled curve: finite points in x order, split into segments at undefined samples and jumps. The host draws it; nothing here depends on a pixel size.
final class PlotValue: Hashable {
    static let maxPoints = 512
    let formula: String
    let lower: Double, upper: Double
    let yLower: Double, yUpper: Double
    /// The y limits exclude values near a pole or jump instead of spanning them.
    let yLimited: Bool
    /// More sharp changes were found than the sampling bound can resolve.
    let undersampled: Bool
    let x: [Double]
    let y: [Double]
    /// Index of the first point of each drawn segment.
    let segmentStarts: [Int]
    private let hash: Int

    init(_ formula: String, _ lower: Double, _ upper: Double, _ xs: [Double], _ ys: [Double], _ segments: [Int], _ yLower: Double, _ yUpper: Double, _ limited: Bool, _ undersampled: Bool) throws {
        if xs.isEmpty || xs.count > PlotValue.maxPoints || xs.count != ys.count { throw CalcError.arithmetic("Plot point limit exceeded") }
        self.formula = formula; self.lower = lower; self.upper = upper; x = xs; y = ys; segmentStarts = segments
        self.yLower = yLower; self.yUpper = yUpper; yLimited = limited; self.undersampled = undersampled
        var code = Hasher(); code.combine(Array(formula.utf16)); code.combine(yLower); code.combine(yUpper)
        code.combine(xs); code.combine(ys); code.combine(segments)
        hash = code.finalize()
    }
    /// Axis and summary numbers: four significant digits, with values within 1e-12 of zero shown as 0.
    static func number(_ value: Double) -> String { NetFormat.double(Swift.abs(value) < 1e-12 ? 0 : value, "G4") }
    private var domain: String { "[" + PlotValue.number(lower) + ", " + PlotValue.number(upper) + "]" }
    private var range: String { PlotValue.number(yLower) + " to " + PlotValue.number(yUpper) }
    var display: String { "plot" }
    var copyText: String { "plot " + formula + " on " + domain + ": y from " + range + ", \(x.count) points" }
    var summary: String { "Sampled on " + domain + "; y shown from " + range + (yLimited ? "\nLimits leave out values near poles or jumps" : "") }
    var details: String {
        "Formula: " + formula + "\nDomain: " + domain + "\n\(x.count) points from \(PlotSampler.gridSamples) uniform samples, refined near sharp changes up to \(PlotValue.maxPoints)\n" +
            "\(segmentStarts.count) segment(s); a segment ends at an undefined sample or a jump\ny shown from " + range + (yLimited ? ", robust limits that leave out values near poles or jumps" : ", the sampled extremes") +
            (undersampled ? "\nToo many sharp changes for the sampling bound; narrow the domain with from a to b" : "")
    }
    /// The accessibility description (C# Description; ToString is Display).
    var description: String { "Plot of " + formula + " for x from " + PlotValue.number(lower) + " to " + PlotValue.number(upper) + ", y shown from " + range }

    static func == (a: PlotValue, b: PlotValue) -> Bool {
        a === b || a.hash == b.hash && a.formula.ordinalEquals(b.formula) && a.lower == b.lower && a.upper == b.upper && a.yLower == b.yLower && a.yUpper == b.yUpper &&
            a.x == b.x && a.y == b.y && a.segmentStarts == b.segmentStarts
    }
    func hash(into hasher: inout Hasher) { hasher.combine(hash) }
}

/// System.Math.Max/Min/Clamp on doubles (.NET Core 3.0+): NaN wins, and +0 is greater than -0.
enum NetDoubleMath {
    static func max(_ a: Double, _ b: Double) -> Double {
        if a != b { return a.isNaN ? a : (b.isNaN ? b : (a > b ? a : b)) }
        return a.sign == .minus ? b : a
    }
    static func min(_ a: Double, _ b: Double) -> Double {
        if a != b { return a.isNaN ? a : (b.isNaN ? b : (a < b ? a : b)) }
        return a.sign == .minus ? a : b
    }
    /// Math.Clamp(value, min, max); .NET throws when min > max.
    static func clamp(_ value: Double, _ low: Double, _ high: Double) throws -> Double {
        if low > high { throw CalcError.argument("'\(NetFormat.double(low, nil))' cannot be greater than \(NetFormat.double(high, nil)).") }
        if value < low { return low }
        if value > high { return high }
        return value
    }
}

/// Uniform grid, then bounded midpoint refinement where the curve moves sharply or stops being defined. Jumps are confirmed by bisection: a continuous step halves, a jump does not.
enum PlotSampler {
    static let gridSamples = 257, maxProbes = 2048, maxRounds = 8, jumpDepth = 24
    private static let sharpStep = 0.04, jumpStep = 0.2, fenceFactor = 3.0

    static func sample(_ formula: Formula, _ text: String, _ lower: Double, _ upper: Double, _ budget: ExecutionBudget, _ token: CancellationToken) throws -> PlotValue {
        func at(_ x: Double) throws -> Double { let y = try formula.sample(x, budget, token); return y.isFinite ? y : .nan }
        let step = (upper - lower) / Double(gridSamples - 1)
        if !lower.isFinite || !step.isFinite || lower + step == lower { throw CalcError.arithmetic("Plot domain is too wide or too narrow") }
        var points: [(x: Double, y: Double)] = []; points.reserveCapacity(PlotValue.maxPoints)
        for i in 0..<gridSamples { let x = i == gridSamples - 1 ? upper : lower + Double(i) * step; points.append((x, try at(x))) }
        // LINQ Order() is a stable sort with Comparer<double>.Default (-0 and +0 compare equal).
        let grid = points.map(\.y).filter(\.isFinite).stableSorted { $0 < $1 }
        if grid.isEmpty { throw CalcError.arithmetic("Nothing to plot: the formula is undefined across this domain") }
        // Quartile fences come from the uniform grid only: refinement clusters near poles and would widen them.
        let q1 = grid[(grid.count - 1) / 4], q3 = grid[3 * (grid.count - 1) / 4]
        let spread = q3 > q1 ? q3 - q1 : NetDoubleMath.max(Swift.abs(q1), 1)
        let fenceLower = q1 - fenceFactor * spread, fenceUpper = q3 + fenceFactor * spread
        let viewLower = NetDoubleMath.max(grid[0], fenceLower), viewUpper = NetDoubleMath.min(grid[grid.count - 1], fenceUpper)
        let scale = viewUpper > viewLower ? viewUpper - viewLower : NetDoubleMath.max(Swift.abs(viewLower), 1)
        func clamp(_ y: Double) throws -> Double { try NetDoubleMath.clamp(y, viewLower - scale, viewUpper + scale) }
        var round = 0
        while round < maxRounds && points.count < PlotValue.maxPoints {
            defer { round += 1 }
            var sharp: [(score: Double, index: Int)] = []
            var i = 0
            while i + 1 < points.count {
                defer { i += 1 }
                try token.throwIfCancellationRequested()
                let a = points[i].y, b = points[i + 1].y
                if a.isNaN && b.isNaN { continue }
                let score = a.isNaN || b.isNaN ? 2 : Swift.abs(try clamp(b) - clamp(a)) / scale
                if score > sharpStep { sharp.append((score, i)) }
            }
            if sharp.isEmpty { break }
            // OrderByDescending is stable: equal scores keep their left-to-right order before Take.
            let chosen = Set(sharp.stableSorted { $0.score > $1.score }.prefix(PlotValue.maxPoints - points.count).map(\.index))
            var refined: [(x: Double, y: Double)] = []; refined.reserveCapacity(PlotValue.maxPoints)
            for i in points.indices {
                refined.append(points[i])
                if !chosen.contains(i) { continue }
                let x = points[i].x + (points[i + 1].x - points[i].x) / 2
                refined.append((x, try at(x)))
            }
            points = refined
        }
        var probes = maxProbes, undersampled = false
        func jumps(_ first: (x: Double, y: Double), _ second: (x: Double, y: Double)) throws -> Bool {
            var a = first, b = second
            let start = Swift.abs(b.y - a.y)
            if start <= jumpStep * scale { return false }
            for _ in 0..<jumpDepth {
                // C# `probes-- <= 0`: test, then count the probe.
                let remaining = probes; probes -= 1
                if remaining <= 0 { undersampled = true; return false }
                let x = a.x + (b.x - a.x) / 2
                if x == a.x || x == b.x { return true }
                let y = try at(x)
                if y.isNaN { return true }
                let left = Swift.abs(y - a.y), right = Swift.abs(b.y - y)
                if NetDoubleMath.max(left, right) < start / 4 { return false }
                if left >= right { b = (x, y) } else { a = (x, y) }
            }
            return true
        }
        var xs: [Double] = [], ys: [Double] = [], starts: [Int] = []
        xs.reserveCapacity(points.count); ys.reserveCapacity(points.count)
        var gap = true, broken = false
        for i in points.indices {
            try token.throwIfCancellationRequested()
            if points[i].y.isNaN { gap = true; broken = true; continue }
            if try gap || jumps(points[i - 1], points[i]) { broken = broken || !gap; starts.append(xs.count) }
            xs.append(points[i].x); ys.append(points[i].y); gap = false
        }
        // Enumerable.Min/Max over doubles without NaN: the first extreme value wins.
        var minimum = ys[0], maximum = ys[0]
        for value in ys.dropFirst() { if value < minimum { minimum = value }; if value > maximum { maximum = value } }
        let limited = broken && (minimum < fenceLower || maximum > fenceUpper)
        var yLower = broken ? NetDoubleMath.max(minimum, fenceLower) : minimum, yUpper = broken ? NetDoubleMath.min(maximum, fenceUpper) : maximum
        if !(yUpper > yLower) { let margin = yLower == 0 ? 1 : Swift.abs(yLower) / 10; yLower -= margin; yUpper += margin }
        return try PlotValue(text, lower, upper, xs, ys, starts, yLower, yUpper, limited, undersampled)
    }
}

enum PlotArithmetic {
    static func plot(_ plot: PlotExpression, _ inputs: [SheetValue], _ math: ExactArithmetic, _ budget: ExecutionBudget, _ token: CancellationToken) throws -> (value: SheetValue, assumption: String) {
        let constants = inputs.count - (plot.hasDomain ? 2 : 0)
        let formula = try FormulaArithmetic.prepare(plot.body, "x", inputs, constants).formula
        var lower = FormulaRoots.defaultLower, upper = FormulaRoots.defaultUpper
        if plot.hasDomain {
            let from = try FormulaArithmetic.require(inputs[inputs.count - 2], "Domain bound"), to = try FormulaArithmetic.require(inputs[inputs.count - 1], "Domain bound")
            if try math.sign(try math.subtract(to.exact, from.exact)) <= 0 { throw CalcError.arithmetic("Use from lower to upper with lower < upper") }
            lower = FormulaNumbers.toDouble(from.exact); upper = FormulaNumbers.toDouble(to.exact)
        }
        let value = try PlotSampler.sample(formula, plot.text, lower, upper, budget, token)
        return (.plot(value), "Sampled curve, not an exact graph; sheet names are constants; " + FormulaFunctions.convention)
    }
}
