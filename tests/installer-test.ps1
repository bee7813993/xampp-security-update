<#
.SYNOPSIS
    インストーラーを確認用のフォルダにサイレントでインストールし、中身と動作を確かめてからアンインストールします。

.DESCRIPTION
    1. セットアップを /VERYSILENT で確認用のフォルダ（既定は work\installtest\xampp）にインストールする
       （MariaDB と phpMyAdmin を含む「すべて」。スタートメニューとデスクトップのアイコンは作らない）
    2. 入るべきもの・入らないもの、設定ファイルのパスの書き換え、HTTPS 用の証明書（その PC だけの鍵）を確かめる
    3. tests\smoke-test.ps1 -XamppDir で Apache を一時的に起動して確かめる
    4. アンインストールし、インストールしたファイルが消え、MySQL のデータが残ることを確かめる

.EXAMPLE
    .\tests\installer-test.ps1 -Setup .\dist\xampp-8.2.12-php8.2.35-apache2.4.69-setup.exe
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Setup,
    [string]$InstallDir,
    [string]$ExpectedVersion = '8.2.35',
    [string]$ExpectedApacheVersion = '2.4.69',
    [switch]$Keep
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'xampp-update-common.ps1')
# Windows PowerShell 5.1 を -File で起動すると param の既定値では $PSScriptRoot が空なので、ここで決める
if (-not $InstallDir) { $InstallDir = Join-Path $repoRoot 'work\installtest\xampp' }
$UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{BB7364E5-EE3F-4445-8B9B-B8B60ACC0445}_is1'
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

# Inno Setup のアンインストーラーは自分を一時フォルダにコピーして起動し直すので、unins000.exe が消えるまで待つ
function Invoke-Uninstall([string]$Dir) {
    $uninstaller = Join-Path $Dir 'unins000.exe'
    if (-not (Test-Path -LiteralPath $uninstaller)) {
        return $false
    }
    Start-Process -FilePath $uninstaller -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait | Out-Null
    for ($i = 0; $i -lt 240 -and (Test-Path -LiteralPath $uninstaller); $i++) {
        Start-Sleep -Milliseconds 500
    }
    return -not (Test-Path -LiteralPath $uninstaller)
}

try {
    $Setup = (Resolve-Path -LiteralPath $Setup).Path
    if (Test-Path -LiteralPath $InstallDir) {
        Invoke-Uninstall $InstallDir | Out-Null
        Remove-Item -LiteralPath $InstallDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $InstallDir) | Out-Null
    $log = Join-Path (Split-Path -Parent $InstallDir) 'setup.log'

    Write-Host "==> インストール: $InstallDir"
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $process = Start-Process -FilePath $Setup -Wait -PassThru -ArgumentList @(
        '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CURRENTUSER', '/TYPE=full', '/MERGETASKS="!startmenuicon"',
        "/DIR=`"$InstallDir`"", "/LOG=`"$log`""
    )
    Add-Result 'インストール' ($process.ExitCode -eq 0) ('終了コード {0}、{1:N0} 秒' -f $process.ExitCode, $watch.Elapsed.TotalSeconds)
    if ($process.ExitCode -ne 0) {
        throw "インストールに失敗しました。ログ: $log"
    }

    Write-Host '==> 中身の確認'
    $present = 'xampp-control.exe', 'apache\bin\httpd.exe', 'php\php8ts.dll', 'php\php.ini', 'mysql\bin\mysqld.exe', 'mysql\data',
        'phpMyAdmin\index.php', 'src\xampp-control-panel', 'licenses', 'mysql_start.bat', 'unins000.exe'
    $missing = @($present | Where-Object { -not (Test-Path -LiteralPath (Join-Path $InstallDir $_)) })
    Add-Result '入るべきもの' ($missing.Count -eq 0) $(if ($missing.Count) { 'ありません: ' + ($missing -join ', ') } else { "$($present.Count) 項目すべてあり" })

    $absent = 'perl', 'tomcat', 'FileZillaFTP', 'MercuryMail', 'webalizer', 'sendmail', 'catalina_start.bat', 'filezilla_start.bat',
        'mercury_start.bat', 'php\glib-2.dll', 'php\libenchant2.dll', 'php\ext\php_enchant.dll', 'php\lib\enchant'
    $found = @($absent | Where-Object { Test-Path -LiteralPath (Join-Path $InstallDir $_) })
    Add-Result '入らないもの' ($found.Count -eq 0) $(if ($found.Count) { '残っています: ' + ($found -join ', ') } else { "$($absent.Count) 項目すべてなし" })

    $phpVersion = (Get-Item -LiteralPath (Join-Path $InstallDir 'php\php8ts.dll')).VersionInfo.ProductVersion.Trim()
    $apacheVersion = ((Get-Item -LiteralPath (Join-Path $InstallDir 'apache\bin\httpd.exe')).VersionInfo.FileVersion -split ' ')[0]
    Add-Result 'バージョン' (($phpVersion -eq $ExpectedVersion) -and ($apacheVersion -eq $ExpectedApacheVersion)) "PHP $phpVersion、Apache $apacheVersion"

    $slash = $InstallDir -replace '\\', '/'
    $relocated = (Select-String -LiteralPath (Join-Path $InstallDir 'apache\conf\extra\httpd-xampp.conf') -SimpleMatch "$slash/php/php8ts.dll" -Quiet) -and
        (Select-String -LiteralPath (Join-Path $InstallDir 'php\php.ini') -SimpleMatch "$InstallDir\php\ext" -Quiet) -and
        (Select-String -LiteralPath (Join-Path $InstallDir 'mysql\bin\my.ini') -SimpleMatch "$slash/mysql/data" -Quiet)
    Add-Result '設定ファイルのパスの書き換え' $relocated $(if ($relocated) { 'httpd-xampp.conf、php.ini、my.ini がインストール先を指している' } else { 'インストール先を指していません' })

    $cert = Join-Path $InstallDir 'apache\conf\ssl.crt\server.crt'
    $key = Join-Path $InstallDir 'apache\conf\ssl.key\server.key'
    $certOk = $false
    $certDetail = '証明書がありません'
    if ((Test-Path -LiteralPath $cert) -and (Test-Path -LiteralPath $key)) {
        $text = (Invoke-Native (Join-Path $InstallDir 'apache\bin\openssl.exe') @('x509', '-in', $cert, '-noout', '-text', '-subject')).Output
        $bits = 0
        if ($text -match 'Public-Key:\s*\((\d+)') {
            $bits = [int]$Matches[1]
        }
        $stageKey = Join-Path $repoRoot 'work\stage\xampp\apache\conf\ssl.key\server.key'
        $unique = -not (Test-Path -LiteralPath $stageKey) -or -not (Test-SameFile $key $stageKey)
        $certOk = ($bits -ge 2048) -and ($text -match 'CN\s*=\s*localhost') -and $unique
        $certDetail = 'RSA {0} ビット、CN=localhost: {1}、ビルド時の鍵と別: {2}' -f $bits, ($text -match 'CN\s*=\s*localhost'), $unique
    }
    Add-Result 'HTTPS 用の証明書' $certOk $certDetail
    Add-Result 'アンインストール情報の登録' (Test-Path -LiteralPath $UninstallKey) $UninstallKey

    Write-Host '==> tests\smoke-test.ps1 -XamppDir'
    $smoke = Invoke-Native 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'smoke-test.ps1'), '-XamppDir', $InstallDir)
    $smoke.Output -split "`n" | Where-Object { $_ -match '^\s+\[(OK|NG)\]' } | ForEach-Object { Write-Host "  $_" }
    $summary = @($smoke.Output -split "`n" | Where-Object { $_ -match '項目' } | Select-Object -Last 1)
    Add-Result 'Apache を起動しての確認' ($smoke.ExitCode -eq 0) ([string]($summary -join ''))

    Write-Host '==> アンインストール'
    $removed = Invoke-Uninstall $InstallDir
    $leftover = @('xampp-control.exe', 'php\php8ts.dll', 'apache\bin\httpd.exe', 'apache\conf\ssl.key\server.key' | Where-Object { Test-Path -LiteralPath (Join-Path $InstallDir $_) })
    $dataKept = Test-Path -LiteralPath (Join-Path $InstallDir 'mysql\data')
    Add-Result 'アンインストール' ($removed -and $leftover.Count -eq 0 -and -not (Test-Path -LiteralPath $UninstallKey)) $(if ($leftover.Count) { '残っています: ' + ($leftover -join ', ') } else { 'インストールしたファイルとアンインストール情報が消えた' })
    Add-Result 'MySQL のデータは残す' $dataKept 'mysql\data'
} catch {
    Add-Result '実行' $false $_.Exception.Message
}

if (-not $Keep -and (Test-Path -LiteralPath $InstallDir)) {
    if (Test-Path -LiteralPath (Join-Path $InstallDir 'unins000.exe')) {
        Invoke-Uninstall $InstallDir | Out-Null
    }
    Remove-Item -LiteralPath (Split-Path -Parent $InstallDir) -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($results | Where-Object { $_.Result -ne 'OK' })
Write-Host ''
if ($failed.Count -eq 0) {
    Write-Host "すべての確認に通りました（$($results.Count) 項目）。" -ForegroundColor Green
    exit 0
}
Write-Host "$($failed.Count) 項目で問題がありました。" -ForegroundColor Red
exit 1
