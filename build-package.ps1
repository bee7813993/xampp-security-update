<#
.SYNOPSIS
    公式の XAMPP 8.2.12 の PHP を修正版に入れ替えた、XAMPP 一式の zip を作ります（手元で使う用）。

.DESCRIPTION
    1. SourceForge の XAMPP 公式プロジェクトから xampp-windows-x64-8.2.12-0-VS16.zip を取得し、
       MD5（SourceForge の公開値）と SHA-256 を照合する
    2. 作業フォルダに展開し、update-xampp-php.ps1 -Staging で PHP を入れ替える
    3. dist フォルダに zip と、その SHA-256 を書き出す

    出来上がる zip には XAMPP、MariaDB、phpMyAdmin などの GPL のソフトウェアが含まれます。
    人に配る場合は、対応するソースコードの提供など、各ライセンスの条件を満たす必要があります。

.PARAMETER NoHarden
    php.ini を変更しません（session.upload_progress.enabled は PHP 既定の On のまま）。

.EXAMPLE
    .\build-package.ps1
#>
[CmdletBinding()]
param(
    [string]$DownloadDir,
    [string]$WorkDir,
    [string]$OutDir,
    [switch]$NoHarden
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Windows PowerShell 5.1 を -File で起動すると param の既定値では $PSScriptRoot が空なので、ここで決める
if (-not $DownloadDir) { $DownloadDir = Join-Path $PSScriptRoot 'downloads' }
if (-not $WorkDir) { $WorkDir = Join-Path $PSScriptRoot 'work' }
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'dist' }

$Xampp = @{
    Version = '8.2.12-0'
    File    = 'xampp-windows-x64-8.2.12-0-VS16.zip'
    Url     = 'https://downloads.sourceforge.net/project/xampp/XAMPP%20Windows/8.2.12/xampp-windows-x64-8.2.12-0-VS16.zip'
    # SourceForge が公開しているのは MD5 だけなので、MD5 の一致を確かめたファイルの SHA-256 もあわせて固定する
    Md5     = '1ff00bb5ee8466b4bbb8cb1c4ca51dfa'
    Sha256  = '5f925bdb474d1daec61461ce76649b2464e446f95342254248369a3043066108'
}
$tar = Join-Path $env:SystemRoot 'System32\tar.exe'
$curl = Join-Path $env:SystemRoot 'System32\curl.exe'

function Write-Step([string]$Message) {
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

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

function Test-XamppZip([string]$Path) {
    return ((Get-FileHash -LiteralPath $Path -Algorithm MD5).Hash -eq $Xampp.Md5) -and
        ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $Xampp.Sha256)
}

try {
    Write-Step "XAMPP $($Xampp.Version) を用意"
    New-Item -ItemType Directory -Force -Path $DownloadDir, $WorkDir, $OutDir | Out-Null
    $zip = Join-Path $DownloadDir $Xampp.File
    if (-not ((Test-Path -LiteralPath $zip) -and (Test-XamppZip $zip))) {
        Write-Host "    ダウンロード中: $($Xampp.Url)"
        $part = "$zip.part"
        $result = Invoke-Native $curl @('-fsSL', '--retry', '3', '-o', $part, $Xampp.Url)
        if ($result.ExitCode -ne 0) {
            throw "ダウンロードに失敗しました: $($result.Output)"
        }
        if (-not (Test-XamppZip $part)) {
            Remove-Item -LiteralPath $part -Force
            throw 'ダウンロードしたファイルのハッシュが公開値と一致しません。'
        }
        Move-Item -LiteralPath $part -Destination $zip -Force
    }
    Write-Host "    MD5 / SHA-256 一致: $zip"

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

    $updater = Join-Path $PSScriptRoot 'update-xampp-php.ps1'
    $options = @{ XamppDir = (Join-Path $stage 'xampp'); DownloadDir = $DownloadDir; Staging = $true; Yes = $true; PassThru = $true }
    if ($NoHarden) {
        $options.NoHarden = $true
    }
    $update = & $updater @options
    if ($LASTEXITCODE -ne 0 -or -not $update) {
        throw 'PHP の入れ替えに失敗しました。'
    }

    Write-Step 'zip を作成'
    $name = 'xampp-windows-x64-{0}-VS16-php{1}.zip' -f $Xampp.Version, $update.ToVersion
    $out = Join-Path $OutDir $name
    if (Test-Path -LiteralPath $out) {
        Remove-Item -LiteralPath $out -Force
    }
    $result = Invoke-Native $tar @('-a', '-cf', $out, '-C', $stage, 'xampp')
    if ($result.ExitCode -ne 0) {
        throw "zip の作成に失敗しました: $($result.Output)"
    }
    $hash = (Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath "$out.sha256" -Value "$hash *$name" -Encoding Ascii

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
