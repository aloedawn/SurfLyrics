using System.Windows.Media;
using System.Windows.Media.Animation;

namespace SurfLyrics.Windows;

internal sealed class SpringTextMotion(TranslateTransform position) : IDisposable
{
    private readonly NativeStatusSpring spring = new(position.X);
    private readonly TranslateTransform cadence = new();
    private long lastTick;
    private bool running;

    internal void MoveTo(double target, bool animate)
    {
        if (!animate) { Stop(); spring.Snap(target); position.X = target; return; }
        if (spring.Target == target) return;
        if (running) AdvanceNow();
        spring.Retarget(target);
        position.X = spring.Position;
        if (running || spring.IsSettled) return;
        running = true;
        lastTick = Stopwatch.GetTimestamp();
        // An active WPF root clock requests the display cadence. Simulation
        // still uses elapsed time; there is no DispatcherTimer frame limit.
        var pulse = new DoubleAnimation(0, 1, TimeSpan.FromSeconds(1)) { RepeatBehavior = RepeatBehavior.Forever };
        AnimationCadence.Apply(pulse);
        cadence.BeginAnimation(TranslateTransform.XProperty, pulse);
        CompositionTarget.Rendering += RenderFrame;
    }

    private void AdvanceNow()
    {
        long now = Stopwatch.GetTimestamp();
        spring.Advance(Stopwatch.GetElapsedTime(lastTick, now).TotalSeconds);
        lastTick = now;
        position.X = spring.Position;
    }
    private void RenderFrame(object? sender, EventArgs e)
    {
        AdvanceNow();
        if (spring.IsSettled) Stop();
    }
    private void Stop()
    {
        if (!running) return;
        running = false;
        CompositionTarget.Rendering -= RenderFrame;
        cadence.BeginAnimation(TranslateTransform.XProperty, null);
    }
    public void Dispose() => Stop();
}