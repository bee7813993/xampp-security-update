<#
.SYNOPSIS
    XAMPP for Windows の MariaDB 10.4（サポート終了）を MariaDB 11.4 LTS に入れ替え、データを移行します。

.DESCRIPTION
    MariaDB 公式の Windows 版（zip）を用意して SHA-256 を照合し、XAMPP の mysql フォルダのプログラム
    （bin、lib、share）を入れ替えて、データ（mysql\data）を新しい版の形式に移行します。
    設定（mysql\bin\my.ini）はそのまま使います。

      1. XAMPP のフォルダと、いまの MariaDB のバージョンを確認する
      2. MariaDB（MySQL）が動いていないことを確認する
      3. MariaDB の zip を用意して SHA-256 を照合する
      4. mysql フォルダを丸ごと mysql_backup_<元のバージョン>_<日時> にバックアップする
      5. 元の版の MariaDB を一時的に起動して、正常に終了させる
         （XAMPP の MySQL の停止はプロセスの強制終了なので、そのままでは新しい版がデータを開けない）
      6. bin、lib、share を新しい版に入れ替える（my.ini などの設定ファイルは残す）
      7. 新しい版を一時的に起動し、mariadb-upgrade でシステムテーブルなどを移行してから、正常に終了させる
      8. 途中で失敗したら、バックアップから元に戻す

    一時的に起動する MariaDB は、127.0.0.1 の空いているポートだけで待ち受け、権限の確認を省いた状態
    （--skip-grant-tables）で動かします。root にパスワードを付けていても移行できます。

.PARAMETER XamppDir
    XAMPP のフォルダ。省略すると C:\xampp を使い、なければ各ドライブ直下の \xampp を探します。

.PARAMETER MariaDbZip
    手元にある MariaDB の zip。省略すると、このスクリプトと同じフォルダにある zip を使い、なければダウンロードします。

.PARAMETER DownloadDir
    ダウンロードした zip の置き場所。既定は %TEMP%\xampp-security-update です。

.PARAMETER Restore
    いちばん新しいバックアップに戻します。更新したあとに追加・変更したデータは失われます。

.PARAMETER Yes
    確認の問い合わせを省略します。

.PARAMETER Force
    MariaDB の版が想定と違う場合や、動作中のプロセスがある場合でも続行します。

.PARAMETER Staging
    XAMPP 一式の zip を組み立てるときに使います（build-package.ps1 から呼ばれます）。
    バックアップと動作中のプロセスの確認を行わず、移行したデータを mysql\backup にも写します。

.PARAMETER PassThru
    結果をオブジェクトで返します。

.EXAMPLE
    .\update-xampp-mariadb.ps1

.EXAMPLE
    .\update-xampp-mariadb.ps1 -Restore
#>
[CmdletBinding()]
param(
    [string]$XamppDir,
    [string]$MariaDbZip,
    [string]$DownloadDir = (Join-Path ([IO.Path]::GetTempPath()) 'xampp-security-update'),
    [switch]$Restore,
    [switch]$Yes,
    [switch]$Force,
    [switch]$Staging,
    [switch]$PassThru
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'xampp-update-common.ps1')

# 入れ替え先の MariaDB。SHA-256 は MariaDB の公式サイト（downloads.mariadb.org）で公開されている値。
$Release = @{
    Version = '11.4.13'
    File    = 'mariadb-11.4.13-winx64.zip'
    Folder  = 'mariadb-11.4.13-winx64'
    Sha256  = 'D62986D433EEEBFDE218560B276103831604A61E929E87F1A17F5AEBD80257E2'
    Urls    = @(
        'https://archive.mariadb.org/mariadb-11.4.13/winx64-packages/mariadb-11.4.13-winx64.zip'
        'https://downloads.mariadb.org/rest-api/mariadb/11.4.13/mariadb-11.4.13-winx64.zip'
    )
    Support = '2029 年 5 月'
}
$VcRedistUrl = 'https://aka.ms/vc14/vc_redist.x64.exe'
# 止まっている必要があるプログラム（サーバーと、mysql フォルダのクライアント）
$MariaDbProcessNames = 'mysqld', 'mariadbd', 'mysql', 'mariadb', 'mysqladmin', 'mariadb-admin', 'mysqldump', 'mariadb-dump'
$StopHint = 'XAMPP コントロールパネルで MySQL を Stop してから（サービスとして登録している場合はサービスも停止してから）、もう一度実行してください。'

function Get-MariaDbVersion([string]$MysqlDir) {
    $exe = Join-Path $MysqlDir 'bin\mysqld.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        return $null
    }
    $version = ((Get-Item -LiteralPath $exe).VersionInfo.FileVersion -split ' ')[0].Trim()
    return ($version -split '\.')[0..2] -join '.'
}

function Get-FreePort {
    $listener = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try {
        return $listener.LocalEndpoint.Port
    } finally {
        $listener.Stop()
    }
}

function Get-FolderSize([string]$Path) {
    $sum = (Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    if (-not $sum) {
        return 0
    }
    return [long]$sum
}

# 一時的に起動した MariaDB の標準出力と標準エラー出力の置き場所（最後に消す）
$ConsoleDir = Join-Path ([IO.Path]::GetTempPath()) ('xampp-mariadb-console-' + [guid]::NewGuid().ToString('N'))

# 一時的に MariaDB を起動する。my.ini を読みつつ、パスとポートはコマンドラインで上書きする
# （設定ファイルの \xampp\... はドライブ名がなく、組み立て中のフォルダでは別の場所を指すため）。
# Windows 版の MariaDB 10.4 は、非表示のコンソールで起動すると、起動の途中でコンソールを切り離すときに
# まれに落ちるので、標準出力と標準エラー出力はファイルに向ける。
function Start-TemporaryServer([string]$MysqlDir, [int]$Port, [string[]]$Extra) {
    New-Item -ItemType Directory -Force -Path $ConsoleDir | Out-Null
    $name = 'mysqld-{0}-{1}' -f $Port, [guid]::NewGuid().ToString('N').Substring(0, 8)
    $tmp = [IO.Path]::GetTempPath().TrimEnd('\')
    $arguments = @(
        "--defaults-file=`"$MysqlDir\bin\my.ini`""
        "--basedir=`"$MysqlDir`""
        "--datadir=`"$MysqlDir\data`""
        "--innodb-data-home-dir=`"$MysqlDir\data`""
        "--innodb-log-group-home-dir=`"$MysqlDir\data`""
        "--plugin-dir=`"$MysqlDir\lib\plugin`""
        "--tmpdir=`"$tmp`""
        "--log-error=`"$MysqlDir\data\mysql_error.log`""
        "--port=$Port"
        '--bind-address=127.0.0.1'
        '--skip-grant-tables'
        '--skip-name-resolve'
    ) + $Extra
    return Start-Process -FilePath (Join-Path $MysqlDir 'bin\mysqld.exe') -ArgumentList $arguments -WorkingDirectory $MysqlDir -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $ConsoleDir "$name.out") -RedirectStandardError (Join-Path $ConsoleDir "$name.err")
}

function Invoke-MariaDbAdmin([string]$MysqlDir, [int]$Port, [string[]]$Command) {
    $arguments = @('--no-defaults', '--host=127.0.0.1', "--port=$Port", '--user=root', '--connect-timeout=5') + $Command
    return Invoke-Native (Join-Path $MysqlDir 'bin\mysqladmin.exe') $arguments
}

function Test-PortListening([int]$Port) {
    $listeners = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
    return [bool]($listeners | Where-Object { $_.Port -eq $Port })
}

# 起動が終わるのを待ってから接続を確かめる。Windows 版の MariaDB 10.4 は、起動の途中でエラーログを開き直すため、
# その間にログを読むと落ちたり止まったりすることがある。また初期化の途中で接続されても落ちることがあるので、
# ログには触れず、ポートの待ち受けが始まってから 3 秒たってから接続する。
function Wait-ServerReady([string]$MysqlDir, [int]$Port, $Process, [int]$TimeoutSeconds) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $listening = $null
    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if ($Process.HasExited) {
            return $false
        }
        if (-not $listening -and (Test-PortListening $Port)) {
            $listening = $watch.Elapsed.TotalSeconds
        }
        if ($listening -and $watch.Elapsed.TotalSeconds - $listening -ge 3) {
            $result = Invoke-MariaDbAdmin $MysqlDir $Port @('ping')
            if ($result.ExitCode -eq 0 -and $result.Output -match 'alive') {
                return $true
            }
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Stop-ServerProcess($Process) {
    if (-not $Process.HasExited) {
        Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
        $Process.WaitForExit(30000) | Out-Null
    }
}

# mysqladmin shutdown で正常に終了させる。終わらなければ強制終了して $false を返す。
function Stop-TemporaryServer([string]$MysqlDir, [int]$Port, $Process, [int]$TimeoutSeconds) {
    if ($Process.HasExited) {
        return $false
    }
    $result = Invoke-MariaDbAdmin $MysqlDir $Port @('shutdown')
    if (-not $Process.WaitForExit($TimeoutSeconds * 1000)) {
        Stop-ServerProcess $Process
        return $false
    }
    return $result.ExitCode -eq 0
}

function Get-LogLength([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        return (Get-Item -LiteralPath $Path).Length
    }
    return 0
}

# エラーログの $Offset バイト目以降（今回の起動で書かれた分）。MariaDB が書き込み中でも読めるように開く。
function Get-LogSince([string]$Path, [long]$Offset) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return ''
    }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        if ($Offset -ge $stream.Length) {
            return ''
        }
        $stream.Position = $Offset
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)
        return $reader.ReadToEnd()
    } finally {
        $stream.Dispose()
    }
}

# 一時的に起動して正常に終了させる。$Work を渡すと、起動している間に実行する。今回のログを返す。
function Invoke-TemporaryServer([string]$MysqlDir, [string]$Label, [string[]]$Extra, [scriptblock]$Work) {
    $port = Get-FreePort
    $log = Join-Path $MysqlDir 'data\mysql_error.log'
    $offset = Get-LogLength $log
    $process = Start-TemporaryServer $MysqlDir $port $Extra
    try {
        if (-not (Wait-ServerReady $MysqlDir $port $process 300)) {
            if (-not $process.HasExited) {
                Stop-ServerProcess $process
                throw "MariaDB $Label を起動できませんでした。`n$((Get-LogSince $log $offset).Trim())"
            }
            # 起動の途中で落ちた場合は、もう一度だけ起動する（次の起動でクラッシュから回復する）
            Write-Note "MariaDB $Label が起動の途中で終了しました（終了コード $($process.ExitCode)）。もう一度起動します。"
            $port = Get-FreePort
            $process = Start-TemporaryServer $MysqlDir $port $Extra
            if (-not (Wait-ServerReady $MysqlDir $port $process 300)) {
                Stop-ServerProcess $process
                throw "MariaDB $Label を起動できませんでした。`n$((Get-LogSince $log $offset).Trim())"
            }
        }
        if ($Work) {
            & $Work $port
        }
        if (-not (Stop-TemporaryServer $MysqlDir $port $process 600)) {
            throw "MariaDB $Label を正常に終了できませんでした。`n$((Get-LogSince $log $offset).Trim())"
        }
    } finally {
        Stop-ServerProcess $process
    }
    return Get-LogSince $log $offset
}

# bin、lib、share を新しい版に入れ替える。bin の設定ファイル（my.ini など）は残す。
function Install-MariaDbFile([string]$Source, [string]$MysqlDir) {
    $bin = Join-Path $MysqlDir 'bin'
    Get-ChildItem -LiteralPath $bin -File | Where-Object { $_.Extension -notin '.ini', '.cnf' } | Remove-Item -Force
    Get-ChildItem -LiteralPath $bin -Directory | Remove-Item -Recurse -Force
    Invoke-Robocopy (Join-Path $Source 'bin') $bin @('/E', '/COPY:DAT', '/XF', '*.ini', '*.cnf')
    foreach ($dir in 'lib', 'share') {
        $target = Join-Path $MysqlDir $dir
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Recurse -Force
        }
        Invoke-Robocopy (Join-Path $Source $dir) $target @('/E', '/COPY:DAT')
    }
    foreach ($name in 'COPYING', 'CREDITS', 'README.md', 'THIRDPARTY') {
        $file = Join-Path $Source $name
        if (Test-Path -LiteralPath $file) {
            Copy-Item -LiteralPath $file -Destination (Join-Path $MysqlDir $name) -Force
        }
    }
}

# my.ini の [mysqld] の key_buffer を正式名の key_buffer_size にする（新しい版は省略形に注意を出す）。変えたら $true。
function Update-MyIni([string]$IniPath) {
    $encoding = [Text.Encoding]::GetEncoding(28591)
    $text = [IO.File]::ReadAllText($IniPath, $encoding)
    $newline = "`n"
    if ($text.Contains("`r`n")) {
        $newline = "`r`n"
    }
    $lines = $text -split "`r?`n"
    $section = ''
    $changed = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\[([^\]]+)\]') {
            $section = $Matches[1].Trim().ToLowerInvariant()
        } elseif ($section -in 'mysqld', 'server', 'mariadb' -and $lines[$i] -match '^(\s*)key_buffer(\s*=.*)$') {
            $lines[$i] = $Matches[1] + 'key_buffer_size' + $Matches[2]
            $changed = $true
        }
    }
    if ($changed) {
        [IO.File]::WriteAllText($IniPath, ($lines -join $newline), $encoding)
    }
    return $changed
}

# フォルダの名前を変える。止めたばかりのプロセスがファイルを手放すまで少し待つことがあるので、何度か試す。
function Rename-FolderWithRetry([string]$Path, [string]$NewName) {
    for ($i = 1; ; $i++) {
        try {
            Rename-Item -LiteralPath $Path -NewName $NewName
            return
        } catch {
            if ($i -ge 10) {
                throw
            }
            Start-Sleep -Seconds 1
        }
    }
}

# mysql フォルダをバックアップと入れ替えて元に戻す。入れ替えた方は $Aside という名前で残す。
function Restore-MysqlFolder([string]$Root, [string]$Backup, [string]$Aside) {
    $mysqlDir = Join-Path $Root 'mysql'
    if (Test-Path -LiteralPath $mysqlDir) {
        Rename-FolderWithRetry $mysqlDir $Aside
    }
    try {
        Rename-Item -LiteralPath $Backup -NewName 'mysql'
    } catch {
        Rename-Item -LiteralPath (Join-Path $Root $Aside) -NewName 'mysql'
        throw
    }
}

function Invoke-Update {
    $root = Resolve-XamppDir $XamppDir
    $mysqlDir = Join-Path $root 'mysql'
    Write-Step "XAMPP: $root"

    $current = Get-MariaDbVersion $mysqlDir
    if (-not $current) {
        Write-Host ''
        Write-Host 'MariaDB（mysql フォルダ）が入っていないため、何もしません。' -ForegroundColor Green
        return $null
    }
    Write-Info "いまの MariaDB      : $current"
    Write-Info "入れ替え後の MariaDB: $($Release.Version)（長期サポート版、$($Release.Support) までサポート）"

    $currentVersion = ConvertTo-Version $current
    $targetVersion = [version]$Release.Version
    if (-not $currentVersion -or $currentVersion -lt [version]'10.4') {
        if (-not $Force) {
            throw "移行できるのは MariaDB 10.4 以降のデータです（いまの MariaDB は $current）。"
        }
        Write-Note '想定より古い版ですが、-Force が指定されているため続行します。'
    } elseif ($currentVersion -ge $targetVersion -and -not $Force) {
        Write-Host ''
        Write-Host "MariaDB はすでに $current です。更新の必要はありません。" -ForegroundColor Green
        return $null
    }

    if (-not $Staging) {
        Write-Step 'MariaDB が止まっていることを確認'
        Assert-NotRunning $root $Force $MariaDbProcessNames $StopHint

        $need = [long]((Get-FolderSize $mysqlDir) * 1.2) + 500MB
        $free = (Get-PSDrive -Name (Split-Path -Qualifier $root).TrimEnd(':')).Free
        if ($free -lt $need) {
            throw ('ディスクの空きが足りません（必要 {0:N0} MB、空き {1:N0} MB）。' -f ($need / 1MB), ($free / 1MB))
        }
        Write-Note '作業中に MariaDB を一時的に起動します。終わるまで XAMPP コントロールパネルで MySQL を操作しないでください。'
        Confirm-Continue "$mysqlDir を MariaDB $($Release.Version) に入れ替え、データを移行します。よろしいですか？" $Yes
    }

    Write-Step 'MariaDB を用意'
    $zip = Get-ReleaseFile $MariaDbZip $Release $DownloadDir "MariaDB を取得できませんでした。$($Release.File) を入手し、-MariaDbZip で指定してください。"
    Write-Info "SHA-256 一致: $zip"

    $backup = $null
    $iniChanged = $false
    $logs = ''
    $extract = Join-Path ([IO.Path]::GetTempPath()) ('xampp-mariadb-' + [guid]::NewGuid().ToString('N'))
    try {
        Expand-ZipFile $zip $extract
        $source = Join-Path $extract $Release.Folder
        $check = Invoke-Native (Join-Path $source 'bin\mysqld.exe') @('--no-defaults', '--version')
        if ($check.Output -notmatch ('Ver ' + [regex]::Escape($Release.Version) + '-MariaDB')) {
            if ($check.Output -match '(?i)vcruntime|msvcp|0xc0000135|side-by-side' -or $check.ExitCode -lt 0) {
                throw "MariaDB $($Release.Version) を実行できません。Microsoft Visual C++ 再頒布可能パッケージ（x64）の最新版をインストールしてください: $VcRedistUrl"
            }
            throw "zip の中身が想定と違います: $($check.Output.Trim())"
        }

        if (-not $Staging) {
            Write-Step 'mysql フォルダをバックアップ'
            $backup = Join-Path $root ('mysql_backup_{0}_{1}' -f $current, (Get-Date -Format 'yyyyMMdd-HHmmss'))
            Invoke-Robocopy $mysqlDir $backup @('/E', '/COPY:DAT', '/DCOPY:T')
            Write-Info $backup
        }

        try {
            Write-Step "MariaDB $current を一時的に起動して、正常に終了させる"
            Invoke-TemporaryServer $mysqlDir $current @('--innodb-fast-shutdown=0') $null | Out-Null
            Write-Info '正常に終了しました。'

            Write-Step "MariaDB $($Release.Version) に入れ替え"
            Install-MariaDbFile $source $mysqlDir
            Write-Info "mysqld.exe: $(Get-MariaDbVersion $mysqlDir)"
            $iniChanged = Update-MyIni (Join-Path $mysqlDir 'bin\my.ini')
            if ($iniChanged) {
                Write-Info 'my.ini の key_buffer を key_buffer_size に書き換えました。'
            }

            Write-Step 'データを新しい版に移行（mariadb-upgrade）'
            # 移行前の起動では、古いシステムテーブルについてのエラーが必ずログに出るので、ここでは見ない
            Invoke-TemporaryServer $mysqlDir $Release.Version @() {
                param($Port)
                $upgrade = Invoke-Native (Join-Path $mysqlDir 'bin\mariadb-upgrade.exe') @('--no-defaults', '--host=127.0.0.1', "--port=$Port", '--user=root', '--force')
                if ($upgrade.ExitCode -ne 0) {
                    throw "mariadb-upgrade が失敗しました。`n$($upgrade.Output.Trim())"
                }
            } | Out-Null
            Write-Info '移行して、正常に終了しました。'

            Write-Step '移行したデータで起動できることを確認'
            $logs = Invoke-TemporaryServer $mysqlDir $Release.Version @() $null
            Write-Info '起動して、正常に終了しました。'

            if ($Staging) {
                # 新しくインストールしたときの初期データ（mysql\backup）も、移行したものにそろえる
                Remove-Item -LiteralPath (Join-Path $mysqlDir 'data\mysql_error.log') -Force -ErrorAction SilentlyContinue
                Invoke-Robocopy (Join-Path $mysqlDir 'data') (Join-Path $mysqlDir 'backup') @('/MIR', '/COPY:DAT')
            }
        } catch {
            if ($backup) {
                Write-Note '途中で失敗したため、バックアップから元に戻します。'
                $aside = 'mysql_failed_' + (Get-Date -Format 'yyyyMMdd-HHmmss')
                Restore-MysqlFolder $root $backup $aside
                Write-Note "失敗した mysql フォルダは $aside として残しています。"
            }
            throw
        }
    } finally {
        Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue
    }

    $problems = @($logs -split "`r?`n" | Where-Object { $_ -match '\[ERROR\]' } | ForEach-Object { "mysql_error.log: $($_.Trim())" })
    # mariadb-upgrade は、移行した版を data\mariadb_upgrade_info（古い版では mysql_upgrade_info）に記録する
    $recorded = @('mariadb_upgrade_info', 'mysql_upgrade_info' | ForEach-Object { Join-Path $mysqlDir "data\$_" } | Where-Object {
        (Test-Path -LiteralPath $_) -and ((Get-Content -LiteralPath $_ -Raw) -match [regex]::Escape($Release.Version))
    })
    if ($recorded.Count -eq 0) {
        $problems += 'mariadb_upgrade_info に新しい版が記録されていません。'
    }

    Write-Host ''
    if ($problems.Count -gt 0) {
        Write-Host 'MariaDB の入れ替えは終わりましたが、確認で問題が見つかりました:' -ForegroundColor Yellow
        foreach ($problem in $problems) {
            Write-Host "  - $problem" -ForegroundColor Yellow
        }
        if (-not $Staging) {
            Write-Host '元に戻すには、update-xampp-mariadb.bat -Restore を実行してください。'
        }
    } else {
        Write-Host "完了しました: MariaDB $current -> $($Release.Version)" -ForegroundColor Green
    }
    if (-not $Staging) {
        Write-Host 'XAMPP コントロールパネルで MySQL を Start してください。'
        Write-Host "バックアップ: $backup（データを含みます。動作に問題がなければ削除してかまいません）"
    }

    return [pscustomobject]@{
        XamppDir     = $root
        FromVersion  = $current
        ToVersion    = $Release.Version
        Backup       = $backup
        IniChanged   = $iniChanged
        Problems     = $problems
    }
}

function Invoke-Restore {
    $root = Resolve-XamppDir $XamppDir
    $mysqlDir = Join-Path $root 'mysql'
    $backups = @(Get-BackupFolder $root 'mysql_backup_')
    if ($backups.Count -eq 0) {
        Write-Host ''
        Write-Host "MariaDB のバックアップ（mysql_backup_*）がないため、何もしません: $root"
        return
    }
    $backup = $backups[0]
    $backupVersion = Get-MariaDbVersion $backup.FullName

    Write-Step "バックアップから元に戻す: $($backup.FullName)"
    Assert-NotRunning $root $Force $MariaDbProcessNames $StopHint
    Write-Note '更新したあとに追加・変更したデータは、元に戻すと失われます（いまの mysql フォルダは残します）。'
    Confirm-Continue "$mysqlDir を $($backup.Name)（MariaDB $backupVersion）に戻します。よろしいですか？" $Yes

    $aside = 'mysql_replaced_' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Restore-MysqlFolder $root $backup.FullName $aside

    Write-Host ''
    Write-Host "元に戻しました: MariaDB $(Get-MariaDbVersion $mysqlDir)" -ForegroundColor Green
    Write-Host "入れ替え後の mysql フォルダは $aside として残しています。"
    Write-Host 'XAMPP コントロールパネルで MySQL を Start してください。'
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
} finally {
    Remove-Item -LiteralPath $ConsoleDir -Recurse -Force -ErrorAction SilentlyContinue
}
