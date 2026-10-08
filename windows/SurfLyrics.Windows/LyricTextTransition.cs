using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Animation;

namespace SurfLyrics.Windows;

public sealed class LyricTextTransition(TextBlock text, Action? textChanged = null)
{
    private string requestedText = text.Text;
    private int revision;
    private bool animating;

    public void SetText(string value, bool fade)
    {
        // Playback is rendered repeatedly; an unchanged line must not restart its animation.
        if (value == requestedText)
        {
            if (!fade && animating) ShowImmediately(value);
            return;
        }
        requestedText = value;
        if (!fade || !text.IsVisible || text.Text.Length == 0)
        {
            ShowImmediately(value);
            return;
        }

        int currentRevision = ++revision;
        animating = true;
        var fadeOut = Animation(text.Opacity, 0, 120);
        fadeOut.Completed += (_, _) =>
        {
            // A seek or track switch may replace a line before its fade finishes.
            if (currentRevision != revision) return;
            text.Opacity = 0;
            text.BeginAnimation(UIElement.OpacityProperty, null);
            text.Text = requestedText;
            textChanged?.Invoke();
            var fadeIn = Animation(0, 1, 180);
            fadeIn.Completed += (_, _) =>
            {
                if (currentRevision != revision) return;
                text.Opacity = 1;
                text.BeginAnimation(UIElement.OpacityProperty, null);
                animating = false;
            };
            text.BeginAnimation(UIElement.OpacityProperty, fadeIn);
        };
        text.BeginAnimation(UIElement.OpacityProperty, fadeOut);
    }

    private void ShowImmediately(string value)
    {
        revision++;
        animating = false;
        text.BeginAnimation(UIElement.OpacityProperty, null);
        text.Opacity = 1;
        text.Text = value;
        textChanged?.Invoke();
    }

    private static DoubleAnimation Animation(double from, double to, int milliseconds) => new(from, to,
        new Duration(TimeSpan.FromMilliseconds(milliseconds)))
    { EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseInOut } };
}
