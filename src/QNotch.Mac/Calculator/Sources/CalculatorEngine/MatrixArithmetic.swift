import Foundation

final class MatrixArithmetic {
    static let convention = "Real linear algebra; row-major matrices, column-vector A*v / row-vector v*A; exact represented arithmetic; no numerical tolerance or approximate singularity test"
    private let math: ExactArithmetic
    private let budget: ExecutionBudget
    private let token: CancellationToken
    private let quantities: QuantityArithmetic
    init(_ math: ExactArithmetic, _ budget: ExecutionBudget, _ token: CancellationToken) {
        self.math = math; self.budget = budget; self.token = token; quantities = QuantityArithmetic(math)
    }
    static func isFunction(_ name: String) -> Bool { ["det", "determinant", "inverse", "inv", "transpose", "trace", "dot", "cross", "norm"].contains(name.netLower) }
    static func validateArity(_ name: String, _ count: Int) throws {
        let expected = ["dot", "cross"].contains(name.netLower) ? 2 : 1
        if count != expected { throw CalcError.format("\(name) expects \(expected) argument(s)") }
    }
    static func isCollection(_ value: SheetValue) -> Bool { value.kind == .list || value.kind == .matrix }
    private func step() throws { try budget.step(token) }
    private func op(_ operation: String, _ a: NumericValue, _ b: NumericValue) throws -> NumericValue { try step(); return try quantities.binary(operation, a, b) }
    private func mul(_ a: ExactNumber, _ b: ExactNumber) throws -> ExactNumber { try step(); return try math.multiply(a, b) }
    private func sub(_ a: ExactNumber, _ b: ExactNumber) throws -> ExactNumber { try step(); return try math.subtract(a, b) }
    private func div(_ a: ExactNumber, _ b: ExactNumber) throws -> ExactNumber { try step(); return try math.divide(a, b) }
    private static func vector(_ values: [NumericValue]) throws -> SheetValue { .list(try SheetList(values.map { .number($0) })) }
    /// C# builds the cells lazily, row by row, while the matrix validates them; every cell here comes from
    /// already-validated operands, so validating after computing all of them gives the same result.
    private static func matrix(_ rows: Int, _ columns: Int, _ cell: (Int, Int) throws -> NumericValue) throws -> SheetValue {
        .matrix(try SheetMatrix((0..<rows).map { r in try SheetList((0..<columns).map { c in .number(try cell(r, c)) }) }))
    }
    private func readVector(_ value: SheetValue) throws -> [NumericValue] {
        guard case .list(let list) = value, !list.values.isEmpty else { throw CalcError.arithmetic("Expected a nonempty flat numeric vector") }
        var result: [NumericValue] = []; result.reserveCapacity(list.values.count); var first: NumericValue?
        for item in list.values {
            try step()
            guard case .number(let number) = item else { throw CalcError.arithmetic("Vectors require real numeric quantities, not money or dates") }
            try SheetMatrix.validateEntry(number, first); if first == nil { first = number }; result.append(number)
        }
        // Validate all nonempty kind labels against each other, including when the first value has none.
        if Set(result.map(\.quantityKind).filter { !$0.isEmpty }).count > 1 { throw CalcError.arithmetic("Vector contains incompatible quantity kinds") }
        return result
    }
    private func map(_ value: SheetValue, _ transform: (NumericValue) throws -> NumericValue) throws -> SheetValue {
        func apply(_ number: NumericValue) throws -> NumericValue { try step(); return try transform(number) }
        if case .matrix(let m) = value { return try MatrixArithmetic.matrix(m.rowCount, m.columnCount) { r, c in try apply(m[r, c]) } }
        return try MatrixArithmetic.vector(try readVector(value).map(apply))
    }
    func unary(_ operation: String, _ value: SheetValue) throws -> SheetValue {
        if operation != "+" && operation != "-" { throw CalcError.arithmetic("Matrix/vector unary operators are + and -") }
        return try map(value) { try quantities.unary(operation, $0) }
    }
    func round(_ kind: RoundingKind, _ value: SheetValue, _ precision: SheetValue) throws -> SheetValue {
        try map(value) { try quantities.round(kind, $0, try precision.number, token) }
    }
    func binary(_ operation: String, _ a: SheetValue, _ b: SheetValue) throws -> SheetValue {
        if operation == "+" || operation == "-" {
            if case .matrix(let x) = a, case .matrix(let y) = b {
                if x.rowCount != y.rowCount || x.columnCount != y.columnCount { throw CalcError.arithmetic("Matrix addition/subtraction requires equal shapes") }
                return try MatrixArithmetic.matrix(x.rowCount, x.columnCount) { r, c in try op(operation, x[r, c], y[r, c]) }
            }
            let left = try readVector(a), right = try readVector(b)
            if left.count != right.count { throw CalcError.arithmetic("Vector addition/subtraction requires equal lengths") }
            return try MatrixArithmetic.vector(try left.indices.map { try op(operation, left[$0], right[$0]) })
        }
        if operation == "*", case .matrix(let x) = a, case .matrix(let y) = b {
            if x.columnCount != y.rowCount { throw CalcError.arithmetic("Matrix product requires left columns = right rows") }
            return try MatrixArithmetic.matrix(x.rowCount, y.columnCount) { r, c in try inner(x.columnCount, { x[r, $0] }, { y[$0, c] }) }
        }
        if operation == "*", case .matrix(let x) = a, b.kind == .list {
            let vector = try readVector(b)
            if x.columnCount != vector.count { throw CalcError.arithmetic("Matrix-vector product requires left columns = vector length") }
            return try MatrixArithmetic.vector(try (0..<x.rowCount).map { r in try inner(vector.count, { x[r, $0] }, { vector[$0] }) })
        }
        if operation == "*", a.kind == .list, case .matrix(let y) = b {
            let vector = try readVector(a)
            if vector.count != y.rowCount { throw CalcError.arithmetic("Vector-matrix product requires vector length = right rows") }
            return try MatrixArithmetic.vector(try (0..<y.columnCount).map { c in try inner(vector.count, { vector[$0] }, { y[$0, c] }) })
        }
        if (operation == "*" || operation == "/") && MatrixArithmetic.isCollection(a), case .number(let scalar) = b {
            return try map(a) { try op(operation, $0, scalar) }
        }
        if operation == "*", case .number(let scalar) = a, MatrixArithmetic.isCollection(b) {
            return try map(b) { try op(operation, scalar, $0) }
        }
        throw CalcError.arithmetic("Unsupported matrix/vector operation; use dot for two vectors and inverse explicitly for matrix division")
    }
    private func inner(_ count: Int, _ a: (Int) -> NumericValue, _ b: (Int) -> NumericValue) throws -> NumericValue {
        var sum = try op("*", a(0), b(0))
        for i in stride(from: 1, to: count, by: 1) { sum = try op("+", sum, try op("*", a(i), b(i))) }
        return sum
    }
    func function(_ name: String, _ args: [SheetValue]) throws -> SheetValue {
        try MatrixArithmetic.validateArity(name, args.count); let key = name.netLower
        if key == "dot" || key == "cross" || key == "norm" {
            let a = try readVector(args[0])
            if key == "norm" { try step(); return .number(try quantities.function("sqrt", [try inner(a.count, { a[$0] }, { a[$0] })])) }
            let b = try readVector(args[1])
            if a.count != b.count { throw CalcError.arithmetic("Vector lengths must match") }
            if key == "dot" { return .number(try inner(a.count, { a[$0] }, { b[$0] })) }
            if a.count != 3 { throw CalcError.arithmetic("Cross product requires three-component vectors") }
            return try MatrixArithmetic.vector(try (0..<3).map { i in
                try op("-", try op("*", a[(i + 1) % 3], b[(i + 2) % 3]), try op("*", a[(i + 2) % 3], b[(i + 1) % 3]))
            })
        }
        guard case .matrix(let matrix) = args[0] else { throw CalcError.arithmetic("\(name) requires a matrix written as [[row], [row]]") }
        if key == "transpose" { return try MatrixArithmetic.matrix(matrix.columnCount, matrix.rowCount) { r, c in matrix[c, r] } }
        if matrix.rowCount != matrix.columnCount { throw CalcError.arithmetic("\(name) requires a square matrix") }
        let n = matrix.rowCount
        if key == "trace" {
            var sum = matrix[0, 0]
            for i in stride(from: 1, to: n, by: 1) { sum = try op("+", sum, matrix[i, i]) }
            // Approximation is a provenance property of the entire operand, including off-diagonal cells.
            return .number(sum.with { $0.isApproximate = matrix.isApproximate })
        }
        var cells = [[ExactNumber]](repeating: [ExactNumber](repeating: .zero, count: n), count: n), inverse = cells
        for r in 0..<n { for c in 0..<n { try step(); cells[r][c] = matrix[r, c].exact; inverse[r][c] = r == c ? ExactArithmetic.one : .zero } }
        let wantDeterminant = key == "det" || key == "determinant"
        var determinant = ExactArithmetic.one
        for pivot in 0..<n {
            try step(); var row = pivot
            while row < n && cells[row][pivot].isZero { try step(); row += 1 }
            if row == n {
                if wantDeterminant { return .number(MatrixArithmetic.wrap(.zero, try matrix[0, 0].unit?.power(Rational(n)), matrix.isApproximate)) }
                throw CalcError.arithmetic("Singular matrix has no inverse")
            }
            if row != pivot {
                for c in 0..<n {
                    try step()
                    (cells[row][c], cells[pivot][c]) = (cells[pivot][c], cells[row][c]); (inverse[row][c], inverse[pivot][c]) = (inverse[pivot][c], inverse[row][c])
                }
                if wantDeterminant { determinant = try mul(determinant, ExactNumber(Rational(-1))) }
            }
            let divisor = cells[pivot][pivot]
            if wantDeterminant {
                determinant = try mul(determinant, divisor)
                for r in stride(from: pivot + 1, to: n, by: 1) {
                    let factor = try div(cells[r][pivot], divisor); cells[r][pivot] = .zero
                    for c in stride(from: pivot + 1, to: n, by: 1) { cells[r][c] = try sub(cells[r][c], try mul(factor, cells[pivot][c])) }
                }
            } else {
                for c in 0..<n { cells[pivot][c] = try div(cells[pivot][c], divisor); inverse[pivot][c] = try div(inverse[pivot][c], divisor) }
                for r in 0..<n {
                    if r == pivot { continue }
                    let factor = cells[r][pivot]
                    if factor.isZero { continue }
                    for c in 0..<n {
                        cells[r][c] = try sub(cells[r][c], try mul(factor, cells[pivot][c])); inverse[r][c] = try sub(inverse[r][c], try mul(factor, inverse[pivot][c]))
                    }
                }
            }
        }
        if wantDeterminant { return .number(MatrixArithmetic.wrap(determinant, try matrix[0, 0].unit?.power(Rational(n)), matrix.isApproximate)) }
        return try MatrixArithmetic.matrix(n, n) { r, c in MatrixArithmetic.wrap(inverse[r][c], try matrix[0, 0].unit?.power(Rational(-1)), matrix.isApproximate) }
    }
    private static func wrap(_ number: ExactNumber, _ unit: UnitExpression?, _ approximate: Bool) -> NumericValue {
        let value = unit == nil || unit!.dimension == .none ? NumericValue(number) : NumericValue(number, unit: unit!)
        return value.with { $0.isApproximate = approximate }
    }
}
