using System.IO;
using System.Windows.Threading;
using Witness.Core.Models;
using Witness.Platform.Windows.Models;
using Witness.Platform.Windows.Settings;

namespace Witness.App;

internal sealed class ModelSetupController : IAsyncDisposable
{
    private readonly Dispatcher dispatcher;
    private readonly MainWindow window;
    private readonly HttpModelDownloadClient downloadClient;
    private readonly ModelManager manager;
    private bool disposed;

    public event Action<string>? ModelReady;

    public string? ReadyModelPath { get; private set; }

    public ModelSetupController(Dispatcher dispatcher, MainWindow window)
    {
        this.dispatcher = dispatcher;
        this.window = window;
        downloadClient = new HttpModelDownloadClient();
        var modelDirectory = WitnessLocalDataPaths.Current().Models;
        manager = new ModelManager(
            ProductModel.Default,
            modelDirectory,
            downloadClient,
            new SystemModelDiskSpace());
        manager.ProgressChanged += OnProgressChanged;
        window.ModelDownloadRequested += OnDownloadRequested;
        window.ModelDownloadCancelRequested += OnCancelRequested;
    }

    public Task InspectAsync() => PrepareAsync(disclosureAccepted: false);

    public async ValueTask DisposeAsync()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        window.ModelDownloadRequested -= OnDownloadRequested;
        window.ModelDownloadCancelRequested -= OnCancelRequested;
        manager.ProgressChanged -= OnProgressChanged;
        manager.CancelActive();
        await manager.DisposeAsync().ConfigureAwait(false);
        downloadClient.Dispose();
    }

    private async void OnDownloadRequested(object? sender, EventArgs eventArgs) =>
        await PrepareAsync(disclosureAccepted: true).ConfigureAwait(true);

    private void OnCancelRequested(object? sender, EventArgs eventArgs) => manager.CancelActive();

    private async Task PrepareAsync(bool disclosureAccepted)
    {
        if (disposed)
        {
            return;
        }

        try
        {
            var result = await manager.PrepareAsync(disclosureAccepted).ConfigureAwait(true);
            switch (result.Status)
            {
                case ModelPreparationStatus.Ready:
                    ReadyModelPath = result.ModelPath
                        ?? throw new InvalidOperationException("A ready model result must include its verified path.");
                    window.ShowModelReady();
                    ModelReady?.Invoke(ReadyModelPath);
                    break;
                case ModelPreparationStatus.DisclosureRequired:
                    window.ShowModelDisclosure(ProductModel.Default.SizeBytes);
                    break;
                case ModelPreparationStatus.InsufficientSpace:
                    window.ShowModelSpaceError(result.RequiredBytes, result.AvailableBytes);
                    break;
                case ModelPreparationStatus.Cancelled:
                    window.ShowModelCancelled();
                    break;
                case ModelPreparationStatus.VerificationFailed:
                    window.ShowModelError("The downloaded model did not match its pinned size and SHA-256. The partial file was removed.");
                    break;
                default:
                    window.ShowModelError("The model could not be prepared. Check the connection and available storage, then retry.");
                    break;
            }
        }
        catch (Exception) when (!disposed)
        {
            window.ShowModelError("The model could not be prepared. Check the connection and available storage, then retry.");
        }
    }

    private void OnProgressChanged(object? sender, ModelPreparationProgress progress)
    {
        if (disposed)
        {
            return;
        }

        dispatcher.BeginInvoke(() => window.ShowModelProgress(progress));
    }
}
