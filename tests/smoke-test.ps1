<#
.SYNOPSIS
    XAMPP の Apache を一時的に起動し、PHP と Apache が正しく動くかを確かめます。

.DESCRIPTION
    1. -Zip を指定したときは、XAMPP 一式の zip を作業フォルダに展開し、XAMPP の install\install.php で
       パスを書き換える（Perl、Tomcat、MySQL など、Apache と PHP の確認に使わないフォルダは展開しない）。
       -XamppDir を指定したときは、インストール済みのそのフォルダをそのまま使う
    2. -ApplyUpdate を付けたときは、update-xampp-php.ps1 と update-xampp-apache.ps1 を
       通常の手順（バックアップと確認つき）で適用する
    3. Apache を 127.0.0.1 の別のポート（HTTP と HTTPS）で起動し、次のことを確かめる
       - Apache と PHP のバージョン、SAPI、読み込まれた php.ini と php8ts.dll の場所
       - php.ini で有効にしている拡張がすべて読み込まれているか（curl を含む）
       - HTTPS で応答するか
       - multipart/form-data のファイルアップロード
       - memory_limit を超えるスクリプトのあとも、上限が効いていて Apache が応答し続けるか
       - memory_limit の 3 倍を 1 回で確保するスクリプトのあとも、Apache が応答し続けるか
    4. Apache を止める。-ApplyUpdate を付けたときは、両方のスクリプトの -Restore で
       php フォルダと apache フォルダが更新前と同じに戻るかも確かめる
    5. 作業フォルダを片付ける

    -XamppDir のときは、そのフォルダの httpd.conf と httpd-ssl.conf の待ち受けポートを書き換え、
    htdocs に確認用のファイルを置きます。確認専用にインストールしたフォルダで使ってください。

.EXAMPLE
    .\tests\smoke-test.ps1 -Zip .\dist\xampp-windows-x64-8.2.12-0-VS16-php8.2.35-apache2.4.69.zip

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

# 更新で変わりうるファイル（php の DLL と php.ini、apache の bin・modules・include・lib・証明書）の SHA-256 を控える
function Get-Snapshot([string]$Root) {
    $files = @{}
    $apache = Join-Path $Root 'apache'
    foreach ($dir in 'bin', 'modules', 'include', 'lib') {
        foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $apache $dir) -File -Recurse)) {
            $files['apache\' + $file.FullName.Substring($apache.Length + 1)] = (Get-FileHash -LiteralPath $file.FullName).Hash
        }
    }
    foreach ($item in 'conf\ssl.crt\server.crt', 'conf\ssl.key\server.key', 'LICENSE.txt', 'NOTICE.txt') {
        $path = Join-Path $apache $item
        if (Test-Path -LiteralPath $path) {
            $files["apache\$item"] = (Get-FileHash -LiteralPath $path).Hash
        }
    }
    foreach ($item in 'php8ts.dll', 'php.ini', 'ext\php_curl.dll') {
        $files["php\$item"] = (Get-FileHash -LiteralPath (Join-Path $Root "php\$item")).Hash
    }
    return $files
}

$httpd = $null
$root = $null
$before = $null
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
    }
    $xamppConf = Join-Path $root 'apache\conf\extra\httpd-xampp.conf'
    if (-not (Select-String -LiteralPath $xamppConf -SimpleMatch ($root -replace '\\', '/') -Quiet)) {
        throw 'httpd-xampp.conf のパスが XAMPP のフォルダを指していません。'
    }

    if ($ApplyUpdate) {
        $before = Get-Snapshot $root
        $downloads = Join-Path $repoRoot 'downloads'

        Write-Host '==> update-xampp-php.ps1 を適用'
        $update = & (Join-Path $repoRoot 'update-xampp-php.ps1') -XamppDir $root -DownloadDir $downloads -Yes -PassThru
        $exitCode = $LASTEXITCODE
        $ok = ($exitCode -eq 0) -and $update -and ($update.ToVersion -eq $ExpectedVersion) -and $update.Backup -and (Test-Path -LiteralPath $update.Backup)
        $detail = "終了コード $exitCode"
        if ($update) {
            $detail = '{0} -> {1}、apache\bin 更新 [{2}] 追加 [{3}]、php.ini 変更 {4} 件' -f $update.FromVersion, $update.ToVersion,
                (@($update.ApacheUpdated) -join ', '), (@($update.ApacheAdded) -join ', '), @($update.Hardened).Count
        }
        Add-Result 'update-xampp-php.ps1' $ok $detail
        if (-not $ok) {
            throw 'PHP の更新スクリプトが失敗しました。'
        }

        Write-Host '==> update-xampp-apache.ps1 を適用'
        $update = & (Join-Path $repoRoot 'update-xampp-apache.ps1') -XamppDir $root -DownloadDir $downloads -Yes -PassThru
        $exitCode = $LASTEXITCODE
        $ok = ($exitCode -eq 0) -and $update -and ($update.ToVersion -eq $ExpectedApacheVersion) -and $update.Backup -and (Test-Path -LiteralPath $update.Backup)
        $detail = "終了コード $exitCode"
        if ($update) {
            $detail = '{0} -> {1}、更新 {2} 追加 {3} ファイル、証明書の作り直し: {4}' -f $update.FromVersion, $update.ToVersion,
                @($update.Updated).Count, @($update.Added).Count, [bool]$update.Certificate
        }
        Add-Result 'update-xampp-apache.ps1' $ok $detail
        if (-not $ok) {
            throw 'Apache の更新スクリプトが失敗しました。'
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
} catch {
    Add-Result '実行' $false $_.Exception.Message
} finally {
    Stop-Httpd $httpd
}

if ($before) {
    Write-Host '==> update-xampp-apache.ps1 -Restore と update-xampp-php.ps1 -Restore'
    $restoreCodes = @()
    foreach ($script in 'update-xampp-apache.ps1', 'update-xampp-php.ps1') {
        $restore = Invoke-Native 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $repoRoot $script), '-XamppDir', $root, '-Restore', '-Yes')
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
