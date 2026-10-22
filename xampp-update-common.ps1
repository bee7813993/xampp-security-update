<#
    update-xampp-php.ps1 と update-xampp-apache.ps1 が共通で使う関数です。
    単独では実行せず、各スクリプトからドットソース（. .\xampp-update-common.ps1）で読み込みます。
#>

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

# 64 ビットの System32（32 ビットの PowerShell から呼ばれた場合は Sysnative）
function Get-SystemDir {
    if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) {
        return Join-Path $env:SystemRoot 'Sysnative'
    }
    return Join-Path $env:SystemRoot 'System32'
}

# XAMPP のフォルダ。省略すると C:\xampp、なければ各ドライブ直下の \xampp を探す。
function Resolve-XamppDir([string]$Path) {
    if ($Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            throw "XAMPP のフォルダが見つかりません: $Path"
        }
        return (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\')
    }
    if (Test-Path -LiteralPath 'C:\xampp\xampp-control.exe') {
        return 'C:\xampp'
    }
    $found = @(
        [IO.DriveInfo]::GetDrives() |
            Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } |
            ForEach-Object { Join-Path $_.RootDirectory.FullName 'xampp' } |
            Where-Object { Test-Path -LiteralPath (Join-Path $_ 'xampp-control.exe') }
    )
    if ($found.Count -eq 1) {
        return $found[0]
    }
    if ($found.Count -eq 0) {
        throw 'XAMPP が見つかりません。-XamppDir で XAMPP のフォルダを指定してください。'
    }
    throw ('XAMPP が複数見つかりました（{0}）。-XamppDir でどれか 1 つを指定してください。' -f ($found -join ', '))
}

# 既定では、この XAMPP の Apache / PHP として動いているプロセス
$ApachePhpProcessNames = 'httpd', 'php', 'php-cgi', 'php-win', 'phpdbg', 'ApacheMonitor', 'rotatelogs'

# この XAMPP のフォルダにある $Names のプロセス
function Get-BlockingProcess([string]$Root, [string[]]$Names = $ApachePhpProcessNames) {
    $prefix = $Root + '\'
    foreach ($process in @(Get-Process -Name $Names -ErrorAction SilentlyContinue)) {
        $path = $null
        try { $path = $process.Path } catch { }
        if ($path) {
            if ($path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                $process
            }
        } elseif ($process.ProcessName -in 'httpd', 'mysqld', 'mariadbd') {
            # 権限の都合で場所を読めないサーバー（サービスとして動いているものなど）も止めてもらう
            $process
        }
    }
}

# この XAMPP の $Names のプログラムを使っている、止まっていないサービス
function Get-BlockingService([string]$Root, [string[]]$Names = $ApachePhpProcessNames) {
    $prefix = $Root + '\'
    $pattern = '(?i)\\(' + (($Names | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')\.exe'
    Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue | Where-Object {
        $_.State -ne 'Stopped' -and $_.PathName -and
        $_.PathName.IndexOf($prefix, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        $_.PathName -match $pattern
    }
}

function Assert-NotRunning([string]$Root, [bool]$Force, [string[]]$Names = $ApachePhpProcessNames,
    [string]$Hint = 'XAMPP コントロールパネルで Apache を Stop してから（サービスとして登録している場合はサービスも停止してから）、もう一度実行してください。') {
    $services = @(Get-BlockingService $Root $Names)
    $processes = @(Get-BlockingProcess $Root $Names)
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
        throw $Hint
    }
    Write-Note '-Force が指定されているため続行します。'
}

# zip を展開する。Windows 10 以降の tar.exe のほうが Expand-Archive よりずっと速いので、あれば使う。
function Expand-ZipFile([string]$Zip, [string]$Destination) {
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $tar = Join-Path (Get-SystemDir) 'tar.exe'
    if (Test-Path -LiteralPath $tar) {
        $result = Invoke-Native $tar @('-xf', $Zip, '-C', $Destination)
        if ($result.ExitCode -ne 0) {
            throw "展開に失敗しました: $($result.Output.Trim())"
        }
    } else {
        Expand-Archive -LiteralPath $Zip -DestinationPath $Destination
    }
}

# $Root にある $Prefix<バージョン>_<日時> のバックアップを新しい順に返す
function Get-BackupFolder([string]$Root, [string]$Prefix) {
    @(
        Get-ChildItem -LiteralPath $Root -Directory -Filter "$Prefix*" |
            Where-Object { $_.Name -match '_\d{8}-\d{6}$' } |
            Sort-Object { $_.Name.Substring($_.Name.Length - 15) } -Descending
    )
}

function Confirm-Continue([string]$Question, [bool]$Yes) {
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

function Test-SameFile([string]$Left, [string]$Right) {
    return ((Get-Item -LiteralPath $Left).Length -eq (Get-Item -LiteralPath $Right).Length) -and
        ((Get-FileHash -LiteralPath $Left).Hash -eq (Get-FileHash -LiteralPath $Right).Hash)
}

# 公開されている SHA-256 と一致するファイルを用意する。手元にあって一致すればそれを使い、
# なければ $Urls を順に試す。PowerShell の既定の User-Agent を受け付けない配布元があるので、curl.exe を優先する。
function Save-VerifiedFile([string[]]$Urls, [string]$Destination, [string]$Sha256) {
    if ((Test-Path -LiteralPath $Destination) -and (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash -eq $Sha256) {
        return
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    $part = "$Destination.part"
    $curl = Join-Path (Get-SystemDir) 'curl.exe'
    foreach ($url in $Urls) {
        Write-Info "ダウンロード中: $url"
        try {
            if (Test-Path -LiteralPath $curl) {
                $result = Invoke-Native $curl @('-fsSL', '--retry', '2', '-o', $part, $url)
                if ($result.ExitCode -ne 0) {
                    throw $result.Output.Trim()
                }
            } else {
                [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest -Uri $url -OutFile $part -UseBasicParsing
            }
            if ((Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash -eq $Sha256) {
                Move-Item -LiteralPath $part -Destination $Destination -Force
                return
            }
            Write-Note 'SHA-256 が公開値と一致しないため、このファイルは使いません。'
        } catch {
            Write-Note "取得できませんでした: $($_.Exception.Message)"
        }
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
    }
    throw "$(Split-Path -Leaf $Destination) を取得できませんでした。"
}

function Test-ApacheConfig([string]$Root) {
    $httpd = Join-Path $Root 'apache\bin\httpd.exe'
    if (-not (Test-Path -LiteralPath $httpd)) {
        return $null
    }
    # 設定ファイルの \xampp\... や /xampp/... は実行中のドライブが基準になるので、XAMPP のフォルダで実行する
    Push-Location -LiteralPath $Root
    try {
        $result = Invoke-Native $httpd @('-t')
    } finally {
        Pop-Location
    }
    return [pscustomobject]@{ Ok = ($result.Output -match 'Syntax OK'); Output = $result.Output.Trim() }
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
    $system = Get-SystemDir
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
