#
# 生成"通用安装包"（不依赖 opkg/apk），适用于任何 OpenWrt
#
#   powershell -ExecutionPolicy Bypass -File Tools/build-manual.ps1
#
# 产物：dist/systemmon-<ver>-manual.tar.gz
# 目标机：tar -xzf 该文件 && cd systemmon-<ver> && sh install.sh

param(
    [string]$SourceDir,
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $SourceDir) { $SourceDir = Join-Path $here '..\luci-app-systemmon' }
if (-not $OutDir)    { $OutDir    = Join-Path $here '..\dist' }

$SourceDir = [System.IO.Path]::GetFullPath($SourceDir)
$OutDir    = [System.IO.Path]::GetFullPath($OutDir)
$ver = '1.3.0'
$name = "systemmon-$ver"

$stage = Join-Path $OutDir '_manual'
if (Test-Path $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
$pkg = Join-Path $stage $name
New-Item -ItemType Directory -Path $pkg -Force | Out-Null

# 脚本
Copy-Item (Join-Path $here 'install-any.sh')   (Join-Path $pkg 'install.sh')   -Force
Copy-Item (Join-Path $here 'uninstall-any.sh') (Join-Path $pkg 'uninstall.sh') -Force

# 根文件系统（systemmon + LuCI 合并到同一棵树）
$root = Join-Path $pkg 'root'
New-Item -ItemType Directory -Path $root -Force | Out-Null

function Copy-Tree([string]$src, [string]$dst) {
    New-Item -ItemType Directory -Path $dst -Force | Out-Null
    & robocopy $src $dst /E /NFL /NDL /NJH /NJS /NC /NS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "复制失败（robocopy $LASTEXITCODE）：$src -> $dst" }
    $global:LASTEXITCODE = 0
}

Copy-Tree (Join-Path $SourceDir 'files') $root
$luci = Join-Path $SourceDir 'luci'
if (Test-Path $luci) { Copy-Tree $luci $root }

# 统一换行，避免 Windows 编辑器改坏
Get-ChildItem -LiteralPath $pkg -Recurse -File | ForEach-Object {
    if ($_.Extension -in @('.sh', '.js', '.html', '.css', '.json', '.svg') -or $_.Name -in @('systemmon', 'status', 'devices', 'config', 'diag')) {
        $text = [System.IO.File]::ReadAllText($_.FullName)
        if ($text.Contains("`r`n")) {
            $text = $text.Replace("`r`n", "`n")
            [System.IO.File]::WriteAllText($_.FullName, $text, (New-Object System.Text.UTF8Encoding($false)))
        }
    }
}

$tar = Join-Path $OutDir "$name-manual.tar.gz"
if (Test-Path $tar) { Remove-Item -LiteralPath $tar -Force }

Push-Location $stage
try {
    & tar.exe -czf $tar $name
    if ($LASTEXITCODE -ne 0) { throw "tar 打包失败（exit $LASTEXITCODE）" }
}
finally {
    Pop-Location
}

Remove-Item -LiteralPath $stage -Recurse -Force
Write-Host ("-> {0}  ({1:N1} KB)" -f (Split-Path $tar -Leaf), ((Get-Item $tar).Length / 1KB))
Write-Host '目标机解压后执行 sh install.sh'
