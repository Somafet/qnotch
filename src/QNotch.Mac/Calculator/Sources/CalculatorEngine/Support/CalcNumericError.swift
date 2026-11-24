/// Numeric failures that the C# engine raises as exceptions (for example OverflowException); the core maps them.
enum CalcNumericError: Error, Equatable {
    case overflow(String)
}
