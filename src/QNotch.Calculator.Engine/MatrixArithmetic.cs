namespace Calc.Core;

internal sealed class MatrixArithmetic(ExactArithmetic math, ExecutionBudget budget, CancellationToken token)
{
    private readonly QuantityArithmetic quantities = new(math);
    internal const string Convention = "Real linear algebra; row-major matrices, column-vector A*v / row-vector v*A; exact represented arithmetic; no numerical tolerance or approximate singularity test";
    internal static bool IsFunction(string name) => name.ToLowerInvariant() is "det" or "determinant" or "inverse" or "inv" or "transpose" or "trace" or "dot" or "cross" or "norm";
    internal static void ValidateArity(string name, int count)
    {
        var expected = name.ToLowerInvariant() is "dot" or "cross" ? 2 : 1;
        if (count != expected) throw new FormatException($"{name} expects {expected} argument(s)");
    }
    internal static bool IsCollection(SheetValue value) => value.Kind is SheetValueKind.List or SheetValueKind.Matrix;
    private void Step() => budget.Step(token);
    private NumericValue Op(string op, NumericValue a, NumericValue b) { Step(); return quantities.Binary(op, a, b); }
    private ExactNumber Mul(ExactNumber a, ExactNumber b) { Step(); return math.Multiply(a, b); }
    private ExactNumber Sub(ExactNumber a, ExactNumber b) { Step(); return math.Subtract(a, b); }
    private ExactNumber Div(ExactNumber a, ExactNumber b) { Step(); return math.Divide(a, b); }
    private static SheetValue Vector(IEnumerable<NumericValue> values) => new(new SheetList(values.Select(value => new SheetValue(value))));
    private static SheetValue Matrix(int rows, int columns, Func<int, int, NumericValue> cell)
        => new(new SheetMatrix(Enumerable.Range(0, rows).Select(r => new SheetList(Enumerable.Range(0, columns).Select(c => new SheetValue(cell(r, c)))))));
    private NumericValue[] ReadVector(SheetValue value)
    {
        if (value.Kind != SheetValueKind.List || value.List.Values.Count == 0) throw new ArithmeticException("Expected a nonempty flat numeric vector");
        var result = new NumericValue[value.List.Values.Count]; NumericValue? first = null;
        for (var i = 0; i < result.Length; i++)
        {
            Step(); var item = value.List.Values[i];
            if (item.Kind != SheetValueKind.Number) throw new ArithmeticException("Vectors require real numeric quantities, not money or dates");
            SheetMatrix.ValidateEntry(item.Number, first); first ??= item.Number; result[i] = item.Number;
        }
        // Validate all nonempty kind labels against each other, including when the first value has none.
        if (result.Select(item => item.QuantityKind).Where(kind => kind.Length > 0).Distinct().Skip(1).Any()) throw new ArithmeticException("Vector contains incompatible quantity kinds");
        return result;
    }
    private SheetValue Map(SheetValue value, Func<NumericValue, NumericValue> transform)
    {
        NumericValue Apply(NumericValue number) { Step(); return transform(number); }
        if (value.Kind == SheetValueKind.Matrix) return Matrix(value.Matrix.RowCount, value.Matrix.ColumnCount, (r, c) => Apply(value.Matrix[r, c]));
        return Vector(ReadVector(value).Select(Apply));
    }
    internal SheetValue Unary(string op, SheetValue value)
    {
        if (op is not "+" and not "-") throw new ArithmeticException("Matrix/vector unary operators are + and -");
        return Map(value, number => quantities.Unary(op, number));
    }
    internal SheetValue Round(RoundingKind kind, SheetValue value, SheetValue precision)
        => Map(value, number => quantities.Round(kind, number, precision.Number, token));
    internal SheetValue Binary(string op, SheetValue a, SheetValue b)
    {
        if (op is "+" or "-")
        {
            if (a.Kind == SheetValueKind.Matrix && b.Kind == SheetValueKind.Matrix)
            {
                var x = a.Matrix; var y = b.Matrix;
                if (x.RowCount != y.RowCount || x.ColumnCount != y.ColumnCount) throw new ArithmeticException("Matrix addition/subtraction requires equal shapes");
                return Matrix(x.RowCount, x.ColumnCount, (r, c) => Op(op, x[r, c], y[r, c]));
            }
            var left = ReadVector(a); var right = ReadVector(b);
            if (left.Length != right.Length) throw new ArithmeticException("Vector addition/subtraction requires equal lengths");
            return Vector(left.Select((value, i) => Op(op, value, right[i])));
        }
        if (op == "*" && a.Kind == SheetValueKind.Matrix && b.Kind == SheetValueKind.Matrix)
        {
            var x = a.Matrix; var y = b.Matrix;
            if (x.ColumnCount != y.RowCount) throw new ArithmeticException("Matrix product requires left columns = right rows");
            return Matrix(x.RowCount, y.ColumnCount, (r, c) => Inner(x.ColumnCount, k => x[r, k], k => y[k, c]));
        }
        if (op == "*" && a.Kind == SheetValueKind.Matrix && b.Kind == SheetValueKind.List)
        {
            var x = a.Matrix; var vector = ReadVector(b);
            if (x.ColumnCount != vector.Length) throw new ArithmeticException("Matrix-vector product requires left columns = vector length");
            return Vector(Enumerable.Range(0, x.RowCount).Select(r => Inner(vector.Length, k => x[r, k], k => vector[k])));
        }
        if (op == "*" && a.Kind == SheetValueKind.List && b.Kind == SheetValueKind.Matrix)
        {
            var vector = ReadVector(a); var y = b.Matrix;
            if (vector.Length != y.RowCount) throw new ArithmeticException("Vector-matrix product requires vector length = right rows");
            return Vector(Enumerable.Range(0, y.ColumnCount).Select(c => Inner(vector.Length, k => vector[k], k => y[k, c])));
        }
        if (op is "*" or "/" && IsCollection(a) && b.Kind == SheetValueKind.Number)
            return Map(a, number => Op(op, number, b.Number));
        if (op == "*" && a.Kind == SheetValueKind.Number && IsCollection(b))
            return Map(b, number => Op(op, a.Number, number));
        throw new ArithmeticException("Unsupported matrix/vector operation; use dot for two vectors and inverse explicitly for matrix division");
    }
    private NumericValue Inner(int count, Func<int, NumericValue> a, Func<int, NumericValue> b)
    {
        var sum = Op("*", a(0), b(0));
        for (var i = 1; i < count; i++) sum = Op("+", sum, Op("*", a(i), b(i)));
        return sum;
    }
    internal SheetValue Function(string name, SheetValue[] args)
    {
        ValidateArity(name, args.Length); var key = name.ToLowerInvariant();
        if (key is "dot" or "cross" or "norm")
        {
            var a = ReadVector(args[0]);
            if (key == "norm") { Step(); return quantities.Function("sqrt", [Inner(a.Length, i => a[i], i => a[i])]); }
            var b = ReadVector(args[1]);
            if (a.Length != b.Length) throw new ArithmeticException("Vector lengths must match");
            if (key == "dot") return Inner(a.Length, i => a[i], i => b[i]);
            if (a.Length != 3) throw new ArithmeticException("Cross product requires three-component vectors");
            return Vector(Enumerable.Range(0, 3).Select(i => Op("-", Op("*", a[(i + 1) % 3], b[(i + 2) % 3]), Op("*", a[(i + 2) % 3], b[(i + 1) % 3]))));
        }
        if (args[0].Kind != SheetValueKind.Matrix) throw new ArithmeticException($"{name} requires a matrix written as [[row], [row]]");
        var matrix = args[0].Matrix;
        if (key == "transpose") return Matrix(matrix.ColumnCount, matrix.RowCount, (r, c) => matrix[c, r]);
        if (matrix.RowCount != matrix.ColumnCount) throw new ArithmeticException($"{name} requires a square matrix");
        var n = matrix.RowCount;
        if (key == "trace")
        {
            var sum = matrix[0, 0]; for (var i = 1; i < n; i++) sum = Op("+", sum, matrix[i, i]);
            // Approximation is a provenance property of the entire operand, including off-diagonal cells.
            return sum with { IsApproximate = matrix.IsApproximate };
        }
        var cells = new ExactNumber[n, n]; var inverse = new ExactNumber[n, n];
        for (var r = 0; r < n; r++) for (var c = 0; c < n; c++) { Step(); cells[r, c] = matrix[r, c].Exact; inverse[r, c] = new(new Rational(r == c ? 1 : 0, 1)); }
        var wantDeterminant = key is "det" or "determinant";
        var determinant = ExactArithmetic.One;
        for (var pivot = 0; pivot < n; pivot++)
        {
            Step(); var row = pivot;
            while (row < n && cells[row, pivot].IsZero) { Step(); row++; }
            if (row == n)
            {
                if (wantDeterminant) return Wrap(default, matrix[0, 0].Unit?.Power(new(n, 1)), matrix.IsApproximate);
                throw new ArithmeticException("Singular matrix has no inverse");
            }
            if (row != pivot)
            {
                for (var c = 0; c < n; c++) { Step(); (cells[row, c], cells[pivot, c]) = (cells[pivot, c], cells[row, c]); (inverse[row, c], inverse[pivot, c]) = (inverse[pivot, c], inverse[row, c]); }
                if (wantDeterminant) determinant = Mul(determinant, new(new Rational(-1, 1)));
            }
            var divisor = cells[pivot, pivot];
            if (wantDeterminant)
            {
                determinant = Mul(determinant, divisor);
                for (var r = pivot + 1; r < n; r++)
                {
                    var factor = Div(cells[r, pivot], divisor); cells[r, pivot] = default;
                    for (var c = pivot + 1; c < n; c++) cells[r, c] = Sub(cells[r, c], Mul(factor, cells[pivot, c]));
                }
            }
            else
            {
                for (var c = 0; c < n; c++) { cells[pivot, c] = Div(cells[pivot, c], divisor); inverse[pivot, c] = Div(inverse[pivot, c], divisor); }
                for (var r = 0; r < n; r++)
                {
                    if (r == pivot) continue;
                    var factor = cells[r, pivot];
                    if (factor.IsZero) continue;
                    for (var c = 0; c < n; c++) { cells[r, c] = Sub(cells[r, c], Mul(factor, cells[pivot, c])); inverse[r, c] = Sub(inverse[r, c], Mul(factor, inverse[pivot, c])); }
                }
            }
        }
        if (wantDeterminant) return Wrap(determinant, matrix[0, 0].Unit?.Power(new(n, 1)), matrix.IsApproximate);
        return Matrix(n, n, (r, c) => Wrap(inverse[r, c], matrix[0, 0].Unit?.Power(new(-1, 1)), matrix.IsApproximate));
    }
    private static NumericValue Wrap(ExactNumber number, UnitExpression? unit, bool approximate)
        => (unit is null || unit.Dimension == default ? new NumericValue(number) : new NumericValue(number, unit)) with { IsApproximate = approximate };
}
