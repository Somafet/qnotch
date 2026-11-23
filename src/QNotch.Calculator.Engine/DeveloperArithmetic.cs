using System.Globalization;
using System.Numerics;
using System.Text;

namespace Calc.Core;

internal sealed class DeveloperArithmetic(ExecutionBudget budget, CancellationToken token)
{
    internal const string Convention = "Exact represented helper values; conversions retain stored data; permission and Unicode queries do not inspect or change OS state";
    internal static bool IsFunction(string name) => name.ToLowerInvariant() is "color" or "colour" or "rgb" or "rgba" or "hsl" or "hsla" or "colourhex" or "chmod" or "modebits" or "modeoctal" or "aspect" or "asratio" or "unicode" or "codepoint" or "chr";
    internal static bool IsTextFunction(string name) => name.ToLowerInvariant() is "color" or "colour" or "chmod" or "unicode";
    internal static void ValidateArity(string name, int count)
    {
        var valid = name.ToLowerInvariant() switch { "rgb" or "hsl" => count is 1 or 3 or 4, "rgba" or "hsla" => count == 4, "aspect" => count == 2, _ => count == 1 };
        if (!valid) throw new FormatException($"{name} has an invalid argument count");
    }
    private void Step() => budget.Step(token);
    private static NumericValue Number(SheetValue value) => value.Kind == SheetValueKind.Integer ? new(new Rational(value.Integer.Value, 1)) : value.Kind == SheetValueKind.Number ? value.Number : throw new ArithmeticException("Expected a numeric helper argument");
    private static Rational Scalar(SheetValue value)
    { var n = Number(value); if (n.Unit is not null || !n.IsRational || n.IsApproximate) throw new ArithmeticException("Expected an exact dimensionless rational"); return n.Exact.Rational; }
    internal SheetValue ColourLiteral(string text)
    {
        Step(); var digits = text.StartsWith('#') ? text[1..] : text;
        if (digits.Length is not (3 or 4 or 6 or 8) || digits.Any(c => !char.IsAsciiHexDigit(c))) throw new FormatException("Expected #RGB, #RGBA, #RRGGBB or #RRGGBBAA");
        if (digits.Length <= 4) digits = string.Concat(digits.Select(c => new string(c, 2)));
        var channels = Enumerable.Range(0, digits.Length / 2).Select(i => int.Parse(digits.AsSpan(i*2,2),NumberStyles.HexNumber,CultureInfo.InvariantCulture)).ToArray();
        return new(new ColourValue(new(channels[0],255),new(channels[1],255),new(channels[2],255),new(channels.Length==4?channels[3]:255,255),ColourPresentation.Hex));
    }
    internal SheetValue Function(string name, SheetValue[] args)
    {
        Step(); ValidateArity(name,args.Length); var key = name.ToLowerInvariant();
        if (key is "color" or "colour") return args[0].Kind == SheetValueKind.Colour ? args[0] : ColourLiteral(args[0].Text.Value);
        if (key is "rgb" or "rgba" or "hsl" or "hsla" or "colourhex")
        {
            var style = key is "rgb" or "rgba" ? ColourPresentation.Rgb : key is "hsl" or "hsla" ? ColourPresentation.Hsl : ColourPresentation.Hex;
            if (args.Length == 1) return new(args[0].Colour.WithPresentation(style));
            Rational Ratio(SheetValue value, bool rgb)
            { var n=Number(value);var r=Scalar(value);return n.IsPercentage?r:r/new Rational(rgb?255:100,1); }
            var alpha = args.Length == 4 ? Scalar(args[3]) : new Rational(1,1);
            if (style == ColourPresentation.Rgb) return new(new ColourValue(Ratio(args[0],true),Ratio(args[1],true),Ratio(args[2],true),alpha,style));
            if (Number(args[0]).IsPercentage) throw new ArithmeticException("Hue is a degree count, not a percentage");
            var hue=DeveloperSource.Mod(Scalar(args[0]),360);var sat=Ratio(args[1],false);var light=Ratio(args[2],false);
            if(sat.Numerator<0||sat.Numerator>sat.Denominator||light.Numerator<0||light.Numerator>light.Denominator)throw new ArithmeticException("HSL percentages must be 0–100%");
            var one=new Rational(1,1);var c=(one-DeveloperSource.Abs(new Rational(2,1)*light-one))*sat;var hp=hue/new Rational(60,1);var x=c*(one-DeveloperSource.Abs(DeveloperSource.Mod(hp,2)-one));var m=light-c/new Rational(2,1);
            var sector=(int)(hp.Numerator/hp.Denominator);var z=default(Rational);
            var (r,g,b)=sector switch{0=>(c,x,z),1=>(x,c,z),2=>(z,c,x),3=>(z,x,c),4=>(x,z,c),_=>(c,z,x)};
            return new(new ColourValue(r+m,g+m,b+m,alpha,style));
        }
        if (key == "chmod")
        {
            if(args[0].Kind==SheetValueKind.Permission)return new(new PermissionValue(args[0].Permission.Bits,!args[0].Permission.ShowOctal));
            if(args[0].Kind==SheetValueKind.Integer){var bits=IntegerArithmetic.Require(args[0]);if(bits<0||bits>4095)throw new ArithmeticException("Permission bits out of range");return new(new PermissionValue((int)bits));}
            var text=args[0].Kind==SheetValueKind.Text?args[0].Text.Value:IntegerArithmetic.Require(args[0]).ToString(CultureInfo.InvariantCulture);
            if(text.Length is >=1 and <=4 && text.All(c=>c is >= '0' and <= '7'))return new(new PermissionValue(Convert.ToInt32(text,8)));
            if(text.Length!=9)throw new FormatException("Expected octal digits or nine symbolic permission characters");
            var mode=0;
            for(var group=0;group<3;group++)
            {
                Step();var p=group*3;var r=text[p];var w=text[p+1];var e=text[p+2];
                if(r is not ('r' or '-')||w is not ('w' or '-')||(group<2?e is not ('x' or '-' or 's' or 'S'):e is not ('x' or '-' or 't' or 'T')))throw new FormatException("Invalid symbolic permission character");
                var n=(r=='r'?4:0)+(w=='w'?2:0)+(e is 'x' or 's' or 't'?1:0);mode|=n<<(6-group*3);
                if(e is 's' or 'S' or 't' or 'T')mode|=group==0?2048:group==1?1024:512;
            }
            return new(new PermissionValue(mode,true));
        }
        if(key=="modebits")return new(new Rational(args[0].Permission.Bits,1));
        if(key=="modeoctal")return new(new PermissionValue(args[0].Permission.Bits,true));
        if(key=="asratio") { if(args[0].IsPercentage) throw new ArithmeticException("Aspect ratio requires an ordinary scalar"); return args[0].Kind==SheetValueKind.Aspect?args[0]:new(new AspectValue(Scalar(args[0]))); }
        if(key=="aspect")
        {
            var w=Number(args[0]);var h=Number(args[1]);
            if(w.IsPercentage||h.IsPercentage||w.IsApproximate||h.IsApproximate||!w.IsRational||!h.IsRational||w.Unit?.Dimension!=h.Unit?.Dimension||w.QuantityKind!=h.QuantityKind||w.Unit?.IsTemperaturePoint==true||h.Unit?.IsTemperaturePoint==true)throw new ArithmeticException("Aspect dimensions must be exact compatible quantities");
            if(w.Exact.Rational.Numerator<=0||h.Exact.Rational.Numerator<=0)throw new ArithmeticException("Aspect dimensions must be positive");
            return new(new AspectValue(w.Exact.Rational/h.Exact.Rational));
        }
        if(key=="unicode")
        {
            if(args[0].Kind==SheetValueKind.Unicode)return new(new UnicodeValue(args[0].Unicode.Scalars,false));
            var values=new List<int>();foreach(var rune in args[0].Text.Value.EnumerateRunes()){Step();if(values.Count==256)throw new ArithmeticException("Unicode inspection exceeds 256 scalars");values.Add(rune.Value);}
            return new(new UnicodeValue(values,false));
        }
        if(key is "codepoint" or "chr")
        {
            var cp=IntegerArithmetic.Require(args[0]);if(cp<0||cp>0x10ffff||!Rune.IsValid((int)cp))throw new ArithmeticException("Expected a Unicode scalar outside the surrogate range");
            return key=="chr"?new(new TextValue(new Rune((int)cp).ToString())):new(new UnicodeValue([(int)cp],true));
        }
        throw new FormatException("Unknown developer helper");
    }
}
