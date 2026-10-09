namespace SurfLyrics.Core;

// Empirical macOS 27.2 model: response .5s, damping .8. The two equal
// contributions and their stop thresholds describe measured motion, not Apple source.
public sealed class NativeStatusSpring
{
    public const double StepSeconds = 1.0 / 120;
    private const double A = 3.2 * Math.PI, B = 2.4 * Math.PI;
    private readonly Part coarse, fine;
    private double remainder;
    public double Target { get; private set; }
    public double Position => coarse.Sample(Target / 2, remainder).Position + fine.Sample(Target / 2, remainder).Position;
    public double Velocity => coarse.Sample(Target / 2, remainder).Velocity + fine.Sample(Target / 2, remainder).Velocity;
    public bool IsSettled => coarse.AtRest(Target / 2) && fine.AtRest(Target / 2);

    public NativeStatusSpring(double initialLeft)
    {
        RequireFinite(initialLeft);
        Target = initialLeft;
        coarse = new(initialLeft / 2, .5);
        fine = new(initialLeft / 2, .25);
    }

    public void Retarget(double newLeft)
    {
        RequireFinite(newLeft);
        if (newLeft == Target) return;
        // Commit the render-time fraction before changing targets. This keeps
        // both position and velocity continuous even between 120Hz model steps.
        coarse.Commit(Target / 2, remainder, settle: false);
        fine.Commit(Target / 2, remainder, settle: false);
        remainder = 0;
        Target = newLeft;
    }

    public void Snap(double newLeft)
    {
        RequireFinite(newLeft);
        Target = newLeft; remainder = 0;
        coarse.Reset(newLeft / 2); fine.Reset(newLeft / 2);
    }

    public double Advance(double seconds)
    {
        RequireFinite(seconds);
        if (seconds < 0) throw new ArgumentOutOfRangeException(nameof(seconds));
        if (IsSettled) { remainder = 0; return Position; }
        remainder += seconds;
        while (remainder + 1e-12 >= StepSeconds)
        {
            coarse.Commit(Target / 2, StepSeconds, settle: true);
            fine.Commit(Target / 2, StepSeconds, settle: true);
            remainder = Math.Max(0, remainder - StepSeconds);
            if (IsSettled) { remainder = 0; break; }
        }
        // Analytic interpolation keeps 144Hz rendering smooth without moving
        // the settling decisions away from the measured 120Hz sample grid.
        return Position;
    }

    public static double ContinuousProgress(double seconds)
    {
        RequireFinite(seconds);
        return seconds <= 0 ? 0 : 1 - Math.Exp(-A * seconds) *
            (Math.Cos(B * seconds) + 4.0 / 3 * Math.Sin(B * seconds));
    }

    private static void RequireFinite(double value)
    {
        if (!double.IsFinite(value)) throw new ArgumentOutOfRangeException(nameof(value));
    }

    private sealed class Part(double initial, double tolerance)
    {
        private double position = initial, velocity;
        internal bool AtRest(double target) => position == target && velocity == 0;
        internal void Reset(double target) { position = target; velocity = 0; }
        internal (double Position, double Velocity) Sample(double target, double seconds)
        {
            if (seconds == 0 || AtRest(target)) return (position, velocity);
            double d = position - target, c = (velocity + A * d) / B;
            double cos = Math.Cos(B * seconds), sin = Math.Sin(B * seconds), decay = Math.Exp(-A * seconds);
            return (target + decay * (d * cos + c * sin),
                decay * ((-A * d + B * c) * cos + (-A * c - B * d) * sin));
        }
        internal void Commit(double target, double seconds, bool settle)
        {
            var next = Sample(target, seconds);
            if (settle && Math.Abs(next.Position - target) < tolerance && Math.Abs(next.Velocity) < tolerance)
                Reset(target);
            else { position = next.Position; velocity = next.Velocity; }
        }
    }
}