param(
  [string]$Configuration = "Release",
  [string]$Runtime = "win-x64"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Project = Join-Path $ProjectRoot "windows/OrchestraNotebook.Windows/OrchestraNotebook.Windows.csproj"
$PublishDir = Join-Path $ProjectRoot "dist/windows-$Runtime"
$Archive = Join-Path $ProjectRoot "dist/Orchestra-Notebook-Windows-$Runtime.zip"

if (Test-Path $PublishDir) { Remove-Item $PublishDir -Recurse -Force }
if (Test-Path $Archive) { Remove-Item $Archive -Force }
New-Item -ItemType Directory -Force -Path $PublishDir | Out-Null

dotnet publish $Project -c $Configuration -r $Runtime --self-contained true -p:PublishSingleFile=false -o $PublishDir
Compress-Archive -Path (Join-Path $PublishDir "*") -DestinationPath $Archive -CompressionLevel Optimal

Write-Host "Windows 构建完成：$PublishDir"
Write-Host "安装包：$Archive"
