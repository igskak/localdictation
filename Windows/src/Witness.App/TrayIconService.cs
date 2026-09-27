using System.Drawing;
using System.Windows.Forms;

namespace Witness.App;

internal sealed class TrayIconService : IDisposable
{
    private readonly NotifyIcon notifyIcon;
    private readonly ContextMenuStrip menu;

    public TrayIconService()
    {
        menu = new ContextMenuStrip();
        var open = new ToolStripMenuItem("Open Witness");
        open.Click += (_, _) => OpenRequested?.Invoke(this, EventArgs.Empty);
        var exit = new ToolStripMenuItem("Exit");
        exit.Click += (_, _) => ExitRequested?.Invoke(this, EventArgs.Empty);
        menu.Items.Add(open);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(exit);

        notifyIcon = new NotifyIcon
        {
            Text = "Witness — private dictation on this PC",
            Icon = SystemIcons.Application,
            ContextMenuStrip = menu,
            Visible = true,
        };
        notifyIcon.DoubleClick += (_, _) => OpenRequested?.Invoke(this, EventArgs.Empty);
    }

    public event EventHandler? OpenRequested;
    public event EventHandler? ExitRequested;

    public void Dispose()
    {
        notifyIcon.Visible = false;
        notifyIcon.Dispose();
        menu.Dispose();
    }
}
