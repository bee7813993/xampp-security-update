<#
.SYNOPSIS
    PHP と Apache を更新した XAMPP のインストーラーを、Inno Setup で作ります。

.DESCRIPTION
    build-package.ps1 で作った作業フォルダ（work\stage\xampp）を次の部品に分け、installer\xampp-setup.iss を
    コンパイルして dist フォルダにセットアップ（.exe）と、その SHA-256 を書き出します。

      core        Apache、PHP、XAMPP コントロールパネルなど（必須）
      mariadb     MariaDB（mysql フォルダと mysql_start.bat / mysql_stop.bat）
      phpmyadmin  phpMyAdmin

    次のものは入れません。
      - サポートが終わっている、または古い部品: Perl、Tomcat、FileZilla Server、Mercury Mail、Webalizer、fake sendmail
      - PHP に同梱の LGPL の DLL（enchant 拡張と、それが使う glib）
      - HTTPS 用の証明書と秘密鍵（インストールのときに、その PC だけの鍵で作る）

.PARAMETER Iscc
    Inno Setup の ISCC.exe。省略すると、よくあるインストール先から探します。

.EXAMPLE
    .\build-package.ps1
    .\build-installer.ps1
#>
[CmdletBinding()]
param(
    [string]$Iscc,
    [string]$WorkDir,
    [string]$OutDir
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'xampp-update-common.ps1')

# Windows PowerShell 5.1 を -File で起動すると param の既定値では $PSScriptRoot が空なので、ここで決める
if (-not $WorkDir) { $WorkDir = Join-Path $PSScriptRoot 'work' }
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'dist' }

# core に入れないもの（XAMPP のフォルダからの相対パス）
$ExcludedDirs = @(
    'perl', 'tomcat', 'FileZillaFTP', 'MercuryMail', 'webalizer', 'sendmail'  # サポート切れ・古い部品
    'mysql', 'phpMyAdmin'                                                     # 別の部品にする
    'php\lib\enchant'                                                         # LGPL（enchant 拡張用）
)
$ExcludedFiles = @(
    'catalina_service.bat', 'catalina_start.bat', 'catalina_stop.bat'
    'filezilla_setup.bat', 'filezilla_start.bat', 'filezilla_stop.bat'
    'mercury_start.bat', 'mercury_stop.bat'
    'mysql_start.bat', 'mysql_stop.bat'
    'php\glib-2.dll', 'php\gmodule-2.dll', 'php\gobject-2.dll', 'php\libenchant2.dll', 'php\ext\php_enchant.dll'
    'apache\conf\ssl.crt\server.crt', 'apache\conf\ssl.key\server.key'
)

function Find-Iscc {
    if ($Iscc) {
        return (Resolve-Path -LiteralPath $Iscc).Path
    }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 7\ISCC.exe')
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
        (Join-Path $env:ProgramFiles 'Inno Setup 7\ISCC.exe')
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe')
    )
    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path) {
            return $path
        }
    }
    throw 'Inno Setup の ISCC.exe が見つかりません。-Iscc で指定してください。'
}

function Get-VersionText([string]$Path, [int]$Parts) {
    $version = ((Get-Item -LiteralPath $Path).VersionInfo.FileVersion -split ' ')[0].Trim()
    return ($version -split '\.')[0..($Parts - 1)] -join '.'
}

try {
    $stage = Join-Path $WorkDir 'stage\xampp'
    if (-not (Test-Path -LiteralPath (Join-Path $stage 'xampp-control.exe'))) {
        throw "build-package.ps1 を先に実行してください（$stage がありません）。"
    }
    $versions = @{
        Php        = (Get-Item -LiteralPath (Join-Path $stage 'php\php8ts.dll')).VersionInfo.ProductVersion.Trim()
        Apache     = Get-VersionText (Join-Path $stage 'apache\bin\httpd.exe') 3
        MariaDb    = Get-VersionText (Join-Path $stage 'mysql\bin\mysqld.exe') 3
        PhpMyAdmin = 'unknown'
    }
    $versionFile = Join-Path $stage 'phpMyAdmin\libraries\classes\Version.php'
    if ((Test-Path -LiteralPath $versionFile) -and ((Get-Content -LiteralPath $versionFile -Raw) -match "VERSION\s*=\s*'([\d.]+)'")) {
        $versions.PhpMyAdmin = $Matches[1]
    }
    Write-Step ('PHP {0}、Apache {1}、MariaDB {2}、phpMyAdmin {3}' -f $versions.Php, $versions.Apache, $versions.MariaDb, $versions.PhpMyAdmin)

    Write-Step '部品ごとに分ける'
    $parts = Join-Path $WorkDir 'installer'
    if (Test-Path -LiteralPath $parts) {
        Remove-Item -LiteralPath $parts -Recurse -Force
    }
    $core = Join-Path $parts 'core'
    $options = @('/E', '/COPY:DAT', '/XD') + @($ExcludedDirs | ForEach-Object { Join-Path $stage $_ }) +
        @('/XF') + @($ExcludedFiles | ForEach-Object { Join-Path $stage $_ })
    Invoke-Robocopy $stage $core $options
    $leftover = @(@($ExcludedDirs) + @($ExcludedFiles) | Where-Object { Test-Path -LiteralPath (Join-Path $core $_) })
    if ($leftover.Count -gt 0) {
        throw "除外したはずのファイルが残っています: $($leftover -join ', ')"
    }
    Invoke-Robocopy (Join-Path $stage 'mysql') (Join-Path $parts 'mariadb\mysql') @('/E', '/COPY:DAT')
    foreach ($name in 'mysql_start.bat', 'mysql_stop.bat') {
        Copy-Item -LiteralPath (Join-Path $stage $name) -Destination (Join-Path $parts 'mariadb') -Force
    }
    Invoke-Robocopy (Join-Path $stage 'phpMyAdmin') (Join-Path $parts 'phpmyadmin\phpMyAdmin') @('/E', '/COPY:DAT')
    foreach ($part in 'core', 'mariadb', 'phpmyadmin') {
        $files = @(Get-ChildItem -LiteralPath (Join-Path $parts $part) -File -Recurse)
        Write-Info ('{0,-11} {1,6} ファイル、{2,6:N0} MB' -f $part, $files.Count, (($files | Measure-Object Length -Sum).Sum / 1MB))
    }

    Write-Step 'Inno Setup でコンパイル（数分かかります）'
    $iscc = Find-Iscc
    Write-Info $iscc
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $name = 'xampp-8.2.12-php{0}-apache{1}-setup' -f $versions.Php, $versions.Apache
    $defines = @(
        "/DStageDir=$parts"
        "/DAppVersion=8.2.12-php$($versions.Php)-apache$($versions.Apache)"
        "/DPhpVersion=$($versions.Php)"
        "/DApacheVersion=$($versions.Apache)"
        "/DMariaDbVersion=$($versions.MariaDb)"
        "/DPhpMyAdminVersion=$($versions.PhpMyAdmin)"
        "/DFileVersion=$(Get-Date -Format 'yyyy.M.d').0"
        "/DOutputDir=$OutDir"
        "/DOutputBaseFilename=$name"
    )
    $result = Invoke-Native $iscc ($defines + @('/Q', (Join-Path $PSScriptRoot 'installer\xampp-setup.iss')))
    if ($result.ExitCode -ne 0) {
        throw "コンパイルに失敗しました。`n$($result.Output)"
    }
    $out = Join-Path $OutDir "$name.exe"
    $hash = (Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath "$out.sha256" -Value "$hash *$name.exe" -Encoding Ascii

    Write-Host ''
    Write-Host ('完成: {0}（{1:N0} MB）' -f $out, ((Get-Item -LiteralPath $out).Length / 1MB)) -ForegroundColor Green
    Write-Host "SHA-256: $hash"
    exit 0
} catch {
    Write-Host ''
    Write-Host "[エラー] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
