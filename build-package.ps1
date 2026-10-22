<#
.SYNOPSIS
    公式の XAMPP 8.2.12 の PHP と Apache を更新した、XAMPP 一式の zip を作ります（手元で使う用）。

.DESCRIPTION
    1. SourceForge の XAMPP 公式プロジェクトから xampp-windows-x64-8.2.12-0-VS16.zip を取得して照合する
    2. 作業フォルダ（work\stage）に展開し、update-xampp-php.ps1 と update-xampp-apache.ps1 を -Staging で適用する
    3. dist フォルダに zip と、その SHA-256 を書き出す

    出来上がる zip には XAMPP、MariaDB、phpMyAdmin などの GPL のソフトウェアが含まれます。
    人に配る場合は、対応するソースコードの提供など、各ライセンスの条件を満たす必要があります。
    work\stage は build-installer.ps1 がインストーラーを作るときにも使います。

.PARAMETER NoHarden
    php.ini を変更しません（session.upload_progress.enabled は PHP 既定の On のまま）。

.PARAMETER PhpOnly
    Apache は更新しません。

.EXAMPLE
    .\build-package.ps1
#>
[CmdletBinding()]
param(
    [string]$DownloadDir,
    [string]$WorkDir,
    [string]$OutDir,
    [switch]$NoHarden,
    [switch]$PhpOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'xampp-update-common.ps1')

# Windows PowerShell 5.1 を -File で起動すると param の既定値では $PSScriptRoot が空なので、ここで決める
if (-not $DownloadDir) { $DownloadDir = Join-Path $PSScriptRoot 'downloads' }
if (-not $WorkDir) { $WorkDir = Join-Path $PSScriptRoot 'work' }
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'dist' }

$Xampp = @{
    Version = '8.2.12-0'
    File    = 'xampp-windows-x64-8.2.12-0-VS16.zip'
    Urls    = @('https://downloads.sourceforge.net/project/xampp/XAMPP%20Windows/8.2.12/xampp-windows-x64-8.2.12-0-VS16.zip')
    # SourceForge が公開しているのは MD5（1ff00bb5ee8466b4bbb8cb1c4ca51dfa）だけなので、
    # MD5 の一致を確かめたファイルから求めた SHA-256 で照合する
    Sha256  = '5f925bdb474d1daec61461ce76649b2464e446f95342254248369a3043066108'
}
$tar = Join-Path (Get-SystemDir) 'tar.exe'

try {
    Write-Step "XAMPP $($Xampp.Version) を用意"
    New-Item -ItemType Directory -Force -Path $DownloadDir, $WorkDir, $OutDir | Out-Null
    $zip = Join-Path $DownloadDir $Xampp.File
    Save-VerifiedFile $Xampp.Urls $zip $Xampp.Sha256
    Write-Info "SHA-256 一致: $zip"

    Write-Step '作業フォルダに展開'
    $stage = Join-Path $WorkDir 'stage'
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    $result = Invoke-Native $tar @('-xf', $zip, '-C', $stage)
    if ($result.ExitCode -ne 0) {
        throw "展開に失敗しました: $($result.Output)"
    }
    $root = Join-Path $stage 'xampp'

    $options = @{ XamppDir = $root; DownloadDir = $DownloadDir; Staging = $true; Yes = $true; PassThru = $true }
    $phpOptions = $options.Clone()
    if ($NoHarden) {
        $phpOptions.NoHarden = $true
    }
    $php = & (Join-Path $PSScriptRoot 'update-xampp-php.ps1') @phpOptions
    if ($LASTEXITCODE -ne 0 -or -not $php) {
        throw 'PHP の入れ替えに失敗しました。'
    }
    $name = 'xampp-windows-x64-{0}-VS16-php{1}' -f $Xampp.Version, $php.ToVersion
    if (-not $PhpOnly) {
        $apache = & (Join-Path $PSScriptRoot 'update-xampp-apache.ps1') @options
        if ($LASTEXITCODE -ne 0 -or -not $apache) {
            throw 'Apache の入れ替えに失敗しました。'
        }
        $name += "-apache$($apache.ToVersion)"
    }

    Write-Step 'zip を作成'
    $out = Join-Path $OutDir "$name.zip"
    if (Test-Path -LiteralPath $out) {
        Remove-Item -LiteralPath $out -Force
    }
    $result = Invoke-Native $tar @('-a', '-cf', $out, '-C', $stage, 'xampp')
    if ($result.ExitCode -ne 0) {
        throw "zip の作成に失敗しました: $($result.Output)"
    }
    $hash = (Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath "$out.sha256" -Value "$hash *$name.zip" -Encoding Ascii

    Write-Host ''
    Write-Host "完成: $out" -ForegroundColor Green
    Write-Host "SHA-256: $hash"
    Write-Host 'GPL のソフトウェアを含むため、人に配る場合は README の「ライセンス」を確認してください。'
    exit 0
} catch {
    Write-Host ''
    Write-Host "[エラー] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
