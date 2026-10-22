<#
.SYNOPSIS
    XAMPP の Apache と MariaDB を一時的に起動し、PHP、Apache、MariaDB、phpMyAdmin が正しく動くかを確かめます。

.DESCRIPTION
    1. -Zip を指定したときは、XAMPP 一式の zip を作業フォルダに展開し、XAMPP の install\install.php で
       パスを書き換える（Perl、Tomcat など、確認に使わないフォルダは展開しない）。
       -XamppDir を指定したときは、インストール済みのそのフォルダをそのまま使う
    2. -ApplyUpdate を付けたときは、元の MariaDB に確認用のデータを書き込んで（XAMPP と同じく）強制終了させてから、
       update-xampp-php / apache / mariadb / phpmyadmin.ps1 を通常の手順（バックアップと確認つき）で適用する
    3. Apache を 127.0.0.1 の別のポート（HTTP と HTTPS）で、MariaDB を 127.0.0.1 の空いているポートで、
       XAMPP コントロールパネルと同じ引数で起動し、次のことを確かめる
       - Apache と PHP のバージョン、SAPI、読み込まれた php.ini と php8ts.dll の場所
       - php.ini で有効にしている拡張がすべて読み込まれているか（curl を含む）
       - HTTPS で応答するか
       - multipart/form-data のファイルアップロード
       - memory_limit を超えるスクリプトのあとも、上限が効いていて Apache が応答し続けるか
       - memory_limit の 3 倍を 1 回で確保するスクリプトのあとも、Apache が応答し続けるか
       - MariaDB のバージョン、移行したデータ、PHP（mysqli）からの読み書き、phpMyAdmin の画面
    4. Apache と MariaDB を止める。-ApplyUpdate を付けたときは、各スクリプトの -Restore で
       php、apache、mysql、phpMyAdmin の各フォルダが更新前と同じに戻るかも確かめる
    5. 作業フォルダを片付ける

    -XamppDir のときは、そのフォルダの httpd.conf、httpd-ssl.conf の待ち受けポートと phpMyAdmin の接続先ポートを
    書き換え、htdocs に確認用のファイルを置きます。確認専用にインストールしたフォルダで使ってください。

.EXAMPLE
    .\tests\smoke-test.ps1 -Zip .\dist\xampp-windows-x64-8.2.12-0-VS16-php8.2.35-apache2.4.69-mariadb11.4.13-pma5.2.3.zip

.EXAMPLE
    .\tests\smoke-test.ps1 -Zip .\downloads\xampp-windows-x64-8.2.12-0-VS16.zip -ApplyUpdate

.EXAMPLE
    .\tests\smoke-test.ps1 -XamppDir .\work\installtest\xampp
#>
[CmdletBinding()]
param(
    [string]$Zip,
    [string]$XamppDir,
    [switch]$ApplyUpdate,
    [string]$ExpectedVersion = '8.2.35',
    [string]$ExpectedApacheVersion = '2.4.69',
    [string]$ExpectedMariaDbVersion = '11.4.13',
    [string]$ExpectedPhpMyAdminVersion = '5.2.3',
    [int]$Port = 8080,
    [int]$SslPort = 8443,
    [string]$WorkDir,
    [switch]$Keep
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'xampp-update-common.ps1')
# Windows PowerShell 5.1 を -File で起動すると param の既定値では $PSScriptRoot が空なので、ここで決める
if (-not $WorkDir) { $WorkDir = Join-Path $repoRoot 'work\smoke' }
if ([bool]$Zip -eq [bool]$XamppDir) {
    throw '-Zip か -XamppDir のどちらか一方を指定してください。'
}
$tar = Join-Path (Get-SystemDir) 'tar.exe'
$curl = Join-Path (Get-SystemDir) 'curl.exe'
$results = New-Object 'System.Collections.Generic.List[object]'
$UpdateScripts = 'php', 'apache', 'mariadb', 'phpmyadmin'

function Add-Result([string]$Name, [bool]$Ok, [string]$Detail) {
    $mark = 'NG'
    $color = 'Red'
    if ($Ok) {
        $mark = 'OK'
        $color = 'Green'
    }
    $results.Add([pscustomobject]@{ Result = $mark; Check = $Name; Detail = $Detail })
    Write-Host ('  [{0}] {1}: {2}' -f $mark, $Name, $Detail) -ForegroundColor $color
}

function Edit-TextFile([string]$Path, [scriptblock]$Edit) {
    $encoding = [Text.Encoding]::GetEncoding(28591)
    $text = [IO.File]::ReadAllText($Path, $encoding)
    [IO.File]::WriteAllText($Path, (& $Edit $text), $encoding)
}

function Invoke-Http([string]$Url, [string[]]$Extra) {
    $body = [IO.Path]::GetTempFileName()
    try {
        $result = Invoke-Native $curl (@('-sS', '-m', '60', '-o', $body, '-w', '%{http_code}') + $Extra + @($Url))
        [pscustomobject]@{ Status = $result.Output.Trim(); Body = [IO.File]::ReadAllText($body) }
    } finally {
        Remove-Item -LiteralPath $body -Force -ErrorAction SilentlyContinue
    }
}

function Stop-ProcessTree($Process) {
    if (-not $Process) {
        return
    }
    $ids = @(Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId = $($Process.Id)" -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty ProcessId) + @($Process.Id)
    foreach ($id in $ids) {
        Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
    }
    foreach ($id in $ids) {
        Wait-Process -Id $id -Timeout 15 -ErrorAction SilentlyContinue
    }
}

function Get-ModuleInProcess($Process, [string]$Name) {
    $ids = @($Process.Id) + @(Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId = $($Process.Id)" | Select-Object -ExpandProperty ProcessId)
    $modules = @()
    foreach ($id in $ids) {
        try {
            $modules += @((Get-Process -Id $id).Modules | Where-Object { $_.ModuleName -eq $Name })
        } catch { }
    }
    return $modules
}

# MariaDB が書き込み中のエラーログを、$Offset バイト目から読む
function Read-LogSince([string]$Path, [long]$Offset) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return ''
    }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        if ($Offset -ge $stream.Length) {
            return ''
        }
        $stream.Position = $Offset
        return (New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)).ReadToEnd()
    } finally {
        $stream.Dispose()
    }
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

# XAMPP コントロールパネルと同じ引数（--defaults-file と --standalone）で MariaDB を起動する。
# Windows 版の MariaDB 10.4 は、非表示のコンソールで起動すると、起動の途中でコンソールを切り離すときにまれに落ちるので、
# 標準出力と標準エラー出力はファイルに向ける。初期化の途中で接続されても落ちることがあるので、
# ポートの待ち受けが始まってから 3 秒たってから接続を確かめる。
function Start-TestMariaDb([string]$Root, [int]$DbPort) {
    $mysql = Join-Path $Root 'mysql'
    $arguments = @("--defaults-file=`"$mysql\bin\my.ini`"", '--standalone', "--port=$DbPort", '--bind-address=127.0.0.1')
    $name = 'mysqld-{0}-{1}' -f $DbPort, [guid]::NewGuid().ToString('N').Substring(0, 8)
    $process = Start-Process -FilePath (Join-Path $mysql 'bin\mysqld.exe') -ArgumentList $arguments -WorkingDirectory $Root -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $WorkDir "$name.out") -RedirectStandardError (Join-Path $WorkDir "$name.err")
    $ping = [pscustomobject]@{ Output = '（接続前）' }
    $listening = -1
    try {
        for ($i = 0; $i -lt 240 -and -not $process.HasExited; $i++) {
            Start-Sleep -Milliseconds 500
            if ($listening -lt 0 -and [bool]([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object { $_.Port -eq $DbPort })) {
                $listening = $i
            }
            if ($listening -lt 0 -or $i - $listening -lt 6) {
                continue
            }
            $ping = Invoke-Native (Join-Path $mysql 'bin\mysqladmin.exe') @('--no-defaults', '--host=127.0.0.1', "--port=$DbPort", '--user=root', '--connect-timeout=5', 'ping')
            if ($ping.Output -match 'alive') {
                return $process
            }
        }
    } catch {
        Stop-ProcessTree $process
        throw
    }
    $state = '動作中のまま応答なし'
    if ($process.HasExited) {
        $state = "終了コード $($process.ExitCode) で終了"
    }
    Stop-ProcessTree $process
    throw "MariaDB が起動しません（$state、最後の ping: $($ping.Output.Trim())）。`n$((Get-Content -LiteralPath (Join-Path $mysql 'data\mysql_error.log') -Tail 15 -ErrorAction SilentlyContinue) -join "`n")"
}

function Invoke-Sql([string]$Root, [int]$DbPort, [string]$Sql) {
    $result = Invoke-Native (Join-Path $Root 'mysql\bin\mysql.exe') @('--no-defaults', '--host=127.0.0.1', "--port=$DbPort", '--user=root', '-N', '-B', '-e', $Sql)
    # MariaDB 11.4 の mysql.exe は、パスワードなしで接続するとサーバー証明書の検証を省くことを WARNING で知らせる
    $lines = @($result.Output -split "`n" | Where-Object { $_ -notmatch '^WARNING: option --ssl-verify-server-cert' })
    return [pscustomobject]@{ ExitCode = $result.ExitCode; Output = ($lines -join "`n") }
}

function Stop-TestMariaDb([string]$Root, [int]$DbPort, $Process) {
    if (-not $Process -or $Process.HasExited) {
        return
    }
    Invoke-Native (Join-Path $Root 'mysql\bin\mysqladmin.exe') @('--no-defaults', '--host=127.0.0.1', "--port=$DbPort", '--user=root', 'shutdown') | Out-Null
    if (-not $Process.WaitForExit(120000)) {
        Stop-ProcessTree $Process
    }
}

# 更新で変わりうるファイルの SHA-256 を控える
function Get-Snapshot([string]$Root) {
    $files = @{}
    $add = {
        param([string]$Path)
        $files[$Path.Substring($Root.Length + 1)] = (Get-FileHash -LiteralPath $Path).Hash
    }
    foreach ($dir in 'apache\bin', 'apache\modules', 'apache\include', 'apache\lib', 'mysql') {
        $path = Join-Path $Root $dir
        if (Test-Path -LiteralPath $path) {
            foreach ($file in @(Get-ChildItem -LiteralPath $path -File -Recurse)) {
                & $add $file.FullName
            }
        }
    }
    foreach ($item in 'apache\conf\ssl.crt\server.crt', 'apache\conf\ssl.key\server.key', 'apache\LICENSE.txt', 'php\php8ts.dll', 'php\php.ini',
        'php\ext\php_curl.dll', 'phpMyAdmin\libraries\classes\Version.php', 'phpMyAdmin\config.inc.php', 'phpMyAdmin\index.php') {
        $path = Join-Path $Root $item
        if (Test-Path -LiteralPath $path) {
            & $add $path
        }
    }
    return $files
}

$httpd = $null
$mariadb = $null
$dbPort = 0
$root = $null
$before = $null
$seeded = $false
try {
    if (Test-Path -LiteralPath $WorkDir) {
        Remove-Item -LiteralPath $WorkDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

    if ($XamppDir) {
        $root = (Resolve-Path -LiteralPath $XamppDir).Path.TrimEnd('\')
        Write-Host "==> インストール済みの XAMPP: $root"
    } else {
        $Zip = (Resolve-Path -LiteralPath $Zip).Path
        Write-Host "==> 展開: $Zip"
        $arguments = @('-xf', $Zip, '-C', $WorkDir)
        foreach ($skip in @('perl', 'tomcat', 'FileZillaFTP', 'MercuryMail', 'webalizer', 'src', 'mysql/backup')) {
            $arguments += @('--exclude', "xampp/$skip")
        }
        $result = Invoke-Native $tar $arguments
        if ($result.ExitCode -ne 0) {
            throw "展開に失敗しました: $($result.Output)"
        }
        $root = Join-Path $WorkDir 'xampp'

        Write-Host '==> パスの書き換え（install\install.php）'
        Push-Location -LiteralPath $root
        try {
            $result = Invoke-Native 'cmd.exe' @('/d', '/c', 'echo 1| php\php.exe -n -d output_buffering=0 install\install.php')
        } finally {
            Pop-Location
        }
    }
    $xamppConf = Join-Path $root 'apache\conf\extra\httpd-xampp.conf'
    if (-not (Select-String -LiteralPath $xamppConf -SimpleMatch ($root -replace '\\', '/') -Quiet)) {
        throw 'httpd-xampp.conf のパスが XAMPP のフォルダを指していません。'
    }
    $hasMariaDb = Test-Path -LiteralPath (Join-Path $root 'mysql\bin\mysqld.exe')
    $hasPhpMyAdmin = Test-Path -LiteralPath (Join-Path $root 'phpMyAdmin\index.php')
    if ($hasMariaDb) {
        $dbPort = Get-FreePort
    }

    if ($ApplyUpdate) {
        if ($hasMariaDb) {
            # 元の MariaDB にデータを書き込み、XAMPP の MySQL の停止と同じく強制終了させる
            Write-Host '==> 元の MariaDB に確認用のデータを書き込んで、強制終了させる'
            $old = Start-TestMariaDb $root $dbPort
            $seed = Invoke-Sql $root $dbPort ('CREATE DATABASE xampp_update_test; CREATE TABLE xampp_update_test.t (id INT PRIMARY KEY, name VARCHAR(20)) ENGINE=InnoDB; ' +
                "INSERT INTO xampp_update_test.t VALUES (1, 'alpha'), (2, 'beta'), (3, 'gamma');")
            Stop-ProcessTree $old
            $seeded = $seed.ExitCode -eq 0
            Add-Result '元の MariaDB にデータを書き込んで強制終了' $seeded $(if ($seeded) { 'xampp_update_test.t に 3 行' } else { $seed.Output })
        }
        $before = Get-Snapshot $root
        $downloads = Join-Path $repoRoot 'downloads'
        foreach ($name in $UpdateScripts) {
            Write-Host "==> update-xampp-$name.ps1 を適用"
            $update = & (Join-Path $repoRoot "update-xampp-$name.ps1") -XamppDir $root -DownloadDir $downloads -Yes -PassThru
            $exitCode = $LASTEXITCODE
            $ok = ($exitCode -eq 0) -and $update -and $update.Backup -and (Test-Path -LiteralPath $update.Backup)
            $detail = "終了コード $exitCode"
            if ($update) {
                $detail = '{0} -> {1}' -f $update.FromVersion, $update.ToVersion
            }
            Add-Result "update-xampp-$name.ps1" $ok $detail
            if (-not $ok) {
                throw "update-xampp-$name.ps1 が失敗しました。"
            }
        }
    }

    Write-Host "==> Apache の待ち受けを 127.0.0.1:$Port / $SslPort に変更"
    Edit-TextFile (Join-Path $root 'apache\conf\httpd.conf') {
        param($text)
        $text = $text -replace '(?m)^Listen 80(?=\r?$)', "Listen 127.0.0.1:$Port"
        $text -replace '(?m)^ServerName localhost:80(?=\r?$)', "ServerName localhost:$Port"
    }
    Edit-TextFile (Join-Path $root 'apache\conf\extra\httpd-ssl.conf') {
        param($text)
        $text = $text -replace '(?m)^Listen 443(?=\r?$)', "Listen 127.0.0.1:$SslPort"
        $text -replace ':443>', ":$SslPort>" -replace 'www\.example\.com:443', "www.example.com:$SslPort"
    }
    if (-not (Select-String -LiteralPath (Join-Path $root 'apache\conf\httpd.conf') -SimpleMatch "Listen 127.0.0.1:$Port" -Quiet)) {
        throw 'httpd.conf の Listen を変更できませんでした。'
    }
    if ($hasMariaDb -and $hasPhpMyAdmin) {
        # phpMyAdmin の接続先を、確認用に起動する MariaDB のポートにする
        Edit-TextFile (Join-Path $root 'phpMyAdmin\config.inc.php') {
            param($text)
            $line = "`$cfg['Servers'][`$i]['port'] = '$dbPort';`r`n"
            $at = $text.LastIndexOf('?>')
            if ($at -lt 0) {
                return $text + "`r`n" + $line
            }
            return $text.Insert($at, $line)
        }
    }

    $htdocs = Join-Path $root 'htdocs'
    Set-Content -LiteralPath (Join-Path $htdocs '__smoke.php') -Encoding Ascii -Value @'
<?php
$extensions = get_loaded_extensions();
sort($extensions);
$curl = function_exists('curl_version') ? curl_version() : null;
header('Content-Type: application/json');
echo json_encode(array(
    'version' => PHP_VERSION,
    'sapi' => PHP_SAPI,
    'zts' => (bool) PHP_ZTS,
    'ini' => php_ini_loaded_file(),
    'https' => !empty($_SERVER['HTTPS']),
    'upload_progress' => ini_get('session.upload_progress.enabled'),
    'openssl' => defined('OPENSSL_VERSION_TEXT') ? OPENSSL_VERSION_TEXT : null,
    'curl' => $curl ? $curl['version'] . ' / ' . $curl['ssl_version'] . ' / libssh2 ' . $curl['libssh_version'] : null,
    'extensions' => $extensions,
));
'@
    Set-Content -LiteralPath (Join-Path $htdocs '__upload.php') -Encoding Ascii -Value @'
<?php
header('Content-Type: application/json');
$file = isset($_FILES['file']) ? $_FILES['file'] : null;
echo json_encode(array(
    'field' => isset($_POST['field']) ? $_POST['field'] : null,
    'error' => $file ? $file['error'] : null,
    'size' => $file ? $file['size'] : null,
    'sha256' => ($file && $file['error'] === UPLOAD_ERR_OK) ? hash_file('sha256', $file['tmp_name']) : null,
));
'@
    Set-Content -LiteralPath (Join-Path $htdocs '__oom.php') -Encoding Ascii -Value @'
<?php
ini_set('memory_limit', '32M');
$chunks = array();
while (true) {
    $chunks[] = str_repeat('x', 1048576);
}
'@
    # memory_limit の 3 倍を 1 回で確保する。修正版では、よく使う関数の大きな確保は通常の Fatal error になり、
    # プロセスごと終了するハード上限（既定は memory_limit の 200%）は、それ以外の確保に対する最後の歯止め
    Set-Content -LiteralPath (Join-Path $htdocs '__bigalloc.php') -Encoding Ascii -Value @'
<?php
ini_set('memory_limit', '32M');
$big = str_repeat('x', 96 * 1048576);
echo strlen($big);
'@
    Set-Content -LiteralPath (Join-Path $htdocs '__db.php') -Encoding Ascii -Value @'
<?php
mysqli_report(MYSQLI_REPORT_ERROR | MYSQLI_REPORT_STRICT);
header('Content-Type: application/json');
$db = new mysqli('127.0.0.1', 'root', '', 'test', (int) $_GET['port']);
$db->query('CREATE TABLE IF NOT EXISTS smoke_php (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(20))');
$db->query("INSERT INTO smoke_php (name) VALUES ('from php')");
$count = $db->query('SELECT COUNT(*) FROM smoke_php')->fetch_row()[0];
echo json_encode(array('server' => $db->server_info, 'rows' => (int) $count));
'@

    Write-Host '==> Apache を起動'
    $httpd = Start-Process -FilePath (Join-Path $root 'apache\bin\httpd.exe') -WorkingDirectory $root -WindowStyle Hidden -PassThru
    $probe = $null
    for ($i = 0; $i -lt 60 -and -not $httpd.HasExited; $i++) {
        Start-Sleep -Milliseconds 500
        $probe = Invoke-Http "http://127.0.0.1:$Port/__smoke.php" @()
        if ($probe.Status -eq '200') {
            break
        }
    }
    $errorLog = Join-Path $root 'apache\logs\error.log'
    if (-not $probe -or $probe.Status -ne '200') {
        $tail = ''
        if (Test-Path -LiteralPath $errorLog) {
            $tail = (Get-Content -LiteralPath $errorLog -Tail 20) -join "`n"
        }
        throw "Apache が応答しません。`n$tail"
    }

    Write-Host '==> 確認'
    $apacheExe = Get-Item -LiteralPath (Join-Path $root 'apache\bin\httpd.exe')
    $apacheVersion = ($apacheExe.VersionInfo.FileVersion -split ' ')[0]
    Add-Result 'Apache のバージョン' ($apacheVersion -eq $ExpectedApacheVersion) $apacheVersion

    $info = $probe.Body | ConvertFrom-Json
    Add-Result 'PHP のバージョン' ($info.version -eq $ExpectedVersion) $info.version
    Add-Result 'SAPI' ($info.sapi -eq 'apache2handler' -and $info.zts) ('{0}（ZTS: {1}）' -f $info.sapi, $info.zts)
    $iniPath = [string]$info.ini
    Add-Result '読み込まれた php.ini' ($iniPath.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) $iniPath

    $modules = @(Get-ModuleInProcess $httpd 'php8ts.dll')
    $dllOk = $modules.Count -gt 0
    foreach ($module in $modules) {
        if (-not $module.FileName.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or $module.FileVersionInfo.ProductVersion -ne $ExpectedVersion) {
            $dllOk = $false
        }
    }
    $dllDetail = '見つかりません'
    if ($modules.Count -gt 0) {
        $dllDetail = '{0}（{1}、{2} プロセス）' -f $modules[0].FileName, $modules[0].FileVersionInfo.ProductVersion, $modules.Count
    }
    Add-Result 'Apache が読み込んだ php8ts.dll' $dllOk $dllDetail

    # Apache の中では、PHP の openssl / curl 拡張も apache\bin の OpenSSL を使う（参考情報）
    $crypto = @(Get-ModuleInProcess $httpd 'libcrypto-3-x64.dll')
    $cryptoDetail = '読み込まれていません'
    if ($crypto.Count -gt 0) {
        $cryptoDetail = '{0}（{1}）' -f $crypto[0].FileName, $crypto[0].FileVersionInfo.FileVersion
    }
    Add-Result 'Apache の中で使われる libcrypto（参考）' $true $cryptoDetail

    $loaded = @($info.extensions | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $wanted = @()
    foreach ($line in (Get-Content -LiteralPath $iniPath)) {
        if ($line -match '^\s*(zend_)?extension\s*=\s*"?([^";\s]+)') {
            $name = ([IO.Path]::GetFileNameWithoutExtension($Matches[2]) -replace '^php_', '').ToLowerInvariant()
            if ($name -eq 'opcache') {
                $name = 'zend opcache'
            }
            $wanted += $name
        }
    }
    $missing = @($wanted | Where-Object { $loaded -notcontains $_ })
    $extDetail = '{0} 個すべて読み込み済み（{1}）' -f $wanted.Count, ($wanted -join ', ')
    if ($missing.Count -gt 0) {
        $extDetail = '読み込まれていない: ' + ($missing -join ', ')
    }
    Add-Result 'php.ini で有効にしている拡張' ($missing.Count -eq 0) $extDetail
    Add-Result 'curl' ([bool]$info.curl) ([string]$info.curl)
    Add-Result 'session.upload_progress.enabled' $true ('"{0}"（php.ini の値）' -f $info.upload_progress)

    # 起動時のエラーは、このあとの memory_limit の確認で出るエラーと混ざらないよう先に見る
    $startup = @()
    if (Test-Path -LiteralPath $errorLog) {
        $startup = @(Select-String -LiteralPath $errorLog -Pattern 'PHP (Warning|Fatal|Startup)|Unable to load|AH0\d+: .*(error|fail)' | ForEach-Object { $_.Line.Trim() })
    }
    $startupDetail = 'なし'
    if ($startup.Count -gt 0) {
        $startupDetail = $startup[0]
    }
    Add-Result 'Apache の error.log に起動時のエラー' ($startup.Count -eq 0) $startupDetail

    $secure = Invoke-Http "https://127.0.0.1:$SslPort/__smoke.php" @('-k')
    $secureOk = $false
    $secureDetail = "HTTP $($secure.Status)"
    if ($secure.Status -eq '200') {
        $secureInfo = $secure.Body | ConvertFrom-Json
        $secureOk = [bool]$secureInfo.https
        $secureDetail = 'HTTP 200、$_SERVER[HTTPS]: {0}' -f $secureInfo.https
    }
    Add-Result 'HTTPS' $secureOk $secureDetail

    $upload = Join-Path $WorkDir 'upload.bin'
    $bytes = New-Object byte[] 262144
    (New-Object Random 1).NextBytes($bytes)
    [IO.File]::WriteAllBytes($upload, $bytes)
    $expected = (Get-FileHash -LiteralPath $upload -Algorithm SHA256).Hash.ToLowerInvariant()
    $response = Invoke-Http "http://127.0.0.1:$Port/__upload.php" @('-F', 'field=hello', '-F', "file=@$upload")
    $uploadOk = $false
    $uploadDetail = "HTTP $($response.Status)"
    if ($response.Status -eq '200') {
        $body = $response.Body | ConvertFrom-Json
        $uploadOk = ($body.field -eq 'hello') -and ($body.error -eq 0) -and ($body.sha256 -eq $expected)
        $uploadDetail = 'HTTP 200、{0} バイト、SHA-256 一致: {1}' -f $body.size, ($body.sha256 -eq $expected)
    }
    Add-Result 'multipart/form-data のアップロード' $uploadOk $uploadDetail

    $oom = Invoke-Http "http://127.0.0.1:$Port/__oom.php" @()
    $phpErrorLog = Join-Path $root 'php\logs\php_error_log'
    $limited = $oom.Body -match 'Allowed memory size'
    if (-not $limited -and (Test-Path -LiteralPath $phpErrorLog)) {
        $limited = [bool](Select-String -LiteralPath $phpErrorLog -SimpleMatch 'Allowed memory size' -Quiet)
    }
    Add-Result 'memory_limit の上限' $limited "HTTP $($oom.Status)、Allowed memory size のエラー: $limited"
    $after = Invoke-Http "http://127.0.0.1:$Port/__smoke.php" @()
    Add-Result 'memory_limit 超過後の応答' (($after.Status -eq '200') -and -not $httpd.HasExited) "HTTP $($after.Status)"

    # 万一ハード上限に当たると Apache の子プロセスごと終了するので、応答が戻るまで待って様子を記録する
    $big = Invoke-Http "http://127.0.0.1:$Port/__bigalloc.php" @()
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $recovered = $false
    for ($i = 0; $i -lt 60 -and -not $httpd.HasExited; $i++) {
        if ((Invoke-Http "http://127.0.0.1:$Port/__smoke.php" @()).Status -eq '200') {
            $recovered = $true
            break
        }
        Start-Sleep -Milliseconds 500
    }
    $restarted = [bool](Select-String -LiteralPath $errorLog -Pattern 'exited with status 137' -Quiet)
    $bigDetail = 'HTTP {0}、Allowed memory size のエラー: {1}、子プロセスの再起動: {2}、応答まで {3:N1} 秒' -f ($big.Status -replace '\s+', ' '), ($big.Body -match 'Allowed memory size'), $restarted, $watch.Elapsed.TotalSeconds
    Add-Result 'memory_limit を大きく超える確保のあとの応答' $recovered $bigDetail

    if ($hasMariaDb) {
        Write-Host "==> MariaDB を起動（127.0.0.1:$dbPort）"
        $mysqlLog = Join-Path $root 'mysql\data\mysql_error.log'
        $logOffset = 0
        if (Test-Path -LiteralPath $mysqlLog) {
            $logOffset = (Get-Item -LiteralPath $mysqlLog).Length
        }
        $mariadb = Start-TestMariaDb $root $dbPort
        $version = (Invoke-Sql $root $dbPort 'SELECT VERSION();').Output.Trim()
        Add-Result 'MariaDB のバージョン（XAMPP と同じ引数で起動）' ($version -like "$ExpectedMariaDbVersion-*") $version
        if ($seeded) {
            $rows = (Invoke-Sql $root $dbPort "SELECT GROUP_CONCAT(name ORDER BY id) FROM xampp_update_test.t;").Output.Trim()
            Add-Result '強制終了のあとに移行したデータ' ($rows -eq 'alpha,beta,gamma') $rows
        }
        $dbResponse = Invoke-Http "http://127.0.0.1:$Port/__db.php?port=$dbPort" @()
        $dbOk = $false
        $dbDetail = "HTTP $($dbResponse.Status) $($dbResponse.Body)"
        if ($dbResponse.Status -eq '200') {
            $dbInfo = $dbResponse.Body | ConvertFrom-Json
            $dbOk = ($dbInfo.server -like "$ExpectedMariaDbVersion-*") -and ($dbInfo.rows -ge 1)
            $dbDetail = 'mysqli で接続、サーバー {0}、書き込んだ行 {1}' -f $dbInfo.server, $dbInfo.rows
        }
        Add-Result 'PHP（mysqli）からの読み書き' $dbOk $dbDetail

        if ($hasPhpMyAdmin) {
            $pma = Invoke-Http "http://127.0.0.1:$Port/phpmyadmin/index.php" @('-L')
            $pmaOk = ($pma.Status -eq '200') -and ($pma.Body -match [regex]::Escape($ExpectedMariaDbVersion)) -and ($pma.Body -match [regex]::Escape($ExpectedPhpMyAdminVersion))
            Add-Result 'phpMyAdmin の画面' $pmaOk ('HTTP {0}、MariaDB {1} の表示: {2}、phpMyAdmin {3} の表示: {4}' -f $pma.Status, $ExpectedMariaDbVersion,
                ($pma.Body -match [regex]::Escape($ExpectedMariaDbVersion)), $ExpectedPhpMyAdminVersion, ($pma.Body -match [regex]::Escape($ExpectedPhpMyAdminVersion)))
        }

        Stop-TestMariaDb $root $dbPort $mariadb
        $dbErrors = @((Read-LogSince $mysqlLog $logOffset) -split "`r?`n" | Where-Object { $_ -match '\[ERROR\]' })
        Add-Result 'mysql_error.log に起動中のエラー' ($dbErrors.Count -eq 0) $(if ($dbErrors.Count) { $dbErrors[0].Trim() } else { 'なし' })
    } else {
        Add-Result 'MariaDB' $true '入っていないため省略'
    }
} catch {
    Add-Result '実行' $false $_.Exception.Message
} finally {
    Stop-ProcessTree $httpd
    if ($mariadb -and -not $mariadb.HasExited) {
        Stop-ProcessTree $mariadb
    }
}

if ($before) {
    Write-Host '==> 各スクリプトの -Restore'
    $restoreCodes = @()
    foreach ($name in @($UpdateScripts)[($UpdateScripts.Count - 1)..0]) {
        $restore = Invoke-Native 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $repoRoot "update-xampp-$name.ps1"), '-XamppDir', $root, '-Restore', '-Yes')
        $restoreCodes += $restore.ExitCode
    }
    $now = Get-Snapshot $root
    $diff = @(@($before.Keys) + @($now.Keys) | Select-Object -Unique | Where-Object { $before[$_] -ne $now[$_] })
    $restoreOk = (@($restoreCodes | Where-Object { $_ -ne 0 }).Count -eq 0) -and ($diff.Count -eq 0)
    $restoreDetail = '終了コード [{0}]、比べたファイル {1} 個、差分 {2} 個' -f ($restoreCodes -join ', '), $before.Count, $diff.Count
    if ($diff.Count -gt 0) {
        $restoreDetail += '（' + (($diff | Select-Object -First 5) -join ', ') + '）'
    }
    Add-Result 'Restore で元に戻る' $restoreOk $restoreDetail
}

if (-not $Keep) {
    for ($i = 0; $i -lt 3 -and (Test-Path -LiteralPath $WorkDir); $i++) {
        Start-Sleep -Seconds 1
        Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$failed = @($results | Where-Object { $_.Result -ne 'OK' })
Write-Host ''
if ($failed.Count -eq 0) {
    Write-Host "すべての確認に通りました（$($results.Count) 項目）。" -ForegroundColor Green
    exit 0
}
Write-Host "$($failed.Count) 項目で問題がありました。" -ForegroundColor Red
exit 1
