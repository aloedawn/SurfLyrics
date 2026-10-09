using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace SurfLyrics.Windows;

public sealed class LyricTextTransition(TextBlock text, TextBlock outgoing, Action? textChanged = null)
{
    private string requestedText = text.Text;
    private int revision;
    private bool animating;

    public void SetText(string value, bool fade)
    {
        fade &= SystemParameters.ClientAreaAnimation;
        if (value == requestedText)
        {
            if (!fade && animating) ShowImmediately(value);
            return;
        }
        requestedText = value;
        if (!fade || !text.IsVisible || text.Text.Length == 0) { ShowImmediately(value); return; }

        int currentRevision = ++revision;
        // Preserve the more visible outgoing line during a rapid sequence.
        double oldOpacity = outgoing.Opacity;
        if (text.Opacity >= oldOpacity)
        {
            oldOpacity = text.Opacity;
            outgoing.Text = text.Text;
            outgoing.FontFamily = text.FontFamily; outgoing.FontSize = text.FontSize;
            outgoing.FontWeight = text.FontWeight; outgoing.FontStyle = text.FontStyle;
            outgoing.FontStretch = text.FontStretch; outgoing.Foreground = text.Foreground;
            outgoing.Width = text.Width;
            outgoing.RenderTransform = new TranslateTransform(((TranslateTransform)text.RenderTransform).X, 0);
            Canvas.SetTop(outgoing, Canvas.GetTop(text));
        }
        outgoing.BeginAnimation(UIElement.OpacityProperty, null);
        outgoing.Opacity = oldOpacity;
        text.BeginAnimation(UIElement.OpacityProperty, null);
        // Text, shaped width and target change now; fading never delays retargeting.
        text.Text = value;
        text.Opacity = 0;
        textChanged?.Invoke();
        animating = true;
        var fadeOut = Animation(oldOpacity, 0, 120);
        var fadeIn = Animation(0, 1, 180);
        fadeOut.Completed += (_, _) =>
        {
            if (currentRevision != revision) return;
            outgoing.Opacity = 0; outgoing.BeginAnimation(UIElement.OpacityProperty, null);
            outgoing.Text = "";
        };
        fadeIn.Completed += (_, _) =>
        {
            if (currentRevision != revision) return;
            text.Opacity = 1; text.BeginAnimation(UIElement.OpacityProperty, null);
            animating = false;
        };
        outgoing.BeginAnimation(UIElement.OpacityProperty, fadeOut);
        text.BeginAnimation(UIElement.OpacityProperty, fadeIn);
    }

    private void ShowImmediately(string value)
    {
        revision++; animating = false;
        outgoing.BeginAnimation(UIElement.OpacityProperty, null); outgoing.Opacity = 0; outgoing.Text = "";
        text.BeginAnimation(UIElement.OpacityProperty, null); text.Opacity = 1;
        if (text.Text == value) return;
        text.Text = value; textChanged?.Invoke();
    }
    private static DoubleAnimation Animation(double from, double to, int milliseconds)
    {
        var animation = new DoubleAnimation(from, to, new Duration(TimeSpan.FromMilliseconds(milliseconds)))
        { EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut } };
        AnimationCadence.Apply(animation);
        return animation;
    }
}