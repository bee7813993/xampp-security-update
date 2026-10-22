<#
.SYNOPSIS
    XAMPP for Windows の PHP を、PHP2Shell（CVE-2026-109618 / CVE-2026-109619）を修正した公式の PHP 8.2.35 に入れ替えます。

.DESCRIPTION
    php.net が配布している公式の Windows 版 PHP（スレッドセーフ版、x64）を用意して SHA-256 を照合し、
    XAMPP の php フォルダに上書きします。php.ini や PEAR など、XAMPP 独自のファイルはそのまま残ります。

    XAMPP は、Apache から PHP の拡張を読み込めるよう、拡張が使う DLL の一部（ICU、libssh2 など）を
    apache\bin にもコピーしています。このコピーを新しい PHP のものに更新し、新しい PHP で増えた依存 DLL
    （PHP 8.2.35 の curl 拡張が使う brotlidec.dll など）を apache\bin に追加します。

      1. XAMPP のフォルダと、いまの PHP のバージョンを確認する
      2. Apache や PHP が動いていないことを確認する
      3. 公式の zip を用意して SHA-256 を照合する
      4. php フォルダをバックアップする（php_backup_<元のバージョン>_<日時>）
      5. 新しい PHP を上書きし、apache\bin の依存 DLL をそろえる
      6. php.ini の session.upload_progress.enabled を Off にする（-NoHarden で省略）
      7. php.exe と httpd.exe -t で起動できることを確認する

    PHP がすでに 8.2.35 の場合は、apache\bin に足りない依存 DLL があれば追加だけを行います。

.PARAMETER XamppDir
    XAMPP のフォルダ。省略すると C:\xampp を使い、なければ各ドライブ直下の \xampp を探します。

.PARAMETER PhpZip
    手元にある公式の zip。省略すると、このスクリプトと同じフォルダにある zip を使い、なければ php.net から取得します。

.PARAMETER DownloadDir
    ダウンロードした zip の置き場所。既定は %TEMP%\xampp-security-update です。

.PARAMETER NoHarden
    php.ini を変更しません。

.PARAMETER Restore
    いちばん新しいバックアップに戻します（apache\bin で更新・追加した DLL も戻します）。

.PARAMETER Yes
    確認の問い合わせを省略します。

.PARAMETER Force
    PHP のバージョン系列が違う場合や、動作中のプロセスがある場合でも続行します。

.PARAMETER Staging
    XAMPP 一式の zip を組み立てるときに使います（build-package.ps1 から呼ばれます）。
    バックアップ、動作中のプロセスの確認、起動の確認を行いません。

.PARAMETER PassThru
    結果をオブジェクトで返します。

.EXAMPLE
    .\update-xampp-php.ps1

.EXAMPLE
    .\update-xampp-php.ps1 -XamppDir D:\xampp

.EXAMPLE
    .\update-xampp-php.ps1 -Restore
#>
[CmdletBinding()]
param(
    [string]$XamppDir,
    [string]$PhpZip,
    [string]$DownloadDir = (Join-Path ([IO.Path]::GetTempPath()) 'xampp-security-update'),
    [switch]$NoHarden,
    [switch]$Restore,
    [switch]$Yes,
    [switch]$Force,
    [switch]$Staging,
    [switch]$PassThru
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# 入れ替え先の PHP。SHA-256 は php.net の releases.json で公開されている値。
$Release = @{
    Version = '8.2.35'
    File    = 'php-8.2.35-Win32-vs16-x64.zip'
    Sha256  = 'cfa6000be835931961e40740bd3b51111700061d6655ddbfe5a2125807947457'
    Urls    = @(
        'https://downloads.php.net/~windows/releases/php-8.2.35-Win32-vs16-x64.zip'
        'https://downloads.php.net/~windows/releases/archives/php-8.2.35-Win32-vs16-x64.zip'
    )
    Fixes   = 'CVE-2026-109618, CVE-2026-109619'
}
$VcRedistUrl = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'
# バックアップの中で、apache\bin から退避した DLL と追加した DLL の一覧を置くフォルダ
$ApacheBackupName = '_apache_bin'

function Write-Step([string]$Message) {
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Info([string]$Message) {
    Write-Host "    $Message"
}

function Write-Note([string]$Message) {
    Write-Host "    [注意] $Message" -ForegroundColor Yellow
}

# ネイティブコマンドを実行し、標準エラーも含めた出力と終了コードを返す。
# Windows PowerShell 5.1 は $ErrorActionPreference = 'Stop' のまま 2>&1 すると
# 標準エラーへの出力で例外になるため、ここでだけ Continue にする。
function Invoke-Native([string]$FilePath, [string[]]$Arguments) {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = @(& $FilePath @Arguments 2>&1 | ForEach-Object { "$_" })
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($lines -join "`n") }
    } finally {
        $ErrorActionPreference = $saved
    }
}

function Resolve-XamppDir {
    if ($XamppDir) {
        if (-not (Test-Path -LiteralPath $XamppDir -PathType Container)) {
            throw "XAMPP のフォルダが見つかりません: $XamppDir"
        }
        return (Resolve-Path -LiteralPath $XamppDir).Path.TrimEnd('\')
    }
    if (Test-Path -LiteralPath 'C:\xampp\php\php8ts.dll') {
        return 'C:\xampp'
    }
    $found = @(
        [IO.DriveInfo]::GetDrives() |
            Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } |
            ForEach-Object { Join-Path $_.RootDirectory.FullName 'xampp' } |
            Where-Object { Test-Path -LiteralPath (Join-Path $_ 'php\php8ts.dll') }
    )
    if ($found.Count -eq 1) {
        return $found[0]
    }
    if ($found.Count -eq 0) {
        throw 'XAMPP が見つかりません。-XamppDir で XAMPP のフォルダを指定してください。'
    }
    throw ('XAMPP が複数見つかりました（{0}）。-XamppDir でどれか 1 つを指定してください。' -f ($found -join ', '))
}

function Get-PhpVersion([string]$PhpDir) {
    $dll = Join-Path $PhpDir 'php8ts.dll'
    if (-not (Test-Path -LiteralPath $dll)) {
        return $null
    }
    return (Get-Item -LiteralPath $dll).VersionInfo.ProductVersion.Trim()
}

function ConvertTo-Version([string]$Text) {
    $version = $null
    if ([version]::TryParse($Text, [ref]$version)) {
        return $version
    }
    return $null
}

function Test-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $Release.Sha256
}

function Test-SameFile([string]$Left, [string]$Right) {
    return ((Get-Item -LiteralPath $Left).Length -eq (Get-Item -LiteralPath $Right).Length) -and
        ((Get-FileHash -LiteralPath $Left).Hash -eq (Get-FileHash -LiteralPath $Right).Hash)
}

function Get-ReleaseZip {
    if ($PhpZip) {
        $path = (Resolve-Path -LiteralPath $PhpZip).Path
        if (-not (Test-Sha256 $path)) {
            throw "SHA-256 が公式の値と一致しません: $path"
        }
        return $path
    }
    foreach ($path in @((Join-Path $PSScriptRoot $Release.File), (Join-Path $DownloadDir $Release.File))) {
        if ((Test-Path -LiteralPath $path) -and (Test-Sha256 $path)) {
            return $path
        }
    }

    New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null
    $dest = Join-Path $DownloadDir $Release.File
    $part = "$dest.part"
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    foreach ($url in $Release.Urls) {
        Write-Info "ダウンロード中: $url"
        try {
            Invoke-WebRequest -Uri $url -OutFile $part -UseBasicParsing
            if (Test-Sha256 $part) {
                Move-Item -LiteralPath $part -Destination $dest -Force
                return $dest
            }
            Write-Note 'SHA-256 が公式の値と一致しないため、このファイルは使いません。'
        } catch {
            Write-Note "取得できませんでした: $($_.Exception.Message)"
        }
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
    }
    throw "公式の PHP を取得できませんでした。php.net から $($Release.File) を入手し、-PhpZip で指定してください。"
}

# この XAMPP の Apache / PHP として動いているプロセス
function Get-BlockingProcess([string]$Root) {
    $prefix = $Root + '\'
    foreach ($process in @(Get-Process -Name 'httpd', 'php', 'php-cgi', 'php-win', 'phpdbg' -ErrorAction SilentlyContinue)) {
        $path = $null
        try { $path = $process.Path } catch { }
        if ($path) {
            if ($path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                $process
            }
        } elseif ($process.ProcessName -eq 'httpd') {
            # 権限の都合で場所を読めない httpd（サービスとして動いているものなど）も止めてもらう
            $process
        }
    }
}

# この XAMPP の Apache / PHP を使っている、止まっていないサービス
function Get-BlockingService([string]$Root) {
    $prefix = $Root + '\'
    Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue | Where-Object {
        $_.State -ne 'Stopped' -and $_.PathName -and
        $_.PathName.IndexOf($prefix, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        $_.PathName -match '(?i)httpd\.exe|php'
    }
}

function Assert-NotRunning([string]$Root) {
    $services = @(Get-BlockingService $Root)
    $processes = @(Get-BlockingProcess $Root)
    if ($services.Count -eq 0 -and $processes.Count -eq 0) {
        Write-Info '問題ありません。'
        return
    }
    foreach ($service in $services) {
        Write-Note "動作中のサービス: $($service.Name)（$($service.DisplayName)）"
    }
    foreach ($process in $processes) {
        Write-Note "動作中のプロセス: $($process.ProcessName).exe（PID $($process.Id)）"
    }
    if (-not $Force) {
        throw 'XAMPP コントロールパネルで Apache を Stop してから（サービスとして登録している場合はサービスも停止してから）、もう一度実行してください。'
    }
    Write-Note '-Force が指定されているため続行します。'
}

function Confirm-Continue([string]$Question) {
    if ($Yes) {
        return
    }
    $answer = Read-Host "$Question [y/N]"
    if ($answer -notmatch '^(?i)y(es)?$') {
        Write-Host '中止しました。何も変更していません。'
        exit 2
    }
}

function Invoke-Robocopy([string]$Source, [string]$Destination, [string[]]$Options) {
    $arguments = @($Source.TrimEnd('\'), $Destination.TrimEnd('\')) + $Options + @('/R:2', '/W:1', '/NP', '/NFL', '/NDL', '/NJH', '/NJS')
    $result = Invoke-Native 'robocopy.exe' $arguments
    # robocopy は終了コード 8 以上が失敗
    if ($result.ExitCode -ge 8) {
        throw "ファイルのコピーに失敗しました（robocopy の終了コード $($result.ExitCode)）。`n$($result.Output.Trim())"
    }
}

# PE ファイル（DLL）が読み込む DLL の名前を返す（通常のインポートと遅延読み込みの両方）
function Get-PeImport([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $pe = [BitConverter]::ToInt32($bytes, 0x3C)
    if ([BitConverter]::ToUInt32($bytes, $pe) -ne 0x4550) {
        throw "PE 形式ではありません: $Path"
    }
    $sectionCount = [BitConverter]::ToUInt16($bytes, $pe + 6)
    $optionalHeader = $pe + 24
    $sectionTable = $optionalHeader + [BitConverter]::ToUInt16($bytes, $pe + 20)
    $dataDirectory = $optionalHeader + 96
    if ([BitConverter]::ToUInt16($bytes, $optionalHeader) -eq 0x20B) {
        $dataDirectory = $optionalHeader + 112
    }

    $toOffset = {
        param([long]$Rva)
        for ($i = 0; $i -lt $sectionCount; $i++) {
            $section = $sectionTable + 40 * $i
            $start = [long][BitConverter]::ToUInt32($bytes, $section + 12)
            $size = [Math]::Max([long][BitConverter]::ToUInt32($bytes, $section + 8), [long][BitConverter]::ToUInt32($bytes, $section + 16))
            if ($Rva -ge $start -and $Rva -lt $start + $size) {
                return [int]($Rva - $start + [BitConverter]::ToUInt32($bytes, $section + 20))
            }
        }
        return -1
    }
    $readName = {
        param([int]$Offset)
        $end = $Offset
        while ($bytes[$end] -ne 0) {
            $end++
        }
        return [Text.Encoding]::ASCII.GetString($bytes, $Offset, $end - $Offset)
    }

    $names = @()
    # インポート表はデータディレクトリの 1 番目（記述子 20 バイト、DLL 名の RVA は +12）、
    # 遅延読み込みは 13 番目（記述子 32 バイト、DLL 名の RVA は +4）
    foreach ($table in @(@{ Index = 1; Size = 20; NameAt = 12 }, @{ Index = 13; Size = 32; NameAt = 4 })) {
        $rva = [BitConverter]::ToUInt32($bytes, $dataDirectory + 8 * $table.Index)
        if ($rva -eq 0) {
            continue
        }
        $offset = & $toOffset $rva
        while ($offset -ge 0) {
            $nameRva = [BitConverter]::ToUInt32($bytes, $offset + $table.NameAt)
            if ($nameRva -eq 0) {
                break
            }
            $names += & $readName (& $toOffset $nameRva)
            $offset += $table.Size
        }
    }
    return $names
}

# php.ini で有効にしている拡張の DLL
function Get-EnabledExtensionFile([string]$PhpDir) {
    $ini = Join-Path $PhpDir 'php.ini'
    if (-not (Test-Path -LiteralPath $ini)) {
        return
    }
    foreach ($line in [IO.File]::ReadAllLines($ini)) {
        if ($line -notmatch '^\s*(?:zend_)?extension\s*=\s*"?([^";\s]+)') {
            continue
        }
        $name = $Matches[1]
        if ($name -notmatch '(?i)\.dll$') {
            $name = "php_$name.dll"
        }
        $path = $name
        if (-not [IO.Path]::IsPathRooted($name)) {
            $path = Join-Path $PhpDir "ext\$name"
        }
        if (Test-Path -LiteralPath $path) {
            $path
        }
    }
}

# httpd-xampp.conf の LoadFile で、Apache が先に読み込んでおく DLL の名前
function Get-PreloadedDll([string]$Root) {
    $conf = Join-Path $Root 'apache\conf\extra\httpd-xampp.conf'
    if (-not (Test-Path -LiteralPath $conf)) {
        return
    }
    foreach ($line in [IO.File]::ReadAllLines($conf)) {
        if ($line -match '^\s*LoadFile\s+"?([^"]+?)"?\s*$') {
            [IO.Path]::GetFileName($Matches[1].Trim()).ToLowerInvariant()
        }
    }
}

# Apache（httpd.exe）から PHP と有効な拡張を読み込むときに見つからない DLL を調べる。
# Apache は apache\bin とシステムのフォルダから DLL を探すので、php フォルダにしかない DLL は見つからない。
function Find-ApacheMissingDependency([string]$Root) {
    $phpDir = Join-Path $Root 'php'
    $apacheBin = Join-Path $Root 'apache\bin'
    $system = Join-Path $env:SystemRoot 'System32'
    if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) {
        $system = Join-Path $env:SystemRoot 'Sysnative'
    }
    $preloaded = @(Get-PreloadedDll $Root)

    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    foreach ($path in @((Join-Path $phpDir 'php8apache2_4.dll'), (Join-Path $phpDir 'php8ts.dll')) + @(Get-EnabledExtensionFile $phpDir)) {
        if (Test-Path -LiteralPath $path) {
            $queue.Enqueue($path)
        }
    }
    $seen = @{}
    $add = @()
    $unresolved = @()
    while ($queue.Count -gt 0) {
        $module = $queue.Dequeue()
        try {
            $imports = @(Get-PeImport $module)
        } catch {
            $unresolved += "$(Split-Path -Leaf $module)（依存関係を読み取れません）"
            continue
        }
        foreach ($name in $imports) {
            $key = $name.ToLowerInvariant()
            if ($seen.ContainsKey($key)) {
                continue
            }
            $seen[$key] = $true
            if ($key -like 'api-ms-win-*' -or $key -like 'ext-ms-*' -or $preloaded -contains $key -or
                (Test-Path -LiteralPath (Join-Path $apacheBin $name)) -or (Test-Path -LiteralPath (Join-Path $system $name))) {
                continue
            }
            $candidate = Join-Path $phpDir $name
            if (Test-Path -LiteralPath $candidate) {
                $add += $name
                $queue.Enqueue($candidate)
            } else {
                $unresolved += "$name（$(Split-Path -Leaf $module) が使用）"
            }
        }
    }
    return [pscustomobject]@{ Add = $add; Unresolved = $unresolved }
}

# apache\bin にある DLL のうち、いまの php フォルダの同名の DLL と中身が同じもの（XAMPP が PHP からコピーしたもの）
function Get-PhpCopyInApacheBin([string]$Root) {
    $apacheBin = Join-Path $Root 'apache\bin'
    if (-not (Test-Path -LiteralPath $apacheBin)) {
        return
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $apacheBin -Filter '*.dll' -File)) {
        $source = Join-Path $Root "php\$($file.Name)"
        if ((Test-Path -LiteralPath $source) -and (Test-SameFile $file.FullName $source)) {
            $file.Name
        }
    }
}

# apache\bin の PHP 用 DLL を新しい PHP のものにし、足りない依存 DLL を追加する。
# $Backup を渡すと、上書きする DLL と追加した DLL の一覧をバックアップの中に残す。
function Sync-ApacheBin([string]$Root, [string[]]$Copies, [string]$Backup) {
    $phpDir = Join-Path $Root 'php'
    $apacheBin = Join-Path $Root 'apache\bin'
    $updated = @()
    $added = @()
    if (-not (Test-Path -LiteralPath $apacheBin)) {
        return [pscustomobject]@{ Updated = $updated; Added = $added; Unresolved = @() }
    }
    $saved = $null
    if ($Backup) {
        $saved = Join-Path $Backup $ApacheBackupName
        New-Item -ItemType Directory -Force -Path $saved | Out-Null
    }

    foreach ($name in $Copies) {
        $source = Join-Path $phpDir $name
        $target = Join-Path $apacheBin $name
        if (-not (Test-Path -LiteralPath $source) -or (Test-SameFile $source $target)) {
            continue
        }
        if ($saved) {
            Copy-Item -LiteralPath $target -Destination (Join-Path $saved $name) -Force
        }
        Copy-Item -LiteralPath $source -Destination $target -Force
        $updated += $name
    }

    $missing = Find-ApacheMissingDependency $Root
    foreach ($name in $missing.Add) {
        if ($saved) {
            Add-Content -LiteralPath (Join-Path $saved 'added.txt') -Value $name -Encoding Ascii
        }
        Copy-Item -LiteralPath (Join-Path $phpDir $name) -Destination (Join-Path $apacheBin $name) -Force
        $added += $name
    }
    return [pscustomobject]@{ Updated = $updated; Added = $added; Unresolved = $missing.Unresolved }
}

# Sync-ApacheBin で変えた apache\bin を、バックアップの中の記録から元に戻す
function Restore-ApacheBin([string]$Root, [string]$Backup) {
    $saved = Join-Path $Backup $ApacheBackupName
    if (-not (Test-Path -LiteralPath $saved)) {
        return
    }
    $apacheBin = Join-Path $Root 'apache\bin'
    $added = Join-Path $saved 'added.txt'
    if (Test-Path -LiteralPath $added) {
        foreach ($name in [IO.File]::ReadAllLines($added)) {
            if ($name) {
                Remove-Item -LiteralPath (Join-Path $apacheBin $name) -Force -ErrorAction SilentlyContinue
            }
        }
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $saved -Filter '*.dll' -File)) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $apacheBin $file.Name) -Force
    }
    Remove-Item -LiteralPath $saved -Recurse -Force
}

function Write-ApacheBinChange($Sync) {
    foreach ($name in $Sync.Updated) {
        Write-Info "更新: apache\bin\$name"
    }
    foreach ($name in $Sync.Added) {
        Write-Info "追加: apache\bin\$name"
    }
    if (@($Sync.Updated).Count -eq 0 -and @($Sync.Added).Count -eq 0) {
        Write-Info '変更はありません。'
    }
}

# php.exe -m を実行し、警告やエラーの行を返す
function Get-PhpStartupMessage([string]$Root) {
    $phpDir = Join-Path $Root 'php'
    $ini = Join-Path $phpDir 'php.ini'
    $arguments = @('-m')
    if (Test-Path -LiteralPath $ini) {
        $arguments = @('-c', $ini, '-m')
    }
    # php.ini の \xampp\... という書き方は実行中のドライブが基準になるので、XAMPP のフォルダで実行する
    Push-Location -LiteralPath $Root
    try {
        $result = Invoke-Native (Join-Path $phpDir 'php.exe') $arguments
    } finally {
        Pop-Location
    }
    $messages = @($result.Output -split "`n" | Where-Object { $_ -match '(?i)\b(warning|error|deprecated)\b' } | ForEach-Object { $_.Trim() })
    if ($result.ExitCode -ne 0) {
        $messages += "php.exe -m の終了コード: $($result.ExitCode)"
    }
    return $messages
}

function Test-ApacheConfig([string]$Root) {
    $httpd = Join-Path $Root 'apache\bin\httpd.exe'
    if (-not (Test-Path -LiteralPath $httpd)) {
        return $null
    }
    Push-Location -LiteralPath $Root
    try {
        $result = Invoke-Native $httpd @('-t')
    } finally {
        Pop-Location
    }
    return [pscustomobject]@{ Ok = ($result.Output -match 'Syntax OK'); Output = $result.Output.Trim() }
}

# php.ini に session.upload_progress.enabled = Off を入れる。変更したら $true を返す。
function Set-UploadProgressOff([string]$IniPath) {
    # 文字コードを崩さないよう、1 バイトを 1 文字として扱う Latin-1 で読み書きする
    $encoding = [Text.Encoding]::GetEncoding(28591)
    $text = [IO.File]::ReadAllText($IniPath, $encoding)
    $newline = "`n"
    if ($text.Contains("`r`n")) {
        $newline = "`r`n"
    }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.AddRange([string[]]($text -split "`r?`n"))

    $active = -1
    $commented = -1
    $value = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*session\.upload_progress\.enabled\s*=\s*(.*?)\s*$') {
            $active = $i
            $value = $Matches[1]
        } elseif ($lines[$i] -match '^\s*;\s*session\.upload_progress\.enabled\s*=') {
            $commented = $i
        }
    }
    if ($active -ge 0 -and $value -match '^"?(?i:off|0|false|no|none)?"?$') {
        return $false
    }

    $note = '; Added by update-xampp-php.ps1: mitigation for CVE-2026-109619 (PHP default is On)'
    $setting = 'session.upload_progress.enabled = Off'
    if ($active -ge 0) {
        $lines[$active] = $setting
        $lines.Insert($active, $note)
    } elseif ($commented -ge 0) {
        $lines.InsertRange($commented + 1, [string[]]@($note, $setting))
    } else {
        $at = $lines.Count
        if ($at -gt 0 -and $lines[$at - 1] -eq '') {
            $at--
        }
        $lines.InsertRange($at, [string[]]@('[Session]', $note, $setting))
    }
    [IO.File]::WriteAllText($IniPath, ($lines -join $newline), $encoding)
    return $true
}

# PHP がすでに新しい場合は、apache\bin に足りない依存 DLL だけを補う
function Invoke-DependencyRepair([string]$Root, [string]$Current) {
    Write-Host ''
    Write-Host "PHP はすでに $Current です。" -ForegroundColor Green
    $missing = Find-ApacheMissingDependency $Root
    foreach ($item in $missing.Unresolved) {
        Write-Note "見つからない DLL: $item"
    }
    if (@($missing.Add).Count -eq 0) {
        Write-Host '更新の必要はありません。'
        return $null
    }
    Write-Note ('Apache から読み込めない DLL があります: {0}' -f ($missing.Add -join ', '))
    if (-not $Staging) {
        Write-Step 'Apache / PHP が止まっていることを確認'
        Assert-NotRunning $Root
        Confirm-Continue 'php フォルダから apache\bin に、足りない DLL をコピーします。よろしいですか？'
    }
    Write-Step 'Apache から読み込む DLL をそろえる（apache\bin）'
    $sync = Sync-ApacheBin $Root @() $null
    Write-ApacheBinChange $sync
    Write-Host ''
    Write-Host '完了しました。XAMPP コントロールパネルで Apache を Start してください。' -ForegroundColor Green
    return [pscustomobject]@{
        XamppDir      = $Root
        FromVersion   = $Current
        ToVersion     = $Current
        PhpZip        = $null
        Backup        = $null
        ApacheUpdated = @()
        ApacheAdded   = $sync.Added
        Hardened      = @()
        Problems      = @($sync.Unresolved | ForEach-Object { "見つからない DLL: $_" })
    }
}

function Invoke-Update {
    $root = Resolve-XamppDir
    $phpDir = Join-Path $root 'php'
    Write-Step "XAMPP: $root"

    $current = Get-PhpVersion $phpDir
    if (-not $current) {
        throw "スレッドセーフ版の PHP（php\php8ts.dll）が見つかりません。XAMPP のフォルダか確認してください: $root"
    }
    Write-Info "いまの PHP      : $current"
    Write-Info "入れ替え後の PHP: $($Release.Version)（$($Release.Fixes) を修正）"

    $currentVersion = ConvertTo-Version $current
    $targetVersion = [version]$Release.Version
    if (-not $currentVersion -or $currentVersion.Major -ne $targetVersion.Major -or $currentVersion.Minor -ne $targetVersion.Minor) {
        if (-not $Force) {
            throw ('この更新は PHP {0}.{1} 系の XAMPP（XAMPP 8.2.x）用です。いまの PHP は {2} です。XAMPP 8.0 / 8.1 系は、XAMPP 8.2.12 に移行してから適用してください。' -f $targetVersion.Major, $targetVersion.Minor, $current)
        }
        Write-Note 'バージョン系列が違いますが、-Force が指定されているため続行します。'
    } elseif ($currentVersion -ge $targetVersion -and -not $Force) {
        return Invoke-DependencyRepair $root $current
    }

    $apacheBefore = $null
    $baseline = @()
    if (-not $Staging) {
        Write-Step 'Apache / PHP が止まっていることを確認'
        Assert-NotRunning $root
        Confirm-Continue "$phpDir を PHP $($Release.Version) に入れ替えます。よろしいですか？"
    }

    Write-Step '公式の PHP を用意'
    $zip = Get-ReleaseZip
    Write-Info "SHA-256 一致: $zip"

    $backup = $null
    $sync = $null
    $extract = Join-Path ([IO.Path]::GetTempPath()) ('xampp-php-' + [guid]::NewGuid().ToString('N'))
    try {
        Expand-Archive -LiteralPath $zip -DestinationPath $extract
        $newVersion = Get-PhpVersion $extract
        if ($newVersion -ne $Release.Version -or -not (Test-Path -LiteralPath (Join-Path $extract 'php8apache2_4.dll'))) {
            throw "zip の中身が想定と違います（php8ts.dll のバージョン: $newVersion）。"
        }

        if (-not $Staging) {
            # 更新前から出ている警告を、更新で増えたものと区別するために控えておく
            $baseline = @(Get-PhpStartupMessage $root)
            $apacheBefore = Test-ApacheConfig $root

            Write-Step 'php フォルダをバックアップ'
            $backup = Join-Path $root ('php_backup_{0}_{1}' -f $current, (Get-Date -Format 'yyyyMMdd-HHmmss'))
            Invoke-Robocopy $phpDir $backup @('/E', '/COPY:DAT', '/DCOPY:T')
            Write-Info $backup
        }

        # 上書きする前に、XAMPP が apache\bin にコピーしている PHP の DLL を調べておく
        $copies = @(Get-PhpCopyInApacheBin $root)
        try {
            Write-Step "PHP $($Release.Version) を上書き"
            Invoke-Robocopy $extract $phpDir @('/E', '/IS', '/IT', '/COPY:DAT')
            Write-Info "php8ts.dll: $(Get-PhpVersion $phpDir)"

            Write-Step 'Apache から読み込む DLL をそろえる（apache\bin）'
            $sync = Sync-ApacheBin $root $copies $backup
            Write-ApacheBinChange $sync
        } catch {
            if ($backup) {
                Write-Note '途中で失敗したため、バックアップから元に戻します。'
                Restore-ApacheBin $root $backup
                Invoke-Robocopy $backup $phpDir @('/MIR', '/COPY:DAT')
            }
            throw
        }
    } finally {
        Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue
    }

    $hardened = @()
    if (-not $NoHarden) {
        Write-Step 'php.ini の追加対策（session.upload_progress.enabled = Off）'
        foreach ($ini in @((Join-Path $phpDir 'php.ini'), (Join-Path $root 'apache\bin\php.ini'))) {
            if (-not (Test-Path -LiteralPath $ini)) {
                continue
            }
            if (Set-UploadProgressOff $ini) {
                Write-Info "変更しました: $ini"
                $hardened += $ini
            } else {
                Write-Info "設定済みです: $ini"
            }
        }
    }

    $problems = @($sync.Unresolved | ForEach-Object { "Apache から読み込めない DLL: $_" })
    if (-not $Staging) {
        Write-Step '起動の確認'
        $cli = Invoke-Native (Join-Path $phpDir 'php.exe') @('-n', '-r', 'echo PHP_VERSION;')
        if ($cli.ExitCode -eq 0 -and $cli.Output.Trim() -eq $Release.Version) {
            Write-Info "php.exe: $($cli.Output.Trim())"
        } else {
            $problems += "php.exe が正しく起動しません: $($cli.Output.Trim())"
            if ($cli.Output -match '(?i)vcruntime') {
                $problems += "Microsoft Visual C++ 再頒布可能パッケージ（x64）の最新版をインストールしてください: $VcRedistUrl"
            }
        }

        $added = @(Get-PhpStartupMessage $root | Where-Object { $baseline -notcontains $_ })
        if ($added.Count -eq 0) {
            Write-Info 'php.exe -m: 新しい警告はありません'
        } else {
            $problems += @($added | ForEach-Object { "php.exe -m: $_" })
        }

        $apacheAfter = Test-ApacheConfig $root
        if ($apacheAfter) {
            if ($apacheAfter.Ok) {
                Write-Info 'httpd.exe -t: Syntax OK'
            } elseif ($apacheBefore -and -not $apacheBefore.Ok) {
                Write-Note "httpd.exe -t は更新前からエラーでした: $($apacheAfter.Output)"
            } else {
                $problems += "httpd.exe -t: $($apacheAfter.Output)"
            }
        }
    }

    Write-Host ''
    if ($problems.Count -gt 0) {
        Write-Host 'PHP の入れ替えは終わりましたが、確認で問題が見つかりました:' -ForegroundColor Yellow
        foreach ($problem in $problems) {
            Write-Host "  - $problem" -ForegroundColor Yellow
        }
        if (-not $Staging) {
            Write-Host '元に戻すには、update-xampp-php.bat -Restore を実行してください。'
        }
    } else {
        Write-Host "完了しました: PHP $current -> $($Release.Version)" -ForegroundColor Green
    }
    if (-not $Staging) {
        Write-Host 'XAMPP コントロールパネルで Apache を Start してください。'
        Write-Host "バックアップ: $backup（動作に問題がなければ削除してかまいません）"
    }

    return [pscustomobject]@{
        XamppDir      = $root
        FromVersion   = $current
        ToVersion     = $Release.Version
        PhpZip        = $zip
        Backup        = $backup
        ApacheUpdated = $sync.Updated
        ApacheAdded   = $sync.Added
        Hardened      = $hardened
        Problems      = $problems
    }
}

function Invoke-Restore {
    $root = Resolve-XamppDir
    $phpDir = Join-Path $root 'php'
    $backups = @(
        Get-ChildItem -LiteralPath $root -Directory -Filter 'php_backup_*' |
            Where-Object { $_.Name -match '_\d{8}-\d{6}$' } |
            Sort-Object { $_.Name.Substring($_.Name.Length - 15) } -Descending
    )
    if ($backups.Count -eq 0) {
        throw "バックアップ（php_backup_*）が見つかりません: $root"
    }
    $backup = $backups[0]
    $backupVersion = Get-PhpVersion $backup.FullName
    if (-not $backupVersion) {
        throw "バックアップに php8ts.dll がありません: $($backup.FullName)"
    }

    Write-Step "バックアップから元に戻す: $($backup.FullName)"
    Assert-NotRunning $root
    Confirm-Continue "$phpDir を $($backup.Name)（PHP $backupVersion）に戻します。よろしいですか？"

    $aside = 'php_replaced_' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    if (Test-Path -LiteralPath $phpDir) {
        Rename-Item -LiteralPath $phpDir -NewName $aside
    }
    try {
        Rename-Item -LiteralPath $backup.FullName -NewName 'php'
    } catch {
        Rename-Item -LiteralPath (Join-Path $root $aside) -NewName 'php'
        throw
    }
    # バックアップだったフォルダ（いまの php フォルダ）に残した記録から、apache\bin も戻す
    Restore-ApacheBin $root $phpDir

    Write-Host ''
    Write-Host "元に戻しました: PHP $(Get-PhpVersion $phpDir)" -ForegroundColor Green
    Write-Host "入れ替え後の php フォルダは $aside として残しています。"
    Write-Host 'XAMPP コントロールパネルで Apache を Start してください。'
}

try {
    if ($Restore) {
        Invoke-Restore
        exit 0
    }
    $result = Invoke-Update
    if ($PassThru -and $result) {
        $result
    }
    if ($result -and $result.Problems.Count -gt 0) {
        exit 1
    }
    exit 0
} catch {
    Write-Host ''
    Write-Host "[エラー] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
