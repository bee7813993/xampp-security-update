<#
.SYNOPSIS
    XAMPP 一式の zip を展開して Apache を一時的に起動し、PHP が正しく動くかを確かめます。

.DESCRIPTION
    1. zip を作業フォルダに展開し、XAMPP の install\install.php でパスを書き換える
       （Perl、Tomcat、MySQL など、Apache と PHP の確認に使わないフォルダは展開しない）
    2. -ApplyUpdate を付けたときは、update-xampp-php.ps1 を通常の手順（バックアップと確認つき）で適用する
    3. Apache を 127.0.0.1 の別のポートで起動し、HTTP で次のことを確かめる
       - PHP のバージョンと SAPI、読み込まれた php.ini と php8ts.dll の場所
       - php.ini で有効にしている拡張がすべて読み込まれているか（curl を含む）
       - multipart/form-data のファイルアップロード
       - memory_limit を超えるスクリプトのあとも、上限が効いていて Apache が応答し続けるか
       - memory_limit の 3 倍を 1 回で確保するスクリプトのあとも、Apache が応答し続けるか
    4. Apache を止める。-ApplyUpdate を付けたときは、update-xampp-php.ps1 -Restore で
       php フォルダと apache\bin が更新前と同じに戻るかも確かめる
    5. 作業フォルダを片付ける

.EXAMPLE
    .\tests\smoke-test.ps1 -Zip .\dist\xampp-windows-x64-8.2.12-0-VS16-php8.2.35.zip

.EXAMPLE
    .\tests\smoke-test.ps1 -Zip .\downloads\xampp-windows-x64-8.2.12-0-VS16.zip -ApplyUpdate
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Zip,
    [switch]$ApplyUpdate,
    [string]$PhpZip,
    [string]$ExpectedVersion = '8.2.35',
    [int]$Port = 8080,
    [int]$SslPort = 8443,
    [string]$WorkDir,
    [switch]$Keep
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRoot = Split-Path -Parent $PSScriptRoot
# Windows PowerShell 5.1 を -File で起動すると param の既定値では $PSScriptRoot が空なので、ここで決める
if (-not $WorkDir) { $WorkDir = Join-Path $repoRoot 'work\smoke' }
$updater = Join-Path $repoRoot 'update-xampp-php.ps1'
$tar = Join-Path $env:SystemRoot 'System32\tar.exe'
$curl = Join-Path $env:SystemRoot 'System32\curl.exe'
$results = New-Object 'System.Collections.Generic.List[object]'

# update-xampp-php.ps1 の同名関数と同じ。標準エラーも含めた出力と終了コードを返す。
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

function Stop-Httpd($Process) {
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

# php フォルダの PHP のバージョンと、apache\bin の DLL の SHA-256 を控える
function Get-Snapshot([string]$Root) {
    $dlls = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $Root 'apache\bin') -Filter '*.dll' -File)) {
        $dlls[$file.Name] = (Get-FileHash -LiteralPath $file.FullName).Hash
    }
    return [pscustomobject]@{
        Version = (Get-Item -LiteralPath (Join-Path $Root 'php\php8ts.dll')).VersionInfo.ProductVersion
        Ini     = (Get-FileHash -LiteralPath (Join-Path $Root 'php\php.ini')).Hash
        Dlls    = $dlls
    }
}

$httpd = $null
$root = $null
$before = $null
try {
    $Zip = (Resolve-Path -LiteralPath $Zip).Path
    Write-Host "==> 展開: $Zip"
    if (Test-Path -LiteralPath $WorkDir) {
        Remove-Item -LiteralPath $WorkDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    $arguments = @('-xf', $Zip, '-C', $WorkDir)
    foreach ($skip in @('perl', 'tomcat', 'mysql', 'phpMyAdmin', 'FileZillaFTP', 'MercuryMail', 'webalizer', 'src')) {
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
    $xamppConf = Join-Path $root 'apache\conf\extra\httpd-xampp.conf'
    if (-not (Select-String -LiteralPath $xamppConf -SimpleMatch ($root -replace '\\', '/') -Quiet)) {
        throw "パスの書き換えに失敗しました。`n$($result.Output)"
    }

    if ($ApplyUpdate) {
        Write-Host '==> update-xampp-php.ps1 を適用'
        $before = Get-Snapshot $root
        $options = @{ XamppDir = $root; Yes = $true; PassThru = $true }
        if ($PhpZip) {
            $options.PhpZip = $PhpZip
        } else {
            $options.DownloadDir = Join-Path $repoRoot 'downloads'
        }
        $update = & $updater @options
        $exitCode = $LASTEXITCODE
        $ok = ($exitCode -eq 0) -and $update -and ($update.ToVersion -eq $ExpectedVersion) -and $update.Backup -and (Test-Path -LiteralPath $update.Backup)
        $detail = "終了コード $exitCode"
        if ($update) {
            $detail = '{0} -> {1}、apache\bin 更新 [{2}] 追加 [{3}]、php.ini 変更 {4} 件' -f $update.FromVersion, $update.ToVersion,
                (@($update.ApacheUpdated) -join ', '), (@($update.ApacheAdded) -join ', '), @($update.Hardened).Count
        }
        Add-Result 'update-xampp-php.ps1' $ok $detail
        if (-not $ok) {
            throw '更新スクリプトが失敗しました。'
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
    $info = $probe.Body | ConvertFrom-Json
    Add-Result 'PHP のバージョン' ($info.version -eq $ExpectedVersion) $info.version
    Add-Result 'SAPI' ($info.sapi -eq 'apache2handler' -and $info.zts) ('{0}（ZTS: {1}）' -f $info.sapi, $info.zts)
    $iniPath = [string]$info.ini
    Add-Result '読み込まれた php.ini' ($iniPath.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) $iniPath

    $ids = @($httpd.Id) + @(Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId = $($httpd.Id)" | Select-Object -ExpandProperty ProcessId)
    $modules = @()
    foreach ($id in $ids) {
        try {
            $modules += @((Get-Process -Id $id).Modules | Where-Object { $_.ModuleName -eq 'php8ts.dll' })
        } catch { }
    }
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
    $crypto = @()
    foreach ($id in $ids) {
        try {
            $crypto += @((Get-Process -Id $id).Modules | Where-Object { $_.ModuleName -eq 'libcrypto-3-x64.dll' })
        } catch { }
    }
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
    Add-Result 'OpenSSL' ([bool]$info.openssl) ([string]$info.openssl)
    Add-Result 'session.upload_progress.enabled' $true ('"{0}"（php.ini の値）' -f $info.upload_progress)

    # 起動時のエラーは、このあとの memory_limit の確認で出るエラーと混ざらないよう先に見る
    $startup = @()
    if (Test-Path -LiteralPath $errorLog) {
        $startup = @(Select-String -LiteralPath $errorLog -Pattern 'PHP (Warning|Fatal|Startup)|Unable to load' | ForEach-Object { $_.Line.Trim() })
    }
    $startupDetail = 'なし'
    if ($startup.Count -gt 0) {
        $startupDetail = $startup[0]
    }
    Add-Result 'Apache の error.log に PHP の起動時エラー' ($startup.Count -eq 0) $startupDetail

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
} catch {
    Add-Result '実行' $false $_.Exception.Message
} finally {
    Stop-Httpd $httpd
}

if ($before) {
    Write-Host '==> update-xampp-php.ps1 -Restore'
    $restore = Invoke-Native 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $updater, '-XamppDir', $root, '-Restore', '-Yes')
    $now = Get-Snapshot $root
    $diff = @(@($before.Dlls.Keys) + @($now.Dlls.Keys) | Select-Object -Unique | Where-Object { $before.Dlls[$_] -ne $now.Dlls[$_] })
    $restoreOk = ($restore.ExitCode -eq 0) -and ($now.Version -eq $before.Version) -and ($now.Ini -eq $before.Ini) -and ($diff.Count -eq 0)
    $restoreDetail = 'PHP {0}、php.ini 一致 {1}、apache\bin の差分 {2} 件' -f $now.Version, ($now.Ini -eq $before.Ini), $diff.Count
    if ($diff.Count -gt 0) {
        $restoreDetail += '（' + ($diff -join ', ') + '）'
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
