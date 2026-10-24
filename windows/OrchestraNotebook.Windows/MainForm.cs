using System.Diagnostics;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace OrchestraNotebook.WindowsHost;

internal sealed class MainForm : Form
{
    private readonly WebView2 _webView = new() { Dock = DockStyle.Fill, AllowExternalDrop = true };
    private readonly System.Windows.Forms.Timer _selectionTimer = new() { Interval = 750 };
    private readonly JsonSerializerOptions _jsonOptions = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    private readonly string _dataDirectory;
    private readonly string _libraryPath;
    private readonly string _selectionPath;
    private readonly string _pluginPath;
    private bool _pageReady;
    private double _lastSelectionTimestamp;

    public MainForm()
    {
        Text = "配器手记";
        Width = 1280;
        Height = 820;
        MinimumSize = new Size(960, 640);
        StartPosition = FormStartPosition.CenterScreen;
        Controls.Add(_webView);

        _dataDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Orchestra Notebook");
        _libraryPath = Path.Combine(_dataDirectory, "library.json");
        var museScoreDocuments = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Documents", "MuseScore4");
        _selectionPath = Path.Combine(museScoreDocuments, "OrchestraNotebook", "selection.json");
        _pluginPath = Path.Combine(museScoreDocuments, "Plugins", "OrchestraNotebookCapture.qml");

        Load += async (_, _) => await InitializeWebViewAsync();
        _selectionTimer.Tick += async (_, _) => await CheckMuseScoreSelectionAsync();
        FormClosed += (_, _) => _selectionTimer.Stop();
    }

    private async Task InitializeWebViewAsync()
    {
        try
        {
            Directory.CreateDirectory(_dataDirectory);
            EnsureStartMenuShortcut();
            await _webView.EnsureCoreWebView2Async();
            _webView.CoreWebView2.Settings.AreDevToolsEnabled = false;
            _webView.CoreWebView2.Settings.IsStatusBarEnabled = false;
            _webView.CoreWebView2.WebMessageReceived += async (_, args) => await HandleMessageAsync(args.WebMessageAsJson);
            var resources = Path.Combine(AppContext.BaseDirectory, "Resources");
            _webView.CoreWebView2.SetVirtualHostNameToFolderMapping("appassets.local", resources, CoreWebView2HostResourceAccessKind.DenyCors);
            _webView.NavigationCompleted += async (_, args) =>
            {
                if (!args.IsSuccess || _pageReady) return;
                _pageReady = true;
                await SendLibraryAsync();
                _selectionTimer.Start();
                await CheckMuseScoreSelectionAsync();
            };
            _webView.Source = new Uri("https://appassets.local/index.html");
        }
        catch (Exception error)
        {
            MessageBox.Show(this, $"无法启动界面：\n{error.Message}\n\n请确认 Microsoft Edge WebView2 Runtime 已安装。", "配器手记", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    // This is a portable ZIP distribution, so register a per-user Start menu
    // shortcut on launch rather than requiring an installer or administrator rights.
    private static void EnsureStartMenuShortcut()
    {
        try
        {
            var programs = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.StartMenu), "Programs", "配器手记");
            Directory.CreateDirectory(programs);
            var shortcutPath = Path.Combine(programs, "配器手记.lnk");
            var shellType = Type.GetTypeFromProgID("WScript.Shell");
            if (shellType is null) return;
            dynamic shell = Activator.CreateInstance(shellType)!;
            dynamic shortcut = shell.CreateShortcut(shortcutPath);
            shortcut.TargetPath = Application.ExecutablePath;
            shortcut.WorkingDirectory = AppContext.BaseDirectory;
            shortcut.IconLocation = $"{Application.ExecutablePath},0";
            shortcut.Description = "配器手记 Orchestra Notebook";
            shortcut.Save();
            if (Marshal.IsComObject(shortcut)) Marshal.FinalReleaseComObject(shortcut);
            if (Marshal.IsComObject(shell)) Marshal.FinalReleaseComObject(shell);
        }
        catch
        {
            // A shortcut failure must never prevent the portable app from opening.
        }
    }

    private async Task HandleMessageAsync(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            var type = root.TryGetProperty("type", out var typeElement) ? typeElement.GetString() : null;
            switch (type)
            {
                case "chooseScore": await ChooseScoreAsync(); break;
                case "relocateScore": await RelocateScoreAsync(root.Clone()); break;
                case "scanScoreFolder": await ScanScoreFolderAsync(root.Clone()); break;
                case "captureSelection": CaptureSelection(); break;
                case "installPlugin": InstallPlugin(true); break;
                case "pasteImage": await PasteImageAsync(); break;
                case "chooseNoteImage": await ChooseNoteImageAsync(); break;
                case "exportNote": await ExportNoteAsync(root.GetProperty("payload").Clone()); break;
                case "saveLibrary": SaveLibrary(root.GetProperty("payload").GetRawText()); break;
                case "openRoute": await OpenRouteAsync(root.GetProperty("payload").Clone()); break;
                case "revealFile": RevealFile(root.TryGetProperty("path", out var path) ? path.GetString() : null); break;
                case "copyPNG": CopyPng(root.TryGetProperty("data", out var data) ? data.GetString() : null); break;
            }
        }
        catch (Exception error)
        {
            MessageBox.Show(this, error.Message, "操作失败", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    private async Task SendLibraryAsync()
    {
        var json = File.Exists(_libraryPath)
            ? await File.ReadAllTextAsync(_libraryPath, Encoding.UTF8)
            : "{\"version\":8,\"scores\":{},\"order\":[],\"customInstruments\":[]}";
        await CallJavaScriptRawAsync("receiveLibrary", json);
    }

    private void SaveLibrary(string json)
    {
        Directory.CreateDirectory(_dataDirectory);
        var temporary = _libraryPath + ".tmp";
        File.WriteAllText(temporary, json, new UTF8Encoding(false));
        File.Move(temporary, _libraryPath, true);
    }

    private async Task ChooseScoreAsync()
    {
        using var dialog = new OpenFileDialog
        {
            Title = "选择 MuseScore 乐谱",
            Filter = "MuseScore 乐谱 (*.mscz;*.mscx)|*.mscz;*.mscx",
            CheckFileExists = true,
            Multiselect = false
        };
        if (dialog.ShowDialog(this) == DialogResult.OK) await OpenScoreAsync(dialog.FileName);
    }

    private async Task OpenScoreAsync(string path)
    {
        await SetBusyAsync(true, "正在解析乐器与小节…");
        try
        {
            var score = await Task.Run(() => ScoreParser.Parse(path));
            await CallJavaScriptAsync("receiveScore", score);
        }
        catch (Exception error) { MessageBox.Show(this, error.Message, "无法读取乐谱", MessageBoxButtons.OK, MessageBoxIcon.Warning); }
        finally { await SetBusyAsync(false); }
    }

    private async Task RelocateScoreAsync(JsonElement message)
    {
        var scoreId = message.TryGetProperty("scoreId", out var id) ? id.GetString() ?? "" : "";
        var oldPath = message.TryGetProperty("oldPath", out var old) ? old.GetString() ?? "" : "";
        var scoreTitle = message.TryGetProperty("scoreTitle", out var title) ? title.GetString() ?? "这部乐谱" : "这部乐谱";
        using var dialog = new OpenFileDialog
        {
            Title = "重新定位 MuseScore 乐谱",
            Filter = "MuseScore 乐谱 (*.mscz;*.mscx)|*.mscz;*.mscx",
            CheckFileExists = true
        };
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        await SetBusyAsync(true, "正在验证并重新定位乐谱…");
        try
        {
            var score = await Task.Run(() => ScoreParser.Parse(dialog.FileName));
            var answer = MessageBox.Show(this,
                $"旧位置：\n{oldPath}\n\n新位置：\n{dialog.FileName}\n\n更新后会保留全部笔记、谱例和小节范围。",
                $"确认重新定位“{scoreTitle}”？", MessageBoxButtons.OKCancel, MessageBoxIcon.Question);
            if (answer == DialogResult.OK) await CallJavaScriptAsync("receiveRelocatedScore", new { scoreId, score });
        }
        catch (Exception error) { MessageBox.Show(this, error.Message, "无法读取新位置的乐谱", MessageBoxButtons.OK, MessageBoxIcon.Warning); }
        finally { await SetBusyAsync(false); }
    }

    private async Task ScanScoreFolderAsync(JsonElement message)
    {
        using var dialog = new FolderBrowserDialog
        {
            Description = "递归扫描文件夹；仅自动修复旧路径已失效且文件名唯一匹配的乐谱。",
            UseDescriptionForTitle = true,
            ShowNewFolderButton = false
        };
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        var entries = message.TryGetProperty("entries", out var values)
            ? values.EnumerateArray().Select(value => new ScoreEntry(
                value.TryGetProperty("scoreId", out var id) ? id.GetString() ?? "" : "",
                value.TryGetProperty("path", out var path) ? path.GetString() ?? "" : "")).ToList()
            : new List<ScoreEntry>();
        await SetBusyAsync(true, "正在扫描乐谱文件夹…");
        try
        {
            var result = await Task.Run(() =>
            {
                var files = EnumerateScoreFiles(dialog.SelectedPath).ToList();
                var byName = files.GroupBy(file => Path.GetFileName(file) ?? string.Empty, StringComparer.OrdinalIgnoreCase)
                    .ToDictionary(group => group.Key, group => group.ToList(), StringComparer.OrdinalIgnoreCase);
                var matches = new List<object>();
                var missing = 0; var ambiguous = 0; var unmatched = 0;
                foreach (var entry in entries)
                {
                    if (entry.ScoreId.Length == 0 || entry.Path.Length == 0 || File.Exists(entry.Path)) continue;
                    missing++;
                    var candidates = byName.GetValueOrDefault(Path.GetFileName(entry.Path)) ?? new List<string>();
                    if (candidates.Count == 1) matches.Add(new { scoreId = entry.ScoreId, oldPath = entry.Path, newPath = candidates[0] });
                    else if (candidates.Count > 1) ambiguous++;
                    else unmatched++;
                }
                return new { matches, missing, ambiguous, unmatched, scanned = files.Count, root = dialog.SelectedPath };
            });
            await CallJavaScriptAsync("receiveScoreScanResults", result);
        }
        finally { await SetBusyAsync(false); }
    }

    private static IEnumerable<string> EnumerateScoreFiles(string root)
    {
        var pending = new Stack<string>(); pending.Push(root);
        while (pending.Count > 0)
        {
            var directory = pending.Pop();
            IEnumerable<string> directories = Array.Empty<string>(); IEnumerable<string> files = Array.Empty<string>();
            try { directories = Directory.EnumerateDirectories(directory); files = Directory.EnumerateFiles(directory); } catch { }
            foreach (var child in directories) pending.Push(child);
            foreach (var file in files)
                if (Path.GetExtension(file).Equals(".mscz", StringComparison.OrdinalIgnoreCase) || Path.GetExtension(file).Equals(".mscx", StringComparison.OrdinalIgnoreCase))
                    yield return file;
        }
    }

    private bool InstallPlugin(bool showHelp)
    {
        try
        {
            var source = Path.Combine(AppContext.BaseDirectory, "Resources", "OrchestraNotebookCapture.qml");
            Directory.CreateDirectory(Path.GetDirectoryName(_pluginPath)!);
            File.Copy(source, _pluginPath, true);
            Directory.CreateDirectory(Path.GetDirectoryName(_selectionPath)!);
            if (showHelp) MessageBox.Show(this,
                "请完整退出 MuseScore Studio 后重新打开，在插件管理器启用“配器手记：从选区新建笔记”。\n\n先从“插件”菜单运行一次；之后可在快捷键设置中分配 Ctrl+Alt+N。",
                "MuseScore 连接已安装", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return true;
        }
        catch (Exception error)
        {
            MessageBox.Show(this, error.Message, "无法安装 MuseScore 连接", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return false;
        }
    }

    private void CaptureSelection()
    {
        var source = Path.Combine(AppContext.BaseDirectory, "Resources", "OrchestraNotebookCapture.qml");
        if (!File.Exists(_pluginPath) || !File.ReadAllBytes(source).SequenceEqual(File.ReadAllBytes(_pluginPath)))
        {
            InstallPlugin(true); return;
        }
        var executable = FindMuseScoreExecutable();
        if (executable is not null) Process.Start(new ProcessStartInfo(executable) { UseShellExecute = true });
        _ = CallJavaScriptAsync("showToast", new { message = "请在 MuseScore 选择区间，再运行“配器手记：从选区新建笔记”" });
    }

    private async Task CheckMuseScoreSelectionAsync()
    {
        if (!File.Exists(_selectionPath)) return;
        try
        {
            using var document = JsonDocument.Parse(await File.ReadAllTextAsync(_selectionPath, Encoding.UTF8));
            var selection = document.RootElement.Clone();
            var timestamp = selection.TryGetProperty("timestamp", out var time) ? time.GetDouble() : 0;
            if (timestamp <= _lastSelectionTimestamp || DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - timestamp > 30_000) return;
            _lastSelectionTimestamp = timestamp;
            var scorePath = ResolveMuseScorePath(selection);
            if (string.IsNullOrWhiteSpace(scorePath) || !File.Exists(scorePath))
            {
                MessageBox.Show(this, "请先保存当前 MuseScore 乐谱，再重新运行插件。", "无法接收选区", MessageBoxButtons.OK, MessageBoxIcon.Warning); return;
            }
            await SetBusyAsync(true, "正在读取选区位置…");
            var score = await Task.Run(() => ScoreParser.Parse(scorePath));
            await CallJavaScriptAsync("receiveScore", score);
            var resolvedSelection = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(selection.GetRawText())
                ?? new Dictionary<string, JsonElement>();
            resolvedSelection["scorePath"] = JsonSerializer.SerializeToElement(scorePath);
            await CallJavaScriptRawAsync("receiveMuseScoreSelection", JsonSerializer.Serialize(resolvedSelection, _jsonOptions));
            Show(); WindowState = FormWindowState.Normal; Activate(); BringToFront();
        }
        catch (Exception error) { MessageBox.Show(this, error.Message, "无法读取 MuseScore 选区", MessageBoxButtons.OK, MessageBoxIcon.Warning); }
        finally { if (_pageReady) await SetBusyAsync(false); }
    }

    // MuseScore 4 no longer exposes the active score's path to QML plugins.
    // Its session file is the supported local record of open score documents.
    private static string? ResolveMuseScorePath(JsonElement selection)
    {
        if (selection.TryGetProperty("scorePath", out var supplied) && supplied.GetString() is { Length: > 0 } suppliedPath && File.Exists(suppliedPath))
            return suppliedPath;

        var sessionPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "MuseScore", "MuseScore4", "session", "session.json");
        try
        {
            var paths = JsonSerializer.Deserialize<List<string>>(File.ReadAllText(sessionPath, Encoding.UTF8)) ?? [];
            var title = selection.TryGetProperty("scoreTitle", out var titleElement) ? titleElement.GetString() : null;
            var existing = paths.Where(File.Exists).ToList();
            var matchingTitle = existing.LastOrDefault(path =>
                !string.IsNullOrWhiteSpace(title) &&
                string.Equals(Path.GetFileNameWithoutExtension(path), title, StringComparison.OrdinalIgnoreCase));
            return matchingTitle ?? existing.LastOrDefault();
        }
        catch (IOException) { return null; }
        catch (JsonException) { return null; }
    }

    private Task PasteImageAsync()
    {
        if (!Clipboard.ContainsImage()) return CallJavaScriptAsync("receiveClipboardImage", new { });
        using var image = Clipboard.GetImage();
        if (image is null) return CallJavaScriptAsync("receiveClipboardImage", new { });
        using var stream = new MemoryStream(); image.Save(stream, ImageFormat.Png);
        return CallJavaScriptAsync("receiveClipboardImage", new { dataURL = "data:image/png;base64," + Convert.ToBase64String(stream.ToArray()) });
    }

    private async Task ChooseNoteImageAsync()
    {
        using var dialog = new OpenFileDialog { Title = "选择要插入笔记的图片", Filter = "图片|*.png;*.jpg;*.jpeg;*.gif;*.webp;*.bmp" };
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        var info = new FileInfo(dialog.FileName);
        if (info.Length > 8 * 1024 * 1024)
        {
            await CallJavaScriptAsync("receiveUploadedImage", new { error = "图片请控制在 8 MB 以内" }); return;
        }
        var mime = Path.GetExtension(dialog.FileName).ToLowerInvariant() switch
        {
            ".jpg" or ".jpeg" => "image/jpeg", ".gif" => "image/gif", ".webp" => "image/webp", ".bmp" => "image/bmp", _ => "image/png"
        };
        var dataUrl = $"data:{mime};base64,{Convert.ToBase64String(await File.ReadAllBytesAsync(dialog.FileName))}";
        await CallJavaScriptAsync("receiveUploadedImage", new { dataURL = dataUrl, name = Path.GetFileName(dialog.FileName) });
    }

    private async Task ExportNoteAsync(JsonElement payload)
    {
        var format = payload.TryGetProperty("format", out var formatElement) ? formatElement.GetString()?.ToLowerInvariant() : null;
        if (format is not ("md" or "pdf")) return;
        var title = payload.TryGetProperty("title", out var titleElement) ? titleElement.GetString() ?? "无标题" : "无标题";
        var safeTitle = string.Join("-", title.Split(Path.GetInvalidFileNameChars(), StringSplitOptions.RemoveEmptyEntries));
        if (safeTitle.Length == 0) safeTitle = "无标题";
        using var dialog = new SaveFileDialog
        {
            Title = format == "pdf" ? "导出笔记为 PDF" : "导出笔记为 Markdown",
            Filter = format == "pdf" ? "PDF 文件 (*.pdf)|*.pdf" : "Markdown 文件 (*.md)|*.md",
            FileName = safeTitle + "." + format,
            AddExtension = true
        };
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        if (format == "md")
        {
            var markdown = payload.TryGetProperty("markdown", out var content) ? content.GetString() ?? "" : "";
            await File.WriteAllTextAsync(dialog.FileName, markdown, new UTF8Encoding(false));
            await CallJavaScriptAsync("showToast", new { message = "Markdown 已导出" }); return;
        }
        var html = payload.TryGetProperty("html", out var htmlElement) ? htmlElement.GetString() ?? "" : "";
        await ExportPdfAsync(html, dialog.FileName);
        await CallJavaScriptAsync("showToast", new { message = "PDF 已导出" });
    }

    private async Task ExportPdfAsync(string html, string destination)
    {
        using var printable = new WebView2 { Size = new Size(794, 1123), Location = new Point(-2000, -2000) };
        Controls.Add(printable);
        try
        {
            await printable.EnsureCoreWebView2Async();
            var loaded = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            printable.NavigationCompleted += (_, args) =>
            {
                if (args.IsSuccess) loaded.TrySetResult();
                else loaded.TrySetException(new InvalidOperationException("PDF 页面载入失败。"));
            };
            printable.NavigateToString(html);
            await loaded.Task;
            var settings = printable.CoreWebView2.Environment.CreatePrintSettings();
            settings.PageWidth = 8.27; settings.PageHeight = 11.69;
            settings.MarginTop = 0.45; settings.MarginBottom = 0.45; settings.MarginLeft = 0.5; settings.MarginRight = 0.5;
            settings.ShouldPrintBackgrounds = true;
            settings.ShouldPrintHeaderAndFooter = false;
            if (!await printable.CoreWebView2.PrintToPdfAsync(destination, settings)) throw new InvalidOperationException("PDF 生成失败。");
        }
        finally { Controls.Remove(printable); }
    }

    private async Task OpenRouteAsync(JsonElement payload)
    {
        var path = payload.TryGetProperty("path", out var file) ? file.GetString() : null;
        if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
        {
            MessageBox.Show(this, "文件可能被移动或重命名，请先使用“重新定位乐谱…”。", "找不到原乐谱", MessageBoxButtons.OK, MessageBoxIcon.Warning); return;
        }
        var measure = payload.TryGetProperty("measure", out var measureElement) && measureElement.ValueKind == JsonValueKind.Number ? measureElement.GetInt32() : 0;
        Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
        if (measure <= 0) return;
        Clipboard.SetText(measure.ToString());
        await Task.Delay(1800);
        var museScore = Process.GetProcesses().Where(process => process.ProcessName.Contains("MuseScore", StringComparison.OrdinalIgnoreCase))
            .OrderByDescending(process => process.StartTime).FirstOrDefault(process => process.MainWindowHandle != IntPtr.Zero);
        if (museScore is not null && SetForegroundWindow(museScore.MainWindowHandle))
        {
            await Task.Delay(250); SendKeys.SendWait("^f"); await Task.Delay(250); SendKeys.SendWait(measure.ToString()); SendKeys.SendWait("{ENTER}");
            await CallJavaScriptAsync("showToast", new { message = $"已跳转到 m.{measure}" });
        }
        else await CallJavaScriptAsync("showToast", new { message = $"已打开乐谱；小节号 {measure} 已复制" });
    }

    private static string? FindMuseScoreExecutable()
    {
        var roots = new[] { Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86) };
        var relative = new[] { @"MuseScore 4\bin\MuseScore4.exe", @"MuseScore 4\bin\mscore.exe", @"MuseScore 4\MuseScore4.exe" };
        return roots.SelectMany(root => relative.Select(path => Path.Combine(root, path))).FirstOrDefault(File.Exists);
    }

    private static void RevealFile(string? path)
    {
        if (!string.IsNullOrWhiteSpace(path) && File.Exists(path)) Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true });
    }

    private void CopyPng(string? dataUrl)
    {
        if (string.IsNullOrWhiteSpace(dataUrl) || !dataUrl.Contains(',')) return;
        using var stream = new MemoryStream(Convert.FromBase64String(dataUrl[(dataUrl.IndexOf(',') + 1)..]));
        using var image = Image.FromStream(stream); Clipboard.SetImage(new Bitmap(image));
        _ = CallJavaScriptAsync("showToast", new { message = "可视化已复制到剪贴板" });
    }

    private Task SetBusyAsync(bool busy, string? message = null) => CallJavaScriptAsync("setBusy", new { busy, message });
    private Task CallJavaScriptAsync(string function, object payload) => CallJavaScriptRawAsync(function, JsonSerializer.Serialize(payload, _jsonOptions));
    private async Task CallJavaScriptRawAsync(string function, string json)
    {
        if (_pageReady && _webView.CoreWebView2 is not null) await _webView.ExecuteScriptAsync($"window.{function}({json})");
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(IntPtr windowHandle);

    private sealed record ScoreEntry(string ScoreId, string Path);
}
