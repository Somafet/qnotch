import Foundation

/// The C# engine's exception types. A sheet line shows `message` exactly as C# shows `Exception.Message`.
///
/// C# `catch (Exception e) when (e is FormatException or ArithmeticException)` becomes
/// `catch let error as CalcError where error.isFormatOrArithmetic`.
public enum CalcError: Error, Equatable, CustomStringConvertible {
    /// FormatException.
    case format(String)
    /// ArithmeticException, including DivideByZeroException and OverflowException.
    case arithmetic(String)
    /// ArgumentException (and ArgumentOutOfRangeException).
    case argument(String)
    /// SheetComputationLimitException, an ArgumentException.
    case computationLimit
    /// InvalidDataException.
    case invalidData(String)
    /// IOException and its subclasses.
    case io(String)
    /// InvalidOperationException.
    case invalidOperation(String)
    /// OperationCanceledException.
    case cancelled
    /// A part of the C# engine that is not ported yet. Shown like an arithmetic error.
    case notPorted(String)

    public var message: String {
        switch self {
        case .format(let m), .arithmetic(let m), .argument(let m), .invalidData(let m), .io(let m), .invalidOperation(let m): return m
        case .computationLimit: return "Sheet computation limit exceeded"
        case .cancelled: return "The operation was canceled."
        case .notPorted(let what): return "Not available on this Mac yet: " + what
        }
    }
    public var description: String { message }
    /// `e is FormatException or ArithmeticException`.
    public var isFormatOrArithmetic: Bool {
        switch self { case .format, .arithmetic, .notPorted: return true; default: return false }
    }
    public var isArithmetic: Bool { if case .arithmetic = self { return true }; if case .notPorted = self { return true }; return false }
    public var isFormat: Bool { if case .format = self { return true }; return false }
    /// `e is ArgumentException` (SheetComputationLimitException derives from it).
    public var isArgument: Bool { switch self { case .argument, .computationLimit: return true; default: return false } }

    /// .NET's own messages, for places where C# lets a runtime exception's message reach the user.
    static let divideByZeroMessage = "Attempted to divide by zero."
    static let overflowInt32Message = "Value was either too large or too small for an Int32."
    static let overflowInt64Message = "Value was either too large or too small for an Int64."
}

/// A cooperative cancellation token (C# CancellationToken). `none` never cancels.
public final class CancellationToken: @unchecked Sendable {
    public static let none = CancellationToken(canCancel: false)
    private let lock = NSLock()
    private var cancelled = false
    private let canCancel: Bool
    public init() { canCancel = true }
    private init(canCancel: Bool) { self.canCancel = canCancel }
    public var isCancellationRequested: Bool {
        guard canCancel else { return false }
        lock.lock(); defer { lock.unlock() }; return cancelled
    }
    public func cancel() { guard canCancel else { return }; lock.lock(); cancelled = true; lock.unlock() }
    @inline(__always) public func throwIfCancellationRequested() throws {
        if canCancel && isCancellationRequested { throw CalcError.cancelled }
    }
}
