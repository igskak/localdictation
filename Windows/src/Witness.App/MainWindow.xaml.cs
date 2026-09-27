using System.Windows;

namespace Witness.App;

public partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
    }

    internal void SetStatus(string status) => StatusText.Text = status;
}
