import Foundation

/// System.Random with an explicit seed (.NET's legacy subtractive generator, Net5CompatSeedImpl), so seeded
/// C# tests generate the same inputs here.
struct NetRandom {
    private var seedArray = [Int32](repeating: 0, count: 56)
    private var inext = 0, inextp = 21
    init(_ seed: Int32) {
        let subtraction = seed == Int32.min ? Int32.max : abs(seed)
        var mj = 161_803_398 - subtraction
        seedArray[55] = mj
        var mk: Int32 = 1, ii = 0
        for _ in 1..<55 {
            ii += 21; if ii >= 55 { ii -= 55 }
            seedArray[ii] = mk
            mk = mj - mk; if mk < 0 { mk += Int32.max }
            mj = seedArray[ii]
        }
        for _ in 1..<5 {
            for i in 1..<56 {
                var n = i + 30; if n >= 55 { n -= 55 }
                seedArray[i] = seedArray[i] &- seedArray[1 + n]
                if seedArray[i] < 0 { seedArray[i] = seedArray[i] &+ Int32.max }
            }
        }
    }
    private mutating func internalSample() -> Int32 {
        var locINext = inext + 1; if locINext >= 56 { locINext = 1 }
        var locINextp = inextp + 1; if locINextp >= 56 { locINextp = 1 }
        var value = seedArray[locINext] &- seedArray[locINextp]
        if value == Int32.max { value -= 1 }
        if value < 0 { value = value &+ Int32.max }
        seedArray[locINext] = value; inext = locINext; inextp = locINextp
        return value
    }
    private mutating func sample() -> Double { Double(internalSample()) * (1.0 / Double(Int32.max)) }
    /// Random.Next(maxValue).
    mutating func next(_ maxValue: Int) -> Int { Int(sample() * Double(maxValue)) }
    /// Random.Next(minValue, maxValue) for ranges below 2^31.
    mutating func next(_ minValue: Int, _ maxValue: Int) -> Int {
        let range = maxValue - minValue
        precondition(range <= Int(Int32.max), "large ranges are not needed by the ported tests")
        return Int(sample() * Double(range)) + minValue
    }
}
