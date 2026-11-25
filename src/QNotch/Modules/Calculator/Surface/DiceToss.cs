using System.Diagnostics;
using System.Globalization;
using System.Numerics;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Animation;
using Calc.Core;

namespace Calc.Windows;

/// <summary>Dice thrown onto the sheet as rigid 3D polyhedra, seen from above in perspective. The throw is a rigid-body
/// simulation run in full when the dice are thrown: gravity, bounces and friction on the sheet, the view's edges as walls,
/// until every die lies flat on a face. Each die is then turned by one of its own symmetries so the rolled number ends up on
/// top; the shape and its motion are unchanged by that turn, so the landing is the simulation's own. Playback follows the
/// recorded path with a per-frame callback only while dice move; resting dice are a static drawing until <see cref="Dismiss"/>.
/// The motion is decoration from a non-cryptographic generator; the numbers shown come only from the document's roll.</summary>
internal sealed class DiceToss : FrameworkElement
{
    public const int MaxShown = 12;
    /// <summary>Longest throw. Dice still moving near the end are laid flat over <see cref="FlattenSeconds"/>.</summary>
    private const double MaxSeconds = 2.4, FlattenSeconds = .3, StepSeconds = 1 / 600.0;
    private const int StepsPerSample = 5;
    private const double SampleSeconds = StepSeconds * StepsPerSample;

    private sealed class Die
    {
        public required DieFace Face; public required Solid Solid; public required string[] Labels; public required int Target;
        /// <summary>Circumradius in pixels.</summary>
        public required float Radius;
        public Vector3 Position, Velocity, Spin; public Quaternion Turn;
        public bool Asleep, Forced; public double Calm; public float Progress;
        public (Vector3 From, Quaternion Turn, (Vector3 Position, Quaternion Turn) To)? Lying;
        /// <summary>A symmetry of the solid, applied before <see cref="Turn"/>, that brings the rolled marker to the top.</summary>
        public Quaternion Symmetry = Quaternion.Identity;
        public readonly List<(Vector3 Position, Quaternion Turn)> Path = [];
        public Vector3 At; public Quaternion Drawn;
        public Vector3[] Corners = [];
    }
    private readonly List<Die> dice = [];
    private readonly Random motion;
    private readonly Stopwatch clock = new();
    /// <summary>Test mode: the caller advances time with <see cref="Step"/>; no per-frame hook and no fade.</summary>
    private readonly bool manual;
    private double duration, size = 60;
    private int generation;
    private Action? settled;
    private Color body = Colors.Teal; private Brush ink = Brushes.White; private Pen mark = new(Brushes.White, 3);
    private Pen edge = new(Brushes.Black, 1);
    private Typeface typeface = new("Segoe UI");
    private readonly Dictionary<int, Brush> shades = [];
    private readonly Dictionary<string, FormattedText> labels = [];
    /// <summary>The camera looks straight down from <see cref="height"/> above the middle of the sheet; the sheet is the table.</summary>
    private Vector3 camera;
    private (Vector3 Normal, float Offset)[] walls = [];

    public DiceToss() : this(null, false) { }
    /// <summary>A toss with a fixed motion seed whose time the caller advances, for off-screen tests.</summary>
    internal DiceToss(int? seed, bool manual)
    { motion = seed is { } fixedSeed ? new Random(fixedSeed) : new Random(); this.manual = manual; IsHitTestVisible = false; Focusable = false; }
    /// <summary>The longest a throw can last.</summary>
    public static double TossDuration => MaxSeconds;
    /// <summary>How long the current throw lasts.</summary>
    internal double Duration => duration;
    /// <summary>Dice are on the sheet, moving or resting.</summary>
    public bool Showing => dice.Count > 0;
    /// <summary>Dice are moving; only then does a per-frame callback exist.</summary>
    internal bool Moving => settled is not null;

    /// <summary>Throws up to <see cref="MaxShown"/> dice from <paramref name="origin"/>. <paramref name="settled"/> runs once, when the
    /// dice come to rest or when they are dismissed first.</summary>
    public void Play(IReadOnlyList<DieFace> faces, Point origin, double size, Color body, Color ink, FontFamily family, Action settled)
    {
        Clear();
        generation++; BeginAnimation(OpacityProperty, null); Opacity = 1;
        var count = Math.Min(MaxShown, faces.Count);
        this.size = size * (count > 6 ? .8 : 1); this.body = body;
        this.ink = Frozen(new SolidColorBrush(ink));
        mark = new Pen(this.ink, 3.2) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round }; mark.Freeze();
        edge = new Pen(Frozen(new SolidColorBrush(Color.FromArgb(0x90, (byte)(body.R * .45), (byte)(body.G * .45), (byte)(body.B * .45)))),
            Math.Max(.8, this.size / 70)) { LineJoin = PenLineJoin.Round };
        edge.Freeze();
        typeface = new(family, FontStyles.Normal, FontWeights.Bold, FontStretches.Normal);
        shades.Clear(); labels.Clear();
        Stage(Math.Max(RenderSize.Width, this.size * 4), Math.Max(RenderSize.Height, this.size * 4));
        foreach (var face in faces.Take(count))
        {
            var solid = Solid.For(face.Sides); var names = solid.Labels(face.Sides);
            var target = solid.MarkerFor(face.Sides, face.Face);
            names[target] = face.Face.ToString(CultureInfo.InvariantCulture);
            dice.Add(new Die { Face = face, Solid = solid, Labels = names, Target = target, Radius = (float)(this.size / 2 * solid.Scale) });
        }
        Throw(origin);
        Simulate();
        this.settled = settled;
        Pose(0);
        if (!manual) { clock.Restart(); CompositionTarget.Rendering += Frame; }
        InvalidateVisual();
    }

    /// <summary>The camera and the walls: planes through the camera and the sheet's inset edges, so every die stays in view.</summary>
    private void Stage(double width, double height)
    {
        camera = new((float)width / 2, (float)height / 2, (float)(Math.Max(width, height) * 1.25));
        var inset = (float)Math.Max(4, size * .12);
        Vector3 Wall(Vector3 across, float at, float middle, float sign)
        {
            // Inward normal of the plane through the camera and the line where `across`·x = at on the sheet.
            var normal = Vector3.Normalize(across * sign * camera.Z + Vector3.UnitZ * sign * (at - middle));
            return normal;
        }
        walls =
        [
            (Vector3.UnitZ, 0),
            Plane(Wall(Vector3.UnitX, inset, camera.X, 1), new(inset, 0, 0)),
            Plane(Wall(Vector3.UnitX, (float)width - inset, camera.X, -1), new((float)width - inset, 0, 0)),
            Plane(Wall(Vector3.UnitY, inset, camera.Y, 1), new(0, inset, 0)),
            Plane(Wall(Vector3.UnitY, (float)height - inset, camera.Y, -1), new(0, (float)height - inset, 0)),
        ];
        static (Vector3, float) Plane(Vector3 normal, Vector3 through) => (normal, Vector3.Dot(normal, through));
    }

    private float Next() => (float)(motion.NextDouble() - .5);
    private void Throw(Point origin)
    {
        // Thrown from above the end of the line toward the open middle of the sheet, tumbling.
        var aim = new Vector3((float)(camera.X * (1 + Next() * .3)), (float)(camera.Y * (1.1 + Next() * .3)), 0);
        foreach (var die in dice)
        {
            var z = die.Radius * (2.4f + (float)motion.NextDouble());
            var k = camera.Z / (camera.Z - z);
            var start = new Vector3(camera.X + ((float)origin.X - camera.X) / k, camera.Y + ((float)origin.Y - camera.Y) / k, z)
                + new Vector3(Next(), Next(), 0) * die.Radius * 2.2f;
            var heading = aim - start; heading.Z = 0;
            var distance = heading.Length(); heading = distance > 1 ? heading / distance : Vector3.UnitX;
            var turn = MathF.Atan2(heading.Y, heading.X) + Next() * .9f;
            heading = new(MathF.Cos(turn), MathF.Sin(turn), 0);
            var speed = Math.Clamp(distance * 1.3f, die.Radius * 8, die.Radius * 22) * (.85f + (float)motion.NextDouble() * .35f);
            die.Position = start;
            die.Velocity = heading * speed + Vector3.UnitZ * die.Radius * 4 * (float)motion.NextDouble();
            // Forward roll plus a random tumble.
            var roll = Vector3.Cross(Vector3.UnitZ, heading) * speed / die.Radius * .6f;
            die.Spin = roll + Vector3.Normalize(new(Next(), Next(), Next())) * (10 + 10 * (float)motion.NextDouble());
            die.Turn = Quaternion.Normalize(new Quaternion(Next(), Next(), Next(), Next()));
            die.Corners = new Vector3[die.Solid.Vertices.Length];
        }
    }

    private float Gravity => (float)size * 34;
    private const float Inertia = .3f, GroundBounce = .3f, GroundGrip = .5f, WallBounce = .5f, WallGrip = .15f;

    /// <summary>Runs the whole throw now, recording poses for playback, then picks each die's symmetry.</summary>
    private void Simulate()
    {
        foreach (var die in dice) die.Path.Add((die.Position, die.Turn));
        var steps = 0; var limit = (int)((MaxSeconds - FlattenSeconds) / StepSeconds);
        while (steps < limit && dice.Any(d => !d.Asleep))
        {
            Advance((float)StepSeconds); steps++;
            if (steps % StepsPerSample == 0) foreach (var die in dice) die.Path.Add((die.Position, die.Turn));
        }
        if (steps % StepsPerSample != 0) foreach (var die in dice) die.Path.Add((die.Position, die.Turn));
        // Rare: a die still rocking or leaning on another lies down on its nearest face.
        var flatten = dice.Where(d => !d.Asleep).ToArray();
        if (flatten.Length > 0)
        {
            var from = flatten.Select(d => (d.Position, d.Turn)).ToArray();
            var to = flatten.Select(Flat).ToArray();
            var samples = (int)Math.Ceiling(FlattenSeconds / SampleSeconds);
            for (var s = 1; s <= samples; s++)
            {
                var t = (float)s / samples; t = t * t * (3 - 2 * t);
                foreach (var die in dice) if (die.Asleep) die.Path.Add(die.Path[^1]);
                for (var i = 0; i < flatten.Length; i++)
                    flatten[i].Path.Add((Vector3.Lerp(from[i].Position, to[i].Position, t), Quaternion.Slerp(from[i].Turn, to[i].Turn, t)));
            }
            foreach (var die in flatten) { die.Forced = true; die.Asleep = true; (die.Position, die.Turn) = die.Path[^1]; }
        }
        duration = (dice.Count == 0 ? 0 : dice[0].Path.Count - 1) * SampleSeconds;
        foreach (var die in dice) die.Symmetry = die.Solid.Symmetry(die.Target, die.Solid.TopMarker(die.Turn));
    }

    /// <summary>The pose lying on the face nearest the sheet, at rest height, with the die's position kept.</summary>
    private (Vector3 Position, Quaternion Turn) Flat(Die die)
    {
        var bottom = die.Solid.BottomFace(die.Turn);
        var turn = Quaternion.Normalize(Quaternion.Concatenate(die.Turn, Solid.Between(Vector3.Transform(die.Solid.Normals[bottom], die.Turn), -Vector3.UnitZ)));
        return (die.Position with { Z = die.Solid.Depth(bottom) * die.Radius }, turn);
    }

    private void Advance(float dt)
    {
        foreach (var die in dice)
        {
            if (die.Asleep || LieDown(die, dt)) continue;
            die.Velocity.Z -= Gravity * dt;
            die.Position += die.Velocity * dt;
            var rate = die.Spin.Length();
            if (rate > 1e-5f) die.Turn = Quaternion.Normalize(Quaternion.Concatenate(die.Turn, Quaternion.CreateFromAxisAngle(die.Spin / rate, rate * dt)));
            var grounded = false;
            for (var w = 0; w < walls.Length; w++)
                grounded |= Contact(die, walls[w].Normal, walls[w].Offset, w == 0 ? GroundBounce : WallBounce, w == 0 ? GroundGrip : WallGrip) && w == 0;
            // Air barely slows a die; rolling on the sheet does, more so as it slows, so a die stops instead of rolling on.
            var slow = grounded && die.Velocity.Length() < die.Radius * 4 ? 2.5f : 1;
            die.Spin *= MathF.Exp(-(grounded ? 3f * slow : .3f) * dt);
            if (grounded) die.Velocity *= MathF.Exp(-1.2f * slow * dt);
            Rest(die, grounded, dt);
        }
        for (var i = 0; i < dice.Count; i++)
            for (var j = i + 1; j < dice.Count; j++) Collide(dice[i], dice[j]);
    }

    /// <summary>Impulses at every corner below a plane: restitution on impact, Coulomb friction, then the die is lifted out.</summary>
    private bool Contact(Die die, Vector3 normal, float offset, float bounce, float grip)
    {
        var vertices = die.Solid.Vertices; var corners = die.Corners; var deepest = 0f; var touching = false;
        for (var i = 0; i < vertices.Length; i++)
        {
            corners[i] = Vector3.Transform(vertices[i], die.Turn) * die.Radius;
            var depth = Vector3.Dot(normal, die.Position + corners[i]) - offset;
            if (depth < 0) { touching = true; deepest = Math.Min(deepest, depth); }
        }
        // A die skimming the sheet counts as on it, so rolling drag also slows a die hopping along.
        if (!touching) return deepest < 0 || Lowest(die, normal, offset) < die.Radius * .05f;
        var mass = 1f; var inertia = Inertia * die.Radius * die.Radius;
        for (var pass = 0; pass < 3; pass++)
            for (var i = 0; i < vertices.Length; i++)
            {
                var r = corners[i];
                if (Vector3.Dot(normal, die.Position + r) - offset > .5f) continue;
                var closing = Vector3.Dot(normal, die.Velocity + Vector3.Cross(die.Spin, r));
                if (closing >= 0) continue;
                var e = pass == 0 && closing < -die.Radius * 6 ? bounce : 0;
                var arm = Vector3.Cross(r, normal);
                var push = -(1 + e) * closing / (1 / mass + arm.LengthSquared() / inertia);
                Apply(die, normal * push, r, mass, inertia);
                var slip = die.Velocity + Vector3.Cross(die.Spin, r); slip -= normal * Vector3.Dot(slip, normal);
                var speed = slip.Length();
                if (speed < 1e-4f) continue;
                var along = slip / speed; var twist = Vector3.Cross(r, along);
                var drag = Math.Min(speed / (1 / mass + twist.LengthSquared() / inertia), grip * push);
                Apply(die, -along * drag, r, mass, inertia);
            }
        die.Position -= normal * deepest;
        return true;
    }
    private static float Lowest(Die die, Vector3 normal, float offset)
    {
        var lowest = float.MaxValue;
        foreach (var corner in die.Corners) lowest = Math.Min(lowest, Vector3.Dot(normal, die.Position + corner) - offset);
        return lowest;
    }
    private static void Apply(Die die, Vector3 impulse, Vector3 at, float mass, float inertia)
    { die.Velocity += impulse / mass; die.Spin += Vector3.Cross(at, impulse) / inertia; }

    /// <summary>A die that has been slow on the sheet for a moment and lies nearly flat is laid exactly flat and stops.</summary>
    private void Rest(Die die, bool grounded, float dt)
    {
        var calm = grounded && die.Velocity.Length() < die.Radius * .6f && die.Spin.Length() < 1.5f;
        die.Calm = calm ? die.Calm + dt : 0;
        if (die.Calm < .1) return;
        var flat = Vector3.Transform(die.Solid.Normals[die.Solid.BottomFace(die.Turn)], die.Turn).Z <= -.985f;
        if (flat) { (die.Position, die.Turn) = Flat(die); die.Velocity = default; die.Spin = default; die.Asleep = true; }
        // A die that stays tilted is propped on another; it slides down onto its face over a moment.
        else if (die.Calm >= .3) die.Lying = (die.Position, die.Turn, Flat(die));
    }

    /// <summary>Moves a die propped at rest down onto its nearest face, then puts it to sleep.</summary>
    private static bool LieDown(Die die, float dt)
    {
        if (die.Lying is not { } lying) return false;
        die.Progress = Math.Min(1, die.Progress + dt / .2f);
        var t = die.Progress * die.Progress * (3 - 2 * die.Progress);
        die.Position = Vector3.Lerp(lying.From, lying.To.Position, t); die.Turn = Quaternion.Slerp(lying.Turn, lying.To.Turn, t);
        if (die.Progress >= 1) { die.Velocity = default; die.Spin = default; die.Asleep = true; die.Lying = null; }
        return true;
    }

    /// <summary>Dice meet as spheres a little inside their corners, so none can come to rest on another.</summary>
    private static void Collide(Die a, Die b)
    {
        if (a.Asleep && b.Asleep) return;
        var gap = b.Position - a.Position; var distance = gap.Length(); var contact = (a.Radius + b.Radius) * .85f;
        if (distance >= contact || distance < 1e-3f) return;
        var normal = gap / distance; var overlap = contact - distance;
        var shareA = a.Asleep ? 0 : b.Asleep ? 1 : .5f;
        a.Position -= normal * overlap * shareA; b.Position += normal * overlap * (1 - shareA);
        var closing = Vector3.Dot(b.Velocity - a.Velocity, normal);
        if (closing >= 0) return;
        var push = -1.4f * closing / (a.Asleep || b.Asleep ? 1 : 2);
        if (!a.Asleep) a.Velocity -= normal * push;
        if (!b.Asleep) b.Velocity += normal * push;
    }

    /// <summary>Any user action: dice still moving land at once, then all dice leave.</summary>
    public void Dismiss()
    {
        if (!Showing) return;
        Land();
        if (manual || !SheetMotion.Enabled) { Clear(); return; }
        var current = generation;
        var fade = new DoubleAnimation(1, 0, TimeSpan.FromMilliseconds(140)) { FillBehavior = FillBehavior.Stop };
        fade.Completed += (_, _) => { if (current == generation) { Clear(); Opacity = 1; } };
        Opacity = 0; BeginAnimation(OpacityProperty, fade);
    }

    /// <summary>Removes every die immediately, reporting a moving toss as settled.</summary>
    public void Clear()
    {
        Land();
        generation++; dice.Clear(); InvalidateVisual();
    }

    private void Land()
    {
        if (!Moving) return;
        CompositionTarget.Rendering -= Frame; clock.Stop();
        Pose(duration);
        InvalidateVisual();
        var done = settled; settled = null; done?.Invoke();
    }

    private void Frame(object? sender, EventArgs e) => Step(clock.Elapsed.TotalSeconds);

    /// <summary>Advances the toss to <paramref name="now"/> seconds after it started.</summary>
    internal void Step(double now)
    {
        if (!Moving) return;
        if (now >= duration) { Land(); return; }
        Pose(now);
        InvalidateVisual();
    }

    private void Pose(double now)
    {
        foreach (var die in dice)
        {
            var at = Math.Clamp(now / SampleSeconds, 0, die.Path.Count - 1);
            var i = Math.Min((int)at, die.Path.Count - 2); var t = (float)(at - Math.Max(i, 0));
            if (die.Path.Count < 2) { (die.At, die.Drawn) = (die.Path[0].Position, Quaternion.Concatenate(die.Symmetry, die.Path[0].Turn)); continue; }
            var (p0, q0) = die.Path[i]; var (p1, q1) = die.Path[i + 1];
            die.At = Vector3.Lerp(p0, p1, t);
            die.Drawn = Quaternion.Concatenate(die.Symmetry, Quaternion.Slerp(q0, q1, t));
        }
    }

    /// <summary>For tests: each die's top label once the throw has ended, how flat it lies, and whether it was laid down.</summary>
    internal IEnumerable<(string Top, float Flatness, bool Forced, Point Center)> Resting() => dice.Select(die =>
        (die.Labels[die.Solid.TopMarker(die.Drawn)],
         -Vector3.Transform(die.Solid.Normals[die.Solid.BottomFace(die.Drawn)], die.Drawn).Z, die.Forced, Project(die.At)));

    private Point Project(Vector3 point)
    {
        var k = camera.Z / Math.Max(camera.Z * .3f, camera.Z - point.Z);
        return new(camera.X + (point.X - camera.X) * k, camera.Y + (point.Y - camera.Y) * k);
    }

    /// <summary>Light from the upper left, high above the sheet.</summary>
    private static readonly Vector3 Light = Vector3.Normalize(new(-.42f, -.55f, .72f));
    /// <summary>Shadows fall from closer to overhead than the shading light, so they stay near their dice.</summary>
    private static readonly Vector3 Overhead = Vector3.Normalize(new(-.22f, -.3f, 1));

    protected override void OnRender(DrawingContext context)
    {
        if (dice.Count == 0) return;
        var dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        foreach (var die in dice) Shade(context, die);
        foreach (var die in dice.OrderBy(d => d.At.Z))
        {
            var solid = die.Solid; var scale = die.Radius;
            var corners = solid.Vertices.Select(v => die.At + Vector3.Transform(v, die.Drawn) * scale).ToArray();
            context.PushOpacity(die.Face.Kept || Moving ? 1 : .45);
            // Back faces of a convex solid are hidden; the front faces never overlap, so their order does not matter.
            for (var f = 0; f < solid.Faces.Length; f++)
            {
                var normal = Vector3.Transform(solid.Normals[f], die.Drawn);
                var center = die.At + Vector3.Transform(solid.Centers[f], die.Drawn) * scale;
                var view = Vector3.Normalize(camera - center);
                var facing = Vector3.Dot(normal, view);
                if (facing <= .002f) continue;
                var polygon = new StreamGeometry();
                using (var draw = polygon.Open())
                {
                    var face = solid.Faces[f];
                    draw.BeginFigure(Project(corners[face[0]]), true, true);
                    draw.PolyLineTo(face.Skip(1).Select(i => Project(corners[i])).ToArray(), true, true);
                }
                polygon.Freeze();
                context.DrawGeometry(Lit(normal, view), edge, polygon);
                if (facing < .25f) continue;
                if (solid.MarksCorners)
                    foreach (var corner in solid.Faces[f])
                    {
                        // A d4 prints each corner's number next to that corner, pointing at it.
                        var toward = Vector3.Normalize(solid.Vertices[corner] - solid.Centers[f]);
                        var at = solid.Centers[f] + (solid.Vertices[corner] - solid.Centers[f]) * .5f;
                        Printed(context, die, at, toward, solid.Normals[f], () => Print(context, die.Labels[corner], solid.Inradii[f] * .72f, true, dpi));
                    }
                else
                    Printed(context, die, solid.Centers[f], solid.Ups[f], solid.Normals[f], () =>
                    {
                        if (die.Face.Sides == 6) Pips(context, int.Parse(die.Labels[f], CultureInfo.InvariantCulture), solid.Inradii[f]);
                        else Print(context, die.Labels[f], solid.Inradii[f], solid.Faces[f].Length == 3, dpi);
                    });
            }
            context.Pop();
        }
    }

    /// <summary>Draws in a face's own frame (right, up), mapped through the perspective at that point.</summary>
    private void Printed(DrawingContext context, Die die, Vector3 at, Vector3 up, Vector3 normal, Action draw)
    {
        const float step = .05f;
        var right = Vector3.Cross(normal, up);
        Vector3 World(Vector3 local) => die.At + Vector3.Transform(local, die.Drawn) * die.Radius;
        var origin = Project(World(at)); var x = Project(World(at + right * step)) - origin; var y = Project(World(at - up * step)) - origin;
        context.PushTransform(new MatrixTransform(x.X / step, x.Y / step, y.X / step, y.Y / step, origin.X, origin.Y));
        draw();
        context.Pop();
    }

    /// <summary>The shadow: the die's outline cast from nearly overhead onto the sheet, feathered, and softer the higher the die.</summary>
    private void Shade(DrawingContext context, Die die)
    {
        var points = die.Solid.Vertices.Select(v =>
        {
            var p = die.At + Vector3.Transform(v, die.Drawn) * die.Radius;
            var cast = p - Overhead * (p.Z / Overhead.Z);
            return new Point(cast.X, cast.Y);
        }).ToList();
        var hull = Hull(points);
        var lift = Math.Clamp((die.At.Z - die.Radius) / (die.Radius * 4), 0, 1);
        var middle = new Point(hull.Average(p => p.X), hull.Average(p => p.Y));
        foreach (var (grow, share) in new[] { (.16, .22), (.08, .3), (0, .42) })
        {
            var polygon = new StreamGeometry();
            using (var draw = polygon.Open())
            {
                Point Grown(Point p) => middle + (p - middle) * (1 + grow * (1 + 2 * lift));
                draw.BeginFigure(Grown(hull[0]), true, true);
                draw.PolyLineTo(hull.Skip(1).Select(Grown).ToArray(), false, true);
            }
            polygon.Freeze();
            context.DrawGeometry(Tint(Color.FromArgb((byte)(110 * share * (1 - .55 * lift)), 0, 0, 0)), null, polygon);
        }
    }
    private static List<Point> Hull(List<Point> points)
    {
        points.Sort((a, b) => a.X != b.X ? a.X.CompareTo(b.X) : a.Y.CompareTo(b.Y));
        var hull = new List<Point>();
        static double Turn(Point o, Point a, Point b) => (a.X - o.X) * (b.Y - o.Y) - (a.Y - o.Y) * (b.X - o.X);
        foreach (var pass in new[] { points, Enumerable.Reverse(points).ToList() })
        {
            var start = hull.Count;
            foreach (var p in pass)
            {
                while (hull.Count >= start + 2 && Turn(hull[^2], hull[^1], p) <= 0) hull.RemoveAt(hull.Count - 1);
                hull.Add(p);
            }
            hull.RemoveAt(hull.Count - 1);
        }
        return hull;
    }

    private void Print(DrawingContext context, string label, float inradius, bool triangle, double dpi)
    {
        const double reference = 40;
        if (!labels.TryGetValue(label, out var text))
            labels[label] = text = new FormattedText(label, CultureInfo.InvariantCulture, FlowDirection.LeftToRight, typeface, reference, ink, dpi);
        // A triangle's inscribed circle is small next to its corners, so its numbers run a little larger.
        var em = inradius * (triangle ? 1.25 : 1) * (label.Length switch { 1 => 1.3, 2 => 1.05, _ => .78 });
        var k = em / reference;
        context.PushTransform(new ScaleTransform(k, k));
        // Centre the digits' ink, not the line box.
        context.DrawText(text, new Point(-text.Width / 2, text.Extent / 2 - text.Baseline));
        // 6 and 9 carry a mark so they read the right way up.
        if (label is "6" or "9")
        {
            var y = text.Extent / 2 + reference * .12;
            context.DrawLine(mark, new Point(-text.Width * .3, y), new Point(text.Width * .3, y));
        }
        context.Pop();
    }

    private void Pips(DrawingContext context, int face, float inradius)
    {
        var o = inradius * .52; var r = inradius * .17;
        (double X, double Y)[] at = face switch
        {
            1 => [(0, 0)],
            2 => [(-o, -o), (o, o)],
            3 => [(-o, -o), (0, 0), (o, o)],
            4 => [(-o, -o), (o, -o), (-o, o), (o, o)],
            5 => [(-o, -o), (o, -o), (0, 0), (-o, o), (o, o)],
            _ => [(-o, -o), (o, -o), (-o, 0), (o, 0), (-o, o), (o, o)],
        };
        foreach (var (x, y) in at) context.DrawEllipse(ink, null, new Point(x, y), face == 1 ? r * 1.4 : r, face == 1 ? r * 1.4 : r);
    }

    /// <summary>Ambient and diffuse light with a glossy highlight toward the viewer, quantized so a throw reuses frozen brushes.</summary>
    private Brush Lit(Vector3 normal, Vector3 view)
    {
        var diffuse = Math.Max(0, Vector3.Dot(normal, Light));
        var shine = MathF.Pow(Math.Max(0, Vector3.Dot(normal, Vector3.Normalize(Light + view))), 60) * .4f;
        var level = .42f + .66f * diffuse;
        byte Channel(byte c) => (byte)Math.Clamp(c * level + (255 - c * level) * shine, 0, 255);
        return Tint(Color.FromArgb(body.A, Channel(body.R), Channel(body.G), Channel(body.B)));
    }
    private Brush Tint(Color color)
    {
        // Channels rounded to multiples of 4 keep the cache small.
        var key = color.A << 24 | (color.R & 0xFC) << 16 | (color.G & 0xFC) << 8 | color.B & 0xFC;
        if (shades.TryGetValue(key, out var brush)) return brush;
        if (shades.Count > 2048) shades.Clear();
        return shades[key] = Frozen(new SolidColorBrush(Color.FromArgb(color.A, (byte)(color.R & 0xFC), (byte)(color.G & 0xFC), (byte)(color.B & 0xFC))));
    }
    private static Brush Frozen(Brush brush) { brush.Freeze(); return brush; }
}

/// <summary>A convex die: vertices, outward faces, each face's printing frame (centre, right, up, inradius) and its numbering.
/// Numbers mark faces, except on a d4, whose corners carry them and whose top corner shows the roll.</summary>
internal sealed class Solid
{
    public Vector3[] Vertices { get; }
    public int[][] Faces { get; }
    public Vector3[] Normals { get; }
    public Vector3[] Centers { get; }
    public Vector3[] Rights { get; }
    public Vector3[] Ups { get; }
    public float[] Inradii { get; }
    /// <summary>Drawing scale, evening out the apparent size of different shapes.</summary>
    public double Scale { get; }
    /// <summary>Numbers belong to corners (a d4) rather than faces.</summary>
    public bool MarksCorners { get; }
    private readonly int[] numbers;

    private Solid(Vector3[] vertices, int[][] faces, double scale, bool edgeUp, bool marksCorners = false)
    {
        Vertices = vertices; Faces = faces; Scale = scale; MarksCorners = marksCorners;
        Normals = new Vector3[faces.Length]; Centers = new Vector3[faces.Length]; Rights = new Vector3[faces.Length]; Ups = new Vector3[faces.Length]; Inradii = new float[faces.Length];
        for (var f = 0; f < faces.Length; f++)
        {
            var points = faces[f].Select(i => vertices[i]).ToArray();
            var center = points.Aggregate(Vector3.Zero, (a, b) => a + b) / points.Length;
            var normal = Vector3.Normalize(Vector3.Cross(points[1] - points[0], points[2] - points[0]));
            if (Vector3.Dot(normal, center) < 0) normal = -normal;
            // Numbers point at a corner; a cube's pips square up with an edge.
            var toward = edgeUp ? (points[0] + points[1]) / 2 : points[0];
            var up = Vector3.Normalize(toward - center - normal * Vector3.Dot(toward - center, normal));
            Centers[f] = center; Normals[f] = normal; Ups[f] = up; Rights[f] = Vector3.Cross(normal, up);
            Inradii[f] = points.Select((p, i) => DistanceToEdge(center, p, points[(i + 1) % points.Length])).Min();
        }
        if (marksCorners) { numbers = [.. Enumerable.Range(1, vertices.Length)]; return; }
        // Opposite faces sum to n + 1, as on real dice.
        numbers = new int[faces.Length]; var next = 1;
        for (var f = 0; f < faces.Length; f++)
        {
            if (numbers[f] != 0) continue;
            numbers[f] = next;
            var opposite = Enumerable.Range(0, faces.Length).FirstOrDefault(g => numbers[g] == 0 && Vector3.Dot(Normals[g], Normals[f]) < -.99f, -1);
            if (opposite >= 0) numbers[opposite] = faces.Length + 1 - next;
            do next++; while (numbers.Contains(next));
        }
    }
    private static float DistanceToEdge(Vector3 p, Vector3 a, Vector3 b)
    {
        var ab = b - a; var t = Math.Clamp(Vector3.Dot(p - a, ab) / ab.LengthSquared(), 0, 1);
        return Vector3.Distance(p, a + ab * t);
    }

    /// <summary>Labels per marker (face, or corner on a d4) for a die with <paramref name="sides"/> sides; percentile dice read
    /// 00–90. A fresh array per die.</summary>
    public string[] Labels(int sides) => numbers.Select(n => sides == 100 ? (n % 10 * 10).ToString("00", CultureInfo.InvariantCulture)
        : ((n - 1) % sides + 1).ToString(CultureInfo.InvariantCulture)).ToArray();
    /// <summary>The marker that shows a rolled value: its own number on a standard die, otherwise marker 0 relabelled with the value.</summary>
    public int MarkerFor(int sides, int value) => sides == numbers.Length ? Array.IndexOf(numbers, value) : 0;
    /// <summary>The marker facing up (+z) in orientation <paramref name="turn"/>: the top face, or a d4's top corner.</summary>
    public int TopMarker(Quaternion turn) => MarksCorners ? Highest(Vertices, turn) : Highest(Normals, turn);
    /// <summary>The face facing most nearly down.</summary>
    public int BottomFace(Quaternion turn) => Highest(Normals.Select(n => -n).ToArray(), turn);
    private static int Highest(Vector3[] directions, Quaternion turn)
    {
        var best = 0; var height = float.MinValue;
        for (var i = 0; i < directions.Length; i++)
        {
            var z = Vector3.Transform(directions[i], turn).Z;
            if (z > height) { height = z; best = i; }
        }
        return best;
    }
    /// <summary>Distance from the centre to a face's plane: the resting height on that face, in unit radii.</summary>
    public float Depth(int face) => Vector3.Dot(Normals[face], Vertices[Faces[face][0]]);

    /// <summary>A rotation mapping the solid onto itself that carries marker <paramref name="from"/> to marker <paramref name="to"/>.
    /// Every die's rotation group reaches every marker, so one exists.</summary>
    public Quaternion Symmetry(int from, int to)
    {
        Vector3 Axis(int m) => MarksCorners ? Vertices[m] : Normals[m];
        IEnumerable<Vector3> Around(int m) => MarksCorners ? Vertices.Where((_, i) => i != m) : Faces[m].Select(i => Vertices[i]);
        var axis = Axis(to);
        var align = Between(Axis(from), axis);
        Vector3 Flat(Vector3 v) => v - axis * Vector3.Dot(v, axis);
        var side = Flat(Vector3.Transform(Around(from).First(), align));
        foreach (var candidate in Around(to))
        {
            var goal = Flat(candidate);
            var angle = MathF.Atan2(Vector3.Dot(axis, Vector3.Cross(side, goal)), Vector3.Dot(side, goal));
            var turn = Quaternion.Normalize(Quaternion.Concatenate(align, Quaternion.CreateFromAxisAngle(axis, angle)));
            if (Vertices.All(v => Vertices.Any(w => Vector3.DistanceSquared(Vector3.Transform(v, turn), w) < 1e-4f))) return turn;
        }
        throw new InvalidOperationException("No symmetry carries the marker.");
    }
    internal static Quaternion Between(Vector3 from, Vector3 to)
    {
        from = Vector3.Normalize(from); to = Vector3.Normalize(to);
        var dot = Math.Clamp(Vector3.Dot(from, to), -1, 1); var axis = Vector3.Cross(from, to);
        if (axis.LengthSquared() > 1e-10f) return Quaternion.CreateFromAxisAngle(Vector3.Normalize(axis), MathF.Acos(dot));
        if (dot > 0) return Quaternion.Identity;
        var other = Math.Abs(from.X) < .9f ? Vector3.UnitX : Vector3.UnitY;
        return Quaternion.CreateFromAxisAngle(Vector3.Normalize(Vector3.Cross(from, other)), MathF.PI);
    }

    private static readonly Dictionary<int, Solid> Cache = [];
    /// <summary>The real polyhedron for standard dice; other sizes borrow the nearest shape.</summary>
    public static Solid For(int sides)
    {
        var shape = sides switch { <= 4 => 4, <= 6 => 6, <= 8 => 8, <= 10 or 100 => 10, <= 12 => 12, _ => 20 };
        if (Cache.TryGetValue(shape, out var solid)) return solid;
        Vector3[] axes = [Vector3.UnitX, -Vector3.UnitX, Vector3.UnitY, -Vector3.UnitY, Vector3.UnitZ, -Vector3.UnitZ];
        Vector3[] tetra = [new(1, 1, 1), new(1, -1, -1), new(-1, 1, -1), new(-1, -1, 1)];
        return Cache[shape] = shape switch
        {
            4 => FromNormals(tetra, tetra.Select(v => -v).ToArray(), 1.3, false, marksCorners: true),
            6 => FromNormals(Corners(), axes, 1.3, true),
            8 => FromNormals(axes, Corners(), 1.12, false),
            10 => Trapezohedron(),
            12 => FromNormals(Dodecahedron(), Icosahedron(), 1.02, false),
            _ => FromNormals(Icosahedron(), Dodecahedron(), 1.04, false),
        };
    }
    private static readonly float Phi = (1 + MathF.Sqrt(5)) / 2;
    private static Vector3[] Corners() => [.. from a in new[] { -1f, 1f } from b in new[] { -1f, 1f } from c in new[] { -1f, 1f } select new Vector3(a, b, c)];
    private static Vector3[] Icosahedron() => [.. Cycle(1, Phi)];
    /// <summary>The dual of <see cref="Icosahedron"/>: each vertex lies along one icosahedron face normal, and vice versa.</summary>
    private static Vector3[] Dodecahedron() => [.. Corners(), .. Cycle(Phi, 1 / Phi)];
    /// <summary>Cyclic permutations of (0, ±a, ±b).</summary>
    private static IEnumerable<Vector3> Cycle(float a, float b)
    {
        foreach (var s in new[] { -1f, 1f })
            foreach (var t in new[] { -1f, 1f })
            { yield return new(0, s * a, t * b); yield return new(s * a, t * b, 0); yield return new(t * b, 0, s * a); }
    }
    /// <summary>Unit-sphere vertices; each face is the set of vertices farthest along its normal, ordered around it.</summary>
    private static Solid FromNormals(Vector3[] vertices, Vector3[] normals, double scale, bool edgeUp, bool marksCorners = false)
    {
        var unit = vertices.Select(Vector3.Normalize).ToArray();
        var faces = normals.Select(Vector3.Normalize).Select(n =>
        {
            var best = unit.Max(v => Vector3.Dot(v, n));
            var members = Enumerable.Range(0, unit.Length).Where(i => Vector3.Dot(unit[i], n) > best - 1e-3f).ToArray();
            var center = members.Aggregate(Vector3.Zero, (s, i) => s + unit[i]) / members.Length;
            var axis = Vector3.Normalize(unit[members[0]] - center); var other = Vector3.Cross(n, axis);
            return members.OrderBy(i => MathF.Atan2(Vector3.Dot(unit[i] - center, other), Vector3.Dot(unit[i] - center, axis))).ToArray();
        }).ToArray();
        return new(unit, faces, scale, edgeUp, marksCorners);
    }
    /// <summary>A pentagonal trapezohedron (d10) with planar kite faces: two apexes and two rings offset by 36°.
    /// A kite through the apex and two upper ring corners contains the lower corner between them when ring = h(1 − cos 36°)/(1 + cos 36°).</summary>
    private static Solid Trapezohedron()
    {
        const float height = 1.1f;
        var cos36 = MathF.Cos(MathF.PI / 5); var ring = height * (1 - cos36) / (1 + cos36);
        var vertices = new List<Vector3> { new(0, 0, height), new(0, 0, -height) };
        for (var k = 0; k < 5; k++) { var a = k * 2 * MathF.PI / 5; vertices.Add(new(MathF.Cos(a), MathF.Sin(a), ring)); }
        for (var k = 0; k < 5; k++) { var a = k * 2 * MathF.PI / 5 + MathF.PI / 5; vertices.Add(new(MathF.Cos(a), MathF.Sin(a), -ring)); }
        int U(int k) => 2 + k % 5; int L(int k) => 7 + k % 5;
        var faces = new List<int[]>();
        // The apex comes first so each number points at it.
        for (var k = 0; k < 5; k++) { faces.Add([0, U(k), L(k), U(k + 1)]); faces.Add([1, L(k), U(k + 1), L(k + 1)]); }
        var scale = 1 / height;
        return new(vertices.Select(v => v * scale).ToArray(), [.. faces], 1.1, false);
    }
}
