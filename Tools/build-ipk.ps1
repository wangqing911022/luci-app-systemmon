<#
.SYNOPSIS
    从源码目录直接生成 OpenWrt .ipk 安装包（无需 Linux 工具链）。

.DESCRIPTION
    systemmon 是纯脚本 + 静态资源包，架构为 all，因此可以在 Windows 上
    手工组装 opkg 需要的 ar + control.tar.gz + data.tar.gz 结构。

    .apk（apk-tools）不在本脚本内生成：apk 的包格式由构建机上的
    `apk mkpkg` 决定，请使用 .github/workflows/BUILD-PKG.yml（SDK 构建）
    或路由器本机的 Tools/mkpkg-on-device.sh。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File Tools/build-ipk.ps1
#>

[CmdletBinding()]
param(
    [string]$SourceDir,
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $SourceDir) { $SourceDir = Join-Path $here '..\luci-app-systemmon' }
if (-not $OutDir)    { $OutDir    = Join-Path $here '..\dist' }

$SourceDir = [System.IO.Path]::GetFullPath($SourceDir)
$OutDir    = [System.IO.Path]::GetFullPath($OutDir)
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

$Epoch = 1700000000   # 固定 mtime，保证可重复构建

# ---------------------------------------------------------------- tar / ar

function ConvertTo-OctBytes([int]$Value, [int]$Length) {
    $s = [Convert]::ToString($Value, 8).PadLeft($Length - 1, '0') + "`0"
    return [System.Text.Encoding]::ASCII.GetBytes($s)
}

function Write-TarEntry {
    param(
        [System.IO.Stream]$Stream,
        [string]$Name,
        [int]$Mode,
        [byte[]]$Data,
        [bool]$IsDir = $false
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Name)
    if ($bytes.Length -gt 100) { throw "tar 路径过长（>100）：$Name" }

    $header = New-Object byte[] 512
    [Array]::Copy($bytes, 0, $header, 0, $bytes.Length)

    $b = ConvertTo-OctBytes $Mode 8
    [Array]::Copy($b, 0, $header, 100, 8)

    $b = ConvertTo-OctBytes 0 8      # uid
    [Array]::Copy($b, 0, $header, 108, 8)
    $b = ConvertTo-OctBytes 0 8      # gid
    [Array]::Copy($b, 0, $header, 116, 8)

    $size = 0
    if (-not $IsDir -and $Data -ne $null) { $size = $Data.Length }

    $b = ConvertTo-OctBytes $size 12                       # size
    [Array]::Copy($b, 0, $header, 124, 12)
    $b = ConvertTo-OctBytes $Epoch 12                      # mtime
    [Array]::Copy($b, 0, $header, 136, 12)

    for ($i = 148; $i -le 155; $i++) { $header[$i] = 0x20 }   # 校验和占位

    $header[156] = [byte][char]$(if ($IsDir) { '5' } else { '0' })

    $magic = [System.Text.Encoding]::ASCII.GetBytes("ustar`0" + "00")
    [Array]::Copy($magic, 0, $header, 257, 6)
    $header[263] = 0x30; $header[264] = 0x30

    $sum = 0
    foreach ($x in $header) { $sum += $x }
    $cs = [Convert]::ToString($sum, 8).PadLeft(6, '0')
    $csBytes = [System.Text.Encoding]::ASCII.GetBytes($cs)
    [Array]::Copy($csBytes, 0, $header, 148, 6)
    $header[154] = 0
    $header[155] = 0x20

    $Stream.Write($header, 0, 512)

    if (-not $IsDir -and $Data -ne $null -and $Data.Length -gt 0) {
        $Stream.Write($Data, 0, $Data.Length)
        $pad = (512 - ($Data.Length % 512)) % 512
        if ($pad -gt 0) { $Stream.Write((New-Object byte[] $pad), 0, $pad) }
    }
}

function New-TarGz {
    param([object[]]$Entries, [string]$OutFile)

    $ms = New-Object System.IO.MemoryStream
    foreach ($e in $Entries) {
        Write-TarEntry -Stream $ms -Name $e.Name -Mode $e.Mode -Data $e.Data -IsDir $e.IsDir
    }
    $ms.Write((New-Object byte[] 1024), 0, 1024)
    $ms.Position = 0

    $fs = [System.IO.File]::Create($OutFile)
    $gz = New-Object System.IO.Compression.GZipStream($fs, [System.IO.Compression.CompressionLevel]::Optimal)
    $ms.CopyTo($gz)
    $gz.Dispose()
    $fs.Dispose()
    $ms.Dispose()
}

function New-ArArchive {
    param([object[]]$Entries, [string]$OutFile)   # Entries: Name, Path

    $fs = [System.IO.File]::Create($OutFile)
    $magic = [System.Text.Encoding]::ASCII.GetBytes("!<arch>`n")
    $fs.Write($magic, 0, $magic.Length)

    foreach ($e in $Entries) {
        $data = [System.IO.File]::ReadAllBytes($e.Path)
        $name = ($e.Name + '/').PadRight(16)
        $head = $name +
                $Epoch.ToString().PadRight(12) +
                '0'.PadRight(6) +
                '0'.PadRight(6) +
                '100644'.PadRight(8) +
                $data.Length.ToString().PadRight(10) + [char]0x60 +
                "`n"
        $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
        if ($hb.Length -ne 60) { throw "ar 头长度错误：$($hb.Length)" }
        $fs.Write($hb, 0, 60)
        $fs.Write($data, 0, $data.Length)
        if ($data.Length % 2 -ne 0) { $fs.WriteByte(0x0A) }
    }
    $fs.Dispose()
}

# ---------------------------------------------------------------- 打包

function Get-EntriesFromDir {
    param([string]$Root, [string]$Prefix, [string]$ModeRule)

    $result = New-Object System.Collections.ArrayList
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')

    Get-ChildItem -LiteralPath $Root -Recurse -Force | Sort-Object FullName | ForEach-Object {
        $rel = $_.FullName.Substring($rootFull.Length + 1).Replace('\', '/')
        $name = "./$Prefix$rel"

        if ($_.PSIsContainer) {
            [void]$result.Add(@{ Name = "$name/"; Mode = 493; IsDir = $true; Data = $null })
            return
        }

        $mode = 420   # 0644
        if ($ModeRule -eq 'systemmon') {
            if ($rel -match '^etc/init\.d/' -or
                $rel -match '^etc/uci-defaults/' -or
                $rel -match '^usr/libexec/' -or
                $rel -match '/cgi-bin/') { $mode = 493 }   # 0755
        }

        [void]$result.Add(@{
            Name = $name
            Mode = $mode
            IsDir = $false
            Data = [System.IO.File]::ReadAllBytes($_.FullName)
        })
    }
    return ,$result
}

function New-Ipk {
    param(
        [string]$PkgName,
        [string]$Version,
        [string[]]$Depends,
        [string]$Section,
        [string]$Description,
        [string]$SourceDir,
        [string]$FileRoot,
        [string]$ModeRule,
        [string]$Postinst,
        [string]$Prerm,
        [string[]]$Conffiles,
        [string]$OutDir
    )

    $data = Get-EntriesFromDir -Root $FileRoot -Prefix '' -ModeRule $ModeRule

    $installed = 0
    foreach ($d in $data) { if (-not $d.IsDir -and $d.Data) { $installed += $d.Data.Length } }
    $installedKb = [Math]::Ceiling($installed / 1024)

    $controlText = @(
        "Package: $PkgName"
        "Version: $Version"
        "Depends: $($Depends -join ', ')"
        "Source: package/luci-app-systemmon"
        "SourceName: $PkgName"
        "License: MIT"
        "Section: $Section"
        "SourceDateEpoch: $Epoch"
        "Architecture: all"
        "Installed-Size: $installedKb"
        "Description: $Description"
    ) -join "`n"
    $controlText += "`n"

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ipk-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $controlPath = Join-Path $tmp 'control.tar.gz'
        $dataPath    = Join-Path $tmp 'data.tar.gz'
        $debianPath  = Join-Path $tmp 'debian-binary'

        $ctl = New-Object System.Collections.ArrayList
        [void]$ctl.Add(@{
            Name = './control'; Mode = 420; IsDir = $false
            Data = [System.Text.Encoding]::UTF8.GetBytes($controlText)
        })
        if ($Conffiles -and $Conffiles.Count -gt 0) {
            [void]$ctl.Add(@{
                Name = './conffiles'; Mode = 420; IsDir = $false
                Data = [System.Text.Encoding]::UTF8.GetBytes(($Conffiles -join "`n") + "`n")
            })
        }
        if ($Postinst) {
            [void]$ctl.Add(@{
                Name = './postinst'; Mode = 493; IsDir = $false
                Data = [System.Text.Encoding]::UTF8.GetBytes($Postinst)
            })
        }
        if ($Prerm) {
            [void]$ctl.Add(@{
                Name = './prerm'; Mode = 493; IsDir = $false
                Data = [System.Text.Encoding]::UTF8.GetBytes($Prerm)
            })
        }

        New-TarGz -Entries @($ctl) -OutFile $controlPath
        New-TarGz -Entries @($data) -OutFile $dataPath
        [System.IO.File]::WriteAllBytes($debianPath, [System.Text.Encoding]::ASCII.GetBytes("2.0`n"))

        $ipkName = "$PkgName`_$Version`_all.ipk"
        $ipkPath = Join-Path $OutDir $ipkName
        New-ArArchive -Entries @(
            @{ Name = 'debian-binary';  Path = $debianPath },
            @{ Name = 'control.tar.gz'; Path = $controlPath },
            @{ Name = 'data.tar.gz';    Path = $dataPath }
        ) -OutFile $ipkPath

        Write-Host ("  -> {0}  ({1:N1} KB, {2} 个文件)" -f $ipkName, ((Get-Item $ipkPath).Length / 1KB), $data.Count)
        return $ipkPath
    }
    finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------- 主流程

Write-Host "源码目录: $SourceDir"
Write-Host "输出目录: $OutDir"

$postinst = @"
#!/bin/sh
[ -n "`${IPKG_INSTROOT}" ] || {
	/etc/init.d/systemmon enable >/dev/null 2>&1
	/etc/init.d/systemmon restart >/dev/null 2>&1
}
exit 0
"@

$prerm = @"
#!/bin/sh
[ -n "`${IPKG_INSTROOT}" ] || {
	/etc/init.d/systemmon stop >/dev/null 2>&1
	/etc/init.d/systemmon disable >/dev/null 2>&1
}
exit 0
"@

Write-Host "[1/2] systemmon"
New-Ipk -PkgName 'systemmon' -Version '1.3.1-1' -Depends @('libc', 'uhttpd') `
    -Section 'admin' `
    -Description '本机与局域网设备状态监控：CPU、内存、温度、PON 光功率，Web 端口 7752' `
    -SourceDir $SourceDir -FileRoot (Join-Path $SourceDir 'files') -ModeRule 'systemmon' `
    -Postinst $postinst -Prerm $prerm -Conffiles @('/etc/config/systemmon') -OutDir $OutDir | Out-Null

Write-Host "[2/2] luci-app-systemmon"
New-Ipk -PkgName 'luci-app-systemmon' -Version '1.3.1-1' -Depends @('libc', 'systemmon', 'luci-base') `
    -Section 'luci' `
    -Description 'LuCI 菜单入口：状态 -> 设备监控' `
    -SourceDir $SourceDir -FileRoot (Join-Path $SourceDir 'luci') -ModeRule 'luci' `
    -Postinst $null -Prerm $null -Conffiles @() -OutDir $OutDir | Out-Null

Write-Host "完成。"
