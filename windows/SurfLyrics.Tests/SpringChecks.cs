using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using SurfLyrics.Core;

internal static class SpringChecks
{
    internal static void Run(Action<string, bool> check)
    {
        using var vectors = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "macos-spring-settling.json")));
        foreach (var item in vectors.RootElement.GetProperty("Cases").EnumerateArray())
        {
            double delta = item.GetProperty("amplitude_points").GetDouble();
            var stops = item.GetProperty("component_stop_s").EnumerateArray().Select(x => x.GetDouble()).ToArray();
            var spring = new NativeStatusSpring(1024);
            spring.Retarget(1024 + delta);
            bool matches = true;
            for (int n = 1; n <= 120; n++)
            {
                double t = n / 120.0;
                spring.Advance(1.0 / 120);
                double q = -Math.Exp(-3.2 * Math.PI * t) * (Math.Cos(2.4 * Math.PI * t) + 4.0 / 3 * Math.Sin(2.4 * Math.PI * t));
                double expected = 1024 + delta + delta / 2 * q * ((t < stops[0] - 1e-10 ? 1 : 0) + (t < stops[1] - 1e-10 ? 1 : 0));
                matches &= Math.Abs(spring.Position - expected) < 1e-9;
                matches &= spring.IsSettled == (t >= stops.Max() - 1e-10);
            }
            check($"Spring measured settling {item.GetProperty("run").GetString()} step {item.GetProperty("step").GetInt32()}", matches);
        }
        var peak = NativeStatusSpring.ContinuousProgress(5.0 / 12);
        check("Spring keeps 1.516462% overshoot at 416.667ms", Math.Abs(peak - 1.0151646198645465) < 1e-10);
        foreach (double interruption in new[] { .12, .25, .4 })
        {
            var spring = new NativeStatusSpring(0); spring.Retarget(232); spring.Advance(interruption);
            double x = spring.Position, v = spring.Velocity;
            spring.Retarget(-129);
            check($"Retarget at {interruption}s preserves position and velocity", Math.Abs(spring.Position - x) < 1e-12 && Math.Abs(spring.Velocity - v) < 1e-12);
            double a = 3.2 * Math.PI, b = 2.4 * Math.PI, d = x + 129, c = (v + a * d) / b, t = .03;
            double expected = -129 + Math.Exp(-a*t) * (d * Math.Cos(b*t) + c * Math.Sin(b*t));
            check($"Retarget at {interruption}s follows carried momentum", Math.Abs(spring.Advance(t) - expected) < 1e-9);
        }
        var partial = new NativeStatusSpring(0); partial.Retarget(232); partial.Advance(.12345);
        double px = partial.Position, pv = partial.Velocity;
        partial.Retarget(-65);
        check("Substep retarget preserves interpolated state", Math.Abs(partial.Position - px) < 1e-12 && Math.Abs(partial.Velocity - pv) < 1e-12);
        partial.Advance(.01); px = partial.Position; pv = partial.Velocity;
        partial.Retarget(-65);
        check("Equal target does not restart motion", partial.Position == px && partial.Velocity == pv);
        foreach (int rate in new[] { 60, 120, 144 })
        {
            var spring = new NativeStatusSpring(0); spring.Retarget(129);
            bool consistent = true;
            for (int group = 1; group <= 12; group++)
            {
                for (int n = 0; n < rate / 12; n++) spring.Advance(1.0/rate);
                var baseline = new NativeStatusSpring(0); baseline.Retarget(129); baseline.Advance(group / 12.0);
                consistent &= Math.Abs(spring.Position - baseline.Position) < 1e-9;
            }
            check($"{rate}Hz modeled cadence matches common times", consistent);
        }
        var snap = new NativeStatusSpring(0); snap.Retarget(129); snap.Advance(.12); snap.Snap(-3);
        check("Snap cancels all motion", snap.IsSettled && snap.Velocity == 0 && snap.Advance(.2) == -3);
        bool rejected = false;
        try { snap.Advance(double.NaN); } catch (ArgumentOutOfRangeException) { rejected = true; }
        check("Spring rejects nonfinite elapsed time", rejected);
        rejected = false;
        try { snap.Advance(-.1); } catch (ArgumentOutOfRangeException) { rejected = true; }
        check("Spring rejects negative elapsed time", rejected);
    }
}