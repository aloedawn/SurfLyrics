using System.Drawing;
using Microsoft.Win32;
using Forms = System.Windows.Forms;
namespace SurfLyrics.Windows;
internal static class NativeMenu
{
    internal static Forms.ContextMenuStrip Create()
    {
        var menu = new Forms.ContextMenuStrip { ShowImageMargin = false };
        menu.Opening += (_,_) =>
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            bool dark = key?.GetValue("AppsUseLightTheme") is int value && value == 0;
            var background = dark ? Color.FromArgb(32,32,32) : Color.FromArgb(250,250,250);
            var foreground = dark ? Color.White : Color.FromArgb(24,24,24);
            if (Forms.SystemInformation.HighContrast)
            {
                background = SystemColors.Menu; foreground = SystemColors.MenuText;
                menu.Renderer = new Forms.ToolStripSystemRenderer();
            }
            else menu.Renderer = new Forms.ToolStripProfessionalRenderer(new Palette(background,dark ? Color.FromArgb(62,62,62) : Color.FromArgb(224,236,248)));
            menu.BackColor = background; menu.ForeColor = foreground;
            foreach (Forms.ToolStripItem item in menu.Items) { item.BackColor = background; item.ForeColor = foreground; }
        };
        return menu;
    }
    private sealed class Palette(Color background,Color selection) : Forms.ProfessionalColorTable
    {
        public override Color ToolStripDropDownBackground => background;
        public override Color MenuItemSelected => selection;
        public override Color MenuItemBorder => selection;
        public override Color MenuBorder => background;
        public override Color ImageMarginGradientBegin => background;
        public override Color ImageMarginGradientMiddle => background;
        public override Color ImageMarginGradientEnd => background;
        public override Color SeparatorDark => Color.Gray;
        public override Color SeparatorLight => background;
    }
}
