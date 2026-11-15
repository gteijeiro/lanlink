using System.Diagnostics;
using Microsoft.Windows.AppLifecycle;
using Windows.ApplicationModel.Activation;
using Windows.ApplicationModel.DataTransfer;
using Windows.ApplicationModel.DataTransfer.ShareTarget;
using Windows.Storage;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Contains("--self-check")) return 0;
        try
        {
            var activation = AppInstance.GetCurrent().GetActivatedEventArgs();
            if (activation.Kind == ExtendedActivationKind.ShareTarget && activation.Data is ShareTargetActivatedEventArgs shared)
                return Handle(shared.ShareOperation).GetAwaiter().GetResult();
            Launch(Array.Empty<string>());
            return 0;
        }
        catch { return 1; }
    }

    private static async Task<int> Handle(ShareOperation operation)
    {
        StorageFolder? folder = null;
        try
        {
            operation.ReportStarted();
            if (!operation.Data.Contains(StandardDataFormats.StorageItems)) throw new InvalidOperationException("Compartí uno o varios archivos.");
            var items = await operation.Data.GetStorageItemsAsync();
            if (items.Count is 0 or > 100) throw new InvalidOperationException("Podés compartir hasta 100 archivos.");
            // Clean only our expired copies, never the original shared files.
            var temporary = ApplicationData.Current.TemporaryFolder;
            foreach (var stale in await temporary.GetFoldersAsync())
                if (stale.Name.StartsWith("LanLinkShare-", StringComparison.Ordinal) && stale.DateCreated < DateTimeOffset.UtcNow.AddHours(-48))
                    try { await stale.DeleteAsync(); } catch { }
            folder = await temporary.CreateFolderAsync("LanLinkShare-" + Guid.NewGuid());
            var paths = new List<string>();
            ulong total = 0;
            foreach (var item in items)
            {
                if (item is not StorageFile file) throw new InvalidOperationException("Elegí archivos, no carpetas.");
                var info = await file.GetBasicPropertiesAsync();
                total += info.Size;
                if (total > 16UL * 1024 * 1024 * 1024) throw new InvalidOperationException("El envío supera 16 GiB.");
                var sub = await folder.CreateFolderAsync(paths.Count.ToString());
                var copy = await file.CopyAsync(sub, file.Name, NameCollisionOption.GenerateUniqueName);
                paths.Add(copy.Path);
            }
            operation.ReportDataRetrieved();
            Launch(paths);
            operation.ReportCompleted();
            return 0;
        }
        catch (Exception error)
        {
            if (folder != null) try { await folder.DeleteAsync(); } catch { }
            operation.ReportError("No se pudieron preparar los archivos para LanLink: " + error.Message);
            return 1;
        }
    }

    private static void Launch(IEnumerable<string> paths)
    {
        var executable = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "lanlink.exe"));
        if (!File.Exists(executable)) throw new FileNotFoundException("No se encontró LanLink.");
        var start = new ProcessStartInfo(executable) { UseShellExecute = false };
        foreach (var path in paths) start.ArgumentList.Add(path);
        _ = Process.Start(start) ?? throw new InvalidOperationException("No se pudo abrir LanLink.");
    }
}
