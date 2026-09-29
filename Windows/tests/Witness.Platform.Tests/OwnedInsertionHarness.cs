using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using System.Runtime.InteropServices;

namespace Witness.Platform.Tests;

/// <summary>
/// Test-only owned target for W4. It is compiled into the platform test assembly
/// and is never referenced by or published with Witness.App.
/// </summary>
internal sealed class OwnedInsertionHarness : Window
{
    public OwnedInsertionHarness()
    {
        Title = "Witness owned insertion harness";
        Width = 520;
        SizeToContent = SizeToContent.Height;
        ShowInTaskbar = false;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;

        NormalText = new TextBox
        {
            Text = "draft old",
            TabIndex = 0,
            Margin = new Thickness(0, 4, 0, 12),
        };
        AutomationProperties.SetName(NormalText, "Owned normal text field");

        PasswordText = new PasswordBox
        {
            Password = "synthetic-secret",
            TabIndex = 1,
            Margin = new Thickness(0, 4, 0, 12),
        };
        AutomationProperties.SetName(PasswordText, "Owned protected password field");

        DelayedText = new DelayedPasteTextBox
        {
            Text = "delayed old",
            TabIndex = 2,
            Margin = new Thickness(0, 4, 0, 0),
        };
        AutomationProperties.SetName(DelayedText, "Owned delayed paste text field");

        Content = new StackPanel
        {
            Margin = new Thickness(20),
            Children =
            {
                LabelFor("_Normal text", NormalText),
                NormalText,
                LabelFor("_Protected password", PasswordText),
                PasswordText,
                LabelFor("_Delayed paste", DelayedText),
                DelayedText,
            },
        };
    }

    public TextBox NormalText { get; }
    public PasswordBox PasswordText { get; }
    public DelayedPasteTextBox DelayedText { get; }

    private static Label LabelFor(string content, Control target) => new()
    {
        Content = content,
        Target = target,
    };
}

internal sealed class DelayedPasteTextBox : TextBox
{
    public TimeSpan PasteDelay { get; set; } = TimeSpan.FromMilliseconds(100);

    internal Task ApplySyntheticPasteAsync(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var timer = new DispatcherTimer(DispatcherPriority.Input, Dispatcher)
        {
            Interval = PasteDelay,
        };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            SelectedText = text;
            CaretIndex = SelectionStart + text.Length;
            SelectionLength = 0;
            completion.TrySetResult();
        };
        timer.Start();
        return completion.Task;
    }

    protected override void OnPreviewKeyDown(KeyEventArgs e)
    {
        if (e.Key == Key.V && (Keyboard.Modifiers & ModifierKeys.Control) != 0)
        {
            e.Handled = true;
            try
            {
                if (Clipboard.ContainsText(TextDataFormat.UnicodeText))
                    _ = ApplySyntheticPasteAsync(Clipboard.GetText(TextDataFormat.UnicodeText));
            }
            catch (ExternalException)
            {
                // The owned harness deliberately models an unavailable clipboard.
            }
            return;
        }
        base.OnPreviewKeyDown(e);
    }
}
