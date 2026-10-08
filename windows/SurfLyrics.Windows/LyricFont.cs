using System.Windows.Media;
namespace SurfLyrics.Windows;
internal static class LyricFont
{
    internal static bool Bundled => System.Windows.Media.Fonts.GetFontFamilies(new Uri("pack://application:,,,/"),"./Assets/Fonts/").Any(f => f.FamilyNames.Values.Contains("Pretendard JP"));
    internal static readonly FontFamily Family = new(new Uri("pack://application:,,,/"), "./Assets/Fonts/#Pretendard JP");
}
