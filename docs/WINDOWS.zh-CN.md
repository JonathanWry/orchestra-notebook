# Windows 使用与开发说明

## 系统要求

- Windows 10 1809 或更高版本，推荐 Windows 11。
- MuseScore Studio 4。
- Microsoft Edge WebView2 Runtime。Windows 11 和多数仍受支持的 Windows 10 已预装。

GitHub Actions 提供的 `win-x64` 包包含 .NET 运行时，不需要另外安装 .NET。

## 第一次运行

1. 解压整个 ZIP，不要只把 `OrchestraNotebook.exe` 单独拖出来。
2. 运行 `OrchestraNotebook.exe`。首次运行会在当前用户的开始菜单创建“配器手记”快捷方式；之后可通过 Windows 搜索启动。
3. 点击“设置 MuseScore 连接”。插件会复制到：

   ```text
   %USERPROFILE%\Documents\MuseScore4\Plugins\OrchestraNotebookCapture.qml
   ```

4. 完整退出 MuseScore Studio，再重新打开。
5. 在 MuseScore 插件管理器中启用“配器手记：从选区新建笔记”。

## 数据位置

```text
%APPDATA%\Orchestra Notebook\library.json
```

图片以 data URL 保存在同一个 JSON 文件中。定期备份这个文件即可备份全部笔记；原始 `.mscz/.mscx` 文件需要单独备份。

## MuseScore 选区连接

插件把选区写到：

```text
%USERPROFILE%\Documents\MuseScore4\OrchestraNotebook\selection.json
```

App 每 750 ms 检查一次这个本地文件。选区数据只包含文件路径、小节号、tick 和 staff 范围，不经过网络。

## 回跳行为

点击小节链接后，Windows 会：

1. 通过默认文件关联打开 `.mscz/.mscx`。
2. 查找 MuseScore 前台窗口。
3. 发送 `Ctrl+F`、小节号和 Enter。

如果 Windows 阻止切换前台，App 会保留已打开的乐谱，并把小节号复制到剪贴板。

## 从源码构建

安装 .NET 8 SDK 后，在仓库根目录运行：

```powershell
.\build-windows.ps1
```

若只想编译：

```powershell
dotnet build .\windows\OrchestraNotebook.Windows\OrchestraNotebook.Windows.csproj -c Release
```

Windows 宿主的主要文件：

- `MainForm.cs`：WebView2、文件对话框、剪贴板、插件连接与导出。
- `ScoreParser.cs`：读取 `.mscx`，或从 `.mscz` ZIP 中提取主 XML 和缩略图。
- `OrchestraNotebook.Windows.csproj`：依赖、资源复制与版本。

## 故障排查

### 界面空白或提示缺少 WebView2

安装 Microsoft Edge WebView2 Evergreen Runtime，然后重新打开 App。

### MuseScore 插件运行后没有出现笔记

- 确认乐谱已经保存到磁盘。
- 保存后重新运行插件；`selection.json` 中应包含非空的 `scorePath`。
- 检查插件是否已启用。
- 检查 `selection.json` 是否在上面的目录中更新。
- 如果“文档”目录被 OneDrive 重定向，请确认 MuseScore 的 `homePath()/Documents` 与 `%USERPROFILE%\Documents` 是否仍指向同一位置；若不同，请提交 issue 并附上脱敏后的两个路径。

### 无法跳到小节

确认 `.mscz/.mscx` 已与 MuseScore 4 关联。自动输入失败时，直接在 MuseScore 中按 `Ctrl+F`，粘贴已经复制的小节号。
