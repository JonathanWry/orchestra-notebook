# 贡献指南

感谢你帮助改进配器手记。

## 提交问题

请说明：

- 操作系统与版本。
- MuseScore Studio 版本。
- 可以稳定复现的操作步骤。
- 预期行为与实际行为。
- 必要时附截图，但请遮挡私人乐谱名称和本地路径。

不要上传未经脱敏的 `library.json`。它可能包含笔记、图片和完整文件路径。

## 开发约定

- `Resources/` 是两个平台共享的界面层；修改时同时考虑 WebKit 与 WebView2。
- macOS 原生功能放在 `Sources/main.m`。
- Windows 原生功能放在 `windows/OrchestraNotebook.Windows/`。
- 数据迁移必须向后兼容，不能静默丢弃旧笔记字段。
- 文件删除、重新定位和批量扫描必须有明确范围，不能改动原始乐谱内容。

## 提交前检查

macOS：

```zsh
node --check Resources/app.js
./build.sh
codesign --verify --deep --strict dist/配器手记.app
```

Windows：

```powershell
dotnet build .\windows\OrchestraNotebook.Windows\OrchestraNotebook.Windows.csproj -c Release
.\build-windows.ps1
```

Pull request 请尽量只解决一个主题，并在说明中列出手动验证步骤。
