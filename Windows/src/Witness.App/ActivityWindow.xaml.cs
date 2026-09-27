using System.Windows;
using System.Windows.Media;

namespace Witness.App;

internal enum ActivityVisualState
{
    Hidden,
    Listening,
    Processing,
    NoSpeech,
    Interrupted,
    Error,
}

public partial class ActivityWindow : Window
{
    public ActivityWindow()
    {
        InitializeComponent();
    }

    internal void ShowState(ActivityVisualState state, string? detail = null)
    {
        if (state == ActivityVisualState.Hidden)
        {
            Hide();
            return;
        }

        var presentation = state switch
        {
            ActivityVisualState.Listening => ("Listening…", System.Windows.SystemColors.HighlightBrush),
            ActivityVisualState.Processing => ("Processing on this PC…", System.Windows.SystemColors.HighlightBrush),
            ActivityVisualState.NoSpeech => ("No speech detected", System.Windows.SystemColors.GrayTextBrush),
            ActivityVisualState.Interrupted => ("Microphone interrupted", System.Windows.SystemColors.GrayTextBrush),
            ActivityVisualState.Error => ("Dictation could not continue", System.Windows.SystemColors.GrayTextBrush),
            _ => throw new ArgumentOutOfRangeException(nameof(state)),
        };
        StateText.Text = string.IsNullOrWhiteSpace(detail) ? presentation.Item1 : $"{presentation.Item1} {detail}";
        StateDot.Fill = presentation.Item2;
        PositionAtWorkingAreaEdge();
        if (!IsVisible) Show();
    }

    private void PositionAtWorkingAreaEdge()
    {
        const double margin = 20;
        Left = Math.Max(SystemParameters.WorkArea.Left + margin,
            SystemParameters.WorkArea.Right - ActualWidth - margin);
        Top = Math.Max(SystemParameters.WorkArea.Top + margin,
            SystemParameters.WorkArea.Bottom - ActualHeight - margin);
    }
}
