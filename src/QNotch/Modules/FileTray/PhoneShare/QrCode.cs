using System.Text;

namespace QNotch.Modules.FileTray;

/// <summary>
/// QR code encoder for short text (the session URL): byte mode, error correction level M, versions 1 to 10 (up to 213 bytes).
/// Follows ISO/IEC 18004: Reed-Solomon blocks interleaved, then the mask with the lowest penalty. The matrix excludes the quiet zone.
/// </summary>
public static class QrCode
{
    public const int MaxVersion = 10;

    // Level M, index = version.
    static readonly int[] EccPerBlock = [0, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26];
    static readonly int[] Blocks = [0, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5];

    /// <summary>Dark modules as <c>[y, x]</c>. Throws when the text does not fit in version 10. <paramref name="mask"/> -1 picks the best.</summary>
    public static bool[,] Encode(string text, int mask = -1) => Encode(Encoding.UTF8.GetBytes(text), mask);

    public static bool[,] Encode(byte[] data, int mask = -1)
    {
        var version = 1;
        while (version <= MaxVersion && DataBits(version) < 4 + CountBits(version) + data.Length * 8) version++;
        if (version > MaxVersion) throw new ArgumentException($"Too long for a QR code: {data.Length} bytes");

        // Mode, count, data, terminator, byte padding, then alternating pad bytes.
        var bits = new BitList();
        bits.Add(0b0100, 4);
        bits.Add(data.Length, CountBits(version));
        foreach (var b in data) bits.Add(b, 8);
        var capacity = DataBits(version);
        bits.Add(0, Math.Min(4, capacity - bits.Count));
        bits.Add(0, (8 - bits.Count % 8) % 8);
        for (var pad = 0xEC; bits.Count < capacity; pad ^= 0xEC ^ 0x11) bits.Add(pad, 8);

        var m = new Matrix(version);
        m.DrawFunctionPatterns();
        m.DrawCodewords(Interleave(version, bits.ToBytes()));

        if (mask < 0)
        {
            var best = int.MaxValue;
            for (var i = 0; i < 8; i++)
            {
                m.ApplyMask(i);
                m.DrawFormatBits(i);
                var p = m.Penalty();
                if (p < best) { best = p; mask = i; }
                m.ApplyMask(i); // XOR undoes it
            }
        }
        m.ApplyMask(mask);
        m.DrawFormatBits(mask);
        return m.Modules;
    }

    static int CountBits(int version) => version <= 9 ? 8 : 16;

    /// <summary>Modules left for data and error correction once the function patterns are placed.</summary>
    static int RawModules(int version)
    {
        var r = (16 * version + 128) * version + 64;
        if (version >= 2)
        {
            var align = version / 7 + 2;
            r -= (25 * align - 10) * align - 55;
            if (version >= 7) r -= 36;
        }
        return r;
    }

    static int DataBits(int version) => (RawModules(version) / 8 - EccPerBlock[version] * Blocks[version]) * 8;

    /// <summary>Splits the data into blocks, appends each block's error correction and interleaves the codewords.</summary>
    static byte[] Interleave(int version, byte[] data)
    {
        int count = Blocks[version], ecc = EccPerBlock[version], raw = RawModules(version) / 8;
        int shortBlocks = count - raw % count, shortLen = raw / count;
        var divisor = Generator(ecc);
        var blocks = new byte[count][];
        for (int i = 0, k = 0; i < count; i++)
        {
            var len = shortLen - ecc + (i < shortBlocks ? 0 : 1);
            var block = new byte[shortLen + 1];
            Array.Copy(data, k, block, 0, len);
            k += len;
            Remainder(block.AsSpan(0, len), divisor).CopyTo(block, shortLen + 1 - ecc);
            blocks[i] = block;
        }
        var result = new byte[raw];
        var n = 0;
        for (var i = 0; i < shortLen + 1; i++)
            for (var j = 0; j < count; j++)
                if (i != shortLen - ecc || j >= shortBlocks) result[n++] = blocks[j][i]; // short blocks have a gap where long ones hold data
        return result;
    }

    static byte[] Generator(int degree)
    {
        var r = new byte[degree];
        r[degree - 1] = 1;
        byte root = 1;
        for (var i = 0; i < degree; i++)
        {
            for (var j = 0; j < degree; j++)
            {
                r[j] = Mul(r[j], root);
                if (j + 1 < degree) r[j] ^= r[j + 1];
            }
            root = Mul(root, 2);
        }
        return r;
    }

    static byte[] Remainder(ReadOnlySpan<byte> data, byte[] divisor)
    {
        var r = new byte[divisor.Length];
        foreach (var b in data)
        {
            var factor = (byte)(b ^ r[0]);
            Array.Copy(r, 1, r, 0, r.Length - 1);
            r[^1] = 0;
            for (var i = 0; i < r.Length; i++) r[i] ^= Mul(divisor[i], factor);
        }
        return r;
    }

    /// <summary>Multiplication in GF(2^8) modulo x^8 + x^4 + x^3 + x^2 + 1.</summary>
    static byte Mul(byte x, byte y)
    {
        var z = 0;
        for (var i = 7; i >= 0; i--)
        {
            z = (z << 1) ^ ((z >> 7) * 0x11D);
            z ^= ((y >> i) & 1) * x;
        }
        return (byte)z;
    }

    sealed class BitList
    {
        readonly List<bool> _bits = new();
        public int Count => _bits.Count;
        public void Add(int value, int length) { for (var i = length - 1; i >= 0; i--) _bits.Add(((value >> i) & 1) != 0); }
        public byte[] ToBytes()
        {
            var r = new byte[_bits.Count / 8];
            for (var i = 0; i < _bits.Count; i++) if (_bits[i]) r[i >> 3] |= (byte)(0x80 >> (i & 7));
            return r;
        }
    }

    sealed class Matrix
    {
        readonly int _version, _size;
        readonly bool[,] _function;
        public bool[,] Modules { get; }

        public Matrix(int version)
        {
            _version = version;
            _size = version * 4 + 17;
            Modules = new bool[_size, _size];
            _function = new bool[_size, _size];
        }

        void Set(int x, int y, bool dark) { Modules[y, x] = dark; _function[y, x] = true; }

        public void DrawFunctionPatterns()
        {
            for (var i = 0; i < _size; i++) { Set(6, i, i % 2 == 0); Set(i, 6, i % 2 == 0); }
            Finder(3, 3);
            Finder(_size - 4, 3);
            Finder(3, _size - 4);
            var pos = AlignmentPositions();
            for (var i = 0; i < pos.Length; i++)
                for (var j = 0; j < pos.Length; j++)
                    if (!(i == 0 && j == 0 || i == 0 && j == pos.Length - 1 || i == pos.Length - 1 && j == 0)) Alignment(pos[i], pos[j]);
            DrawFormatBits(0); // reserves the area; redrawn with the real mask
            DrawVersion();
        }

        void Finder(int x, int y)
        {
            for (var dy = -4; dy <= 4; dy++)
                for (var dx = -4; dx <= 4; dx++)
                {
                    int xx = x + dx, yy = y + dy, d = Math.Max(Math.Abs(dx), Math.Abs(dy));
                    if (xx >= 0 && xx < _size && yy >= 0 && yy < _size) Set(xx, yy, d != 2 && d != 4);
                }
        }

        void Alignment(int x, int y)
        {
            for (var dy = -2; dy <= 2; dy++)
                for (var dx = -2; dx <= 2; dx++) Set(x + dx, y + dy, Math.Max(Math.Abs(dx), Math.Abs(dy)) != 1);
        }

        int[] AlignmentPositions()
        {
            if (_version == 1) return [];
            var count = _version / 7 + 2;
            var step = (_version * 8 + count * 3 + 5) / (count * 4 - 4) * 2;
            var r = new int[count];
            r[0] = 6;
            for (int i = count - 1, p = _size - 7; i >= 1; i--, p -= step) r[i] = p;
            return r;
        }

        public void DrawFormatBits(int mask)
        {
            var data = 0b00 << 3 | mask; // level M is 00
            var rem = data;
            for (var i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >> 9) * 0x537);
            var bits = (data << 10 | rem) ^ 0x5412;
            for (var i = 0; i <= 5; i++) Set(8, i, Bit(bits, i));
            Set(8, 7, Bit(bits, 6));
            Set(8, 8, Bit(bits, 7));
            Set(7, 8, Bit(bits, 8));
            for (var i = 9; i < 15; i++) Set(14 - i, 8, Bit(bits, i));
            for (var i = 0; i < 8; i++) Set(_size - 1 - i, 8, Bit(bits, i));
            for (var i = 8; i < 15; i++) Set(8, _size - 15 + i, Bit(bits, i));
            Set(8, _size - 8, true); // always dark
        }

        void DrawVersion()
        {
            if (_version < 7) return;
            var rem = _version;
            for (var i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
            var bits = _version << 12 | rem;
            for (var i = 0; i < 18; i++)
            {
                bool bit = Bit(bits, i);
                int a = _size - 11 + i % 3, b = i / 3;
                Set(a, b, bit);
                Set(b, a, bit);
            }
        }

        static bool Bit(int x, int i) => ((x >> i) & 1) != 0;

        /// <summary>Zigzag from the bottom right, two columns at a time, skipping the vertical timing column.</summary>
        public void DrawCodewords(byte[] data)
        {
            var i = 0;
            for (var right = _size - 1; right >= 1; right -= 2)
            {
                if (right == 6) right = 5;
                for (var vert = 0; vert < _size; vert++)
                    for (var j = 0; j < 2; j++)
                    {
                        var x = right - j;
                        var y = ((right + 1) & 2) == 0 ? _size - 1 - vert : vert;
                        if (_function[y, x] || i >= data.Length * 8) continue;
                        Modules[y, x] = ((data[i >> 3] >> (7 - (i & 7))) & 1) != 0;
                        i++;
                    }
            }
        }

        public void ApplyMask(int mask)
        {
            for (var y = 0; y < _size; y++)
                for (var x = 0; x < _size; x++)
                {
                    var flip = mask switch
                    {
                        0 => (x + y) % 2 == 0,
                        1 => y % 2 == 0,
                        2 => x % 3 == 0,
                        3 => (x + y) % 3 == 0,
                        4 => (x / 3 + y / 2) % 2 == 0,
                        5 => x * y % 2 + x * y % 3 == 0,
                        6 => (x * y % 2 + x * y % 3) % 2 == 0,
                        _ => ((x + y) % 2 + x * y % 3) % 2 == 0,
                    };
                    if (flip && !_function[y, x]) Modules[y, x] = !Modules[y, x];
                }
        }

        /// <summary>The four penalty rules of the standard: long runs, 2x2 blocks, finder-like patterns, dark/light imbalance.</summary>
        public int Penalty()
        {
            int p = 0, dark = 0;
            for (var a = 0; a < _size; a++)
            {
                p += LinePenalty(i => Modules[a, i]);
                p += LinePenalty(i => Modules[i, a]);
            }
            for (var y = 0; y < _size; y++)
                for (var x = 0; x < _size; x++)
                {
                    if (Modules[y, x]) dark++;
                    if (x < _size - 1 && y < _size - 1)
                    {
                        var c = Modules[y, x];
                        if (c == Modules[y, x + 1] && c == Modules[y + 1, x] && c == Modules[y + 1, x + 1]) p += 3;
                    }
                }
            var total = _size * _size;
            p += Math.Abs(dark * 20 - total * 10) / total * 10;
            return p;
        }

        int LinePenalty(Func<int, bool> at)
        {
            var p = 0;
            var run = 1;
            for (var i = 1; i <= _size; i++)
            {
                if (i < _size && at(i) == at(i - 1)) { run++; continue; }
                if (run >= 5) p += run - 2;
                run = 1;
            }
            // 1:1:3:1:1 with four light modules on one side (light outside the symbol counts as light).
            bool At(int i) => i >= 0 && i < _size && at(i);
            for (var i = 0; i + 6 < _size; i++)
            {
                if (!(At(i) && !At(i + 1) && At(i + 2) && At(i + 3) && At(i + 4) && !At(i + 5) && At(i + 6))) continue;
                if (!At(i - 1) && !At(i - 2) && !At(i - 3) && !At(i - 4)) p += 40;
                if (!At(i + 7) && !At(i + 8) && !At(i + 9) && !At(i + 10)) p += 40;
            }
            return p;
        }
    }
}
