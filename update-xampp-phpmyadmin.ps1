<#
.SYNOPSIS
    XAMPP for Windows の phpMyAdmin 5.2.1 を、phpMyAdmin 5.2.3 に入れ替えます。

.DESCRIPTION
    phpMyAdmin 公式の配布物（all-languages の zip）を用意して SHA-256 を照合し、XAMPP の phpMyAdmin フォルダを
    新しいものに入れ替えます。設定（config.inc.php）は引き継ぎます。

      1. XAMPP のフォルダと、いまの phpMyAdmin のバージョンを確認する
      2. Apache が動いていないことを確認する
      3. phpMyAdmin の zip を用意して SHA-256 を照合する
      4. いまの phpMyAdmin フォルダの名前を phpMyAdmin_backup_<元のバージョン>_<日時> に変えて残し、
         新しい phpMyAdmin を置いて config.inc.php を引き継ぐ

    config.inc.php のほかに自分で追加したファイル（テーマなど）がある場合は、バックアップから写してください。

.PARAMETER XamppDir
    XAMPP のフォルダ。省略すると C:\xampp を使い、なければ各ドライブ直下の \xampp を探します。

.PARAMETER PhpMyAdminZip
    手元にある phpMyAdmin の zip。省略すると、このスクリプトと同じフォルダにある zip を使い、なければダウンロードします。

.PARAMETER DownloadDir
    ダウンロードした zip の置き場所。既定は %TEMP%\xampp-security-update です。

.PARAMETER Restore
    いちばん新しいバックアップに戻します。

.PARAMETER Yes
    確認の問い合わせを省略します。

.PARAMETER Force
    動作中のプロセスがある場合でも続行します。

.PARAMETER Staging
    XAMPP 一式の zip を組み立てるときに使います（build-package.ps1 から呼ばれます）。
    バックアップと動作中のプロセスの確認を行いません。

.PARAMETER PassThru
    結果をオブジェクトで返します。

.EXAMPLE
    .\update-xampp-phpmyadmin.ps1
#>
[CmdletBinding()]
param(
    [string]$XamppDir,
    [string]$PhpMyAdminZip,
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

# 入れ替え先の phpMyAdmin。SHA-256 は phpMyAdmin の公式サイト（files.phpmyadmin.net）で公開されている値。
$Release = @{
    Version = '5.2.3'
    File    = 'phpMyAdmin-5.2.3-all-languages.zip'
    Folder  = 'phpMyAdmin-5.2.3-all-languages'
    Sha256  = '2D2E13C735366D318425C78E4EE2CC8FC648D77FABA3DDEA2CD516E43885733F'
    Urls    = @('https://files.phpmyadmin.net/phpMyAdmin/5.2.3/phpMyAdmin-5.2.3-all-languages.zip')
}
# 新しい phpMyAdmin に引き継ぐファイル
$KeepFiles = @('config.inc.php')

function Get-PhpMyAdminVersion([string]$Dir) {
    $file = Join-Path $Dir 'libraries\classes\Version.php'
    if ((Test-Path -LiteralPath $file) -and ((Get-Content -LiteralPath $file -Raw) -match "VERSION\s*=\s*'([\d.]+)'")) {
        return $Matches[1]
    }
    return $null
}

function ConvertTo-Version([string]$Text) {
    $version = $null
    if ([version]::TryParse($Text, [ref]$version)) {
        return $version
    }
    return $null
}

function Get-ReleaseZip {
    if ($PhpMyAdminZip) {
        $path = (Resolve-Path -LiteralPath $PhpMyAdminZip).Path
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $Release.Sha256) {
            throw "SHA-256 が公開値と一致しません: $path"
        }
        return $path
    }
    $local = Join-Path $PSScriptRoot $Release.File
    if ((Test-Path -LiteralPath $local) -and (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash -eq $Release.Sha256) {
        return $local
    }
    $dest = Join-Path $DownloadDir $Release.File
    try {
        Save-VerifiedFile $Release.Urls $dest $Release.Sha256
    } catch {
        throw "phpMyAdmin を取得できませんでした。$($Release.File) を入手し、-PhpMyAdminZip で指定してください。"
    }
    return $dest
}

function Invoke-Update {
    $root = Resolve-XamppDir $XamppDir
    $pmaDir = Join-Path $root 'phpMyAdmin'
    Write-Step "XAMPP: $root"

    $current = Get-PhpMyAdminVersion $pmaDir
    if (-not $current) {
        Write-Host ''
        Write-Host 'phpMyAdmin が入っていないため、何もしません。' -ForegroundColor Green
        return $null
    }
    Write-Info "いまの phpMyAdmin      : $current"
    Write-Info "入れ替え後の phpMyAdmin: $($Release.Version)"
    $currentVersion = ConvertTo-Version $current
    if ($currentVersion -and $currentVersion -ge [version]$Release.Version -and -not $Force) {
        Write-Host ''
        Write-Host "phpMyAdmin はすでに $current です。更新の必要はありません。" -ForegroundColor Green
        return $null
    }

    if (-not $Staging) {
        Write-Step 'Apache が止まっていることを確認'
        Assert-NotRunning $root $Force
        Confirm-Continue "$pmaDir を phpMyAdmin $($Release.Version) に入れ替えます。よろしいですか？" $Yes
    }

    Write-Step 'phpMyAdmin を用意'
    $zip = Get-ReleaseZip
    Write-Info "SHA-256 一致: $zip"

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    # 入れ替えを名前の変更だけで済ませるため、XAMPP と同じドライブに展開する
    $extract = Join-Path $root "phpMyAdmin_new_$stamp"
    $backup = $null
    try {
        Expand-ZipFile $zip $extract
        $source = Join-Path $extract $Release.Folder
        if ((Get-PhpMyAdminVersion $source) -ne $Release.Version) {
            throw 'zip の中身が想定と違います。'
        }
        foreach ($name in $KeepFiles) {
            $file = Join-Path $pmaDir $name
            if (Test-Path -LiteralPath $file) {
                Copy-Item -LiteralPath $file -Destination (Join-Path $source $name) -Force
            }
        }

        Write-Step "phpMyAdmin $($Release.Version) に入れ替え"
        if ($Staging) {
            Remove-Item -LiteralPath $pmaDir -Recurse -Force
        } else {
            $backup = Join-Path $root ('phpMyAdmin_backup_{0}_{1}' -f $current, $stamp)
            Rename-Item -LiteralPath $pmaDir -NewName (Split-Path -Leaf $backup)
            Write-Info "元の phpMyAdmin: $backup"
        }
        try {
            Move-Item -LiteralPath $source -Destination $pmaDir
        } catch {
            if ($backup) {
                Rename-Item -LiteralPath $backup -NewName 'phpMyAdmin'
            }
            throw
        }
        Write-Info ('引き継いだファイル: {0}' -f ($KeepFiles -join ', '))
    } finally {
        Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue
    }

    $problems = @()
    if ((Get-PhpMyAdminVersion $pmaDir) -ne $Release.Version) {
        $problems += 'phpMyAdmin のバージョンが想定と違います。'
    }
    Write-Host ''
    if ($problems.Count -gt 0) {
        foreach ($problem in $problems) {
            Write-Host "  - $problem" -ForegroundColor Yellow
        }
    } else {
        Write-Host "完了しました: phpMyAdmin $current -> $($Release.Version)" -ForegroundColor Green
    }
    if (-not $Staging) {
        Write-Host 'XAMPP コントロールパネルで Apache を Start してください。'
        Write-Host "バックアップ: $backup（動作に問題がなければ削除してかまいません）"
    }

    return [pscustomobject]@{
        XamppDir    = $root
        FromVersion = $current
        ToVersion   = $Release.Version
        Backup      = $backup
        Problems    = $problems
    }
}

function Invoke-Restore {
    $root = Resolve-XamppDir $XamppDir
    $pmaDir = Join-Path $root 'phpMyAdmin'
    $backups = @(Get-BackupFolder $root 'phpMyAdmin_backup_')
    if ($backups.Count -eq 0) {
        Write-Host ''
        Write-Host "phpMyAdmin のバックアップ（phpMyAdmin_backup_*）がないため、何もしません: $root"
        return
    }
    $backup = $backups[0]

    Write-Step "バックアップから元に戻す: $($backup.FullName)"
    Assert-NotRunning $root $Force
    Confirm-Continue "$pmaDir を $($backup.Name)（phpMyAdmin $(Get-PhpMyAdminVersion $backup.FullName)）に戻します。よろしいですか？" $Yes

    $aside = 'phpMyAdmin_replaced_' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    if (Test-Path -LiteralPath $pmaDir) {
        Rename-Item -LiteralPath $pmaDir -NewName $aside
    }
    try {
        Rename-Item -LiteralPath $backup.FullName -NewName 'phpMyAdmin'
    } catch {
        Rename-Item -LiteralPath (Join-Path $root $aside) -NewName 'phpMyAdmin'
        throw
    }

    Write-Host ''
    Write-Host "元に戻しました: phpMyAdmin $(Get-PhpMyAdminVersion $pmaDir)" -ForegroundColor Green
    Write-Host "入れ替え後の phpMyAdmin フォルダは $aside として残しています。"
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
