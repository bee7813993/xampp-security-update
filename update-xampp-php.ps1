<#
.SYNOPSIS
    XAMPP for Windows の PHP を、PHP2Shell（CVE-2026-109618 / CVE-2026-109619）を修正した公式の PHP 8.2.35 に入れ替えます。

.DESCRIPTION
    php.net が配布している公式の Windows 版 PHP（スレッドセーフ版、x64）を用意して SHA-256 を照合し、
    XAMPP の php フォルダに上書きします。php.ini や PEAR など、XAMPP 独自のファイルはそのまま残ります。

    XAMPP は、Apache から PHP の拡張を読み込めるよう、拡張が使う DLL の一部（ICU、libssh2 など）を
    apache\bin にもコピーしています。このコピーを新しい PHP のものに更新し、新しい PHP で増えた依存 DLL
    （PHP 8.2.35 の curl 拡張が使う brotlidec.dll など）を apache\bin に追加します。

    あわせて、XAMPP に同梱の古いものを 2 つ更新します。
      - PEAR の Archive_Tar（php\pear）を 1.6.0 にする。XAMPP 8.2.12 の 1.4.0 には CVE-2020-36193 などの脆弱性がある
      - PHP が外部サイトの証明書の検証に使う CA バンドル（apache\bin\curl-ca-bundle.crt）を、curl.se の新しいものにする。
        XAMPP の元のものから変わっている（自分で CA を足した）場合は置き換えない

      1. XAMPP のフォルダと、いまの PHP のバージョンを確認する
      2. Apache や PHP が動いていないことを確認する
      3. 公式の zip などを用意して SHA-256 を照合する
      4. php フォルダをバックアップする（php_backup_<元のバージョン>_<日時>）
      5. 新しい PHP を上書きし、apache\bin の依存 DLL をそろえる
      6. Archive_Tar と CA バンドルを更新する
      7. php.ini の session.upload_progress.enabled を Off にする（-NoHarden で省略）
      8. php.exe と httpd.exe -t で起動できることを確認する

    PHP がすでに 8.2.35 の場合は、apache\bin に足りない依存 DLL の追加と、Archive_Tar・CA バンドルの更新だけを
    （必要なときに、php フォルダをバックアップしてから）行います。

.PARAMETER XamppDir
    XAMPP のフォルダ。省略すると C:\xampp を使い、なければ各ドライブ直下の \xampp を探します。

.PARAMETER PhpZip
    手元にある公式の zip。省略すると、このスクリプトと同じフォルダにある zip を使い、なければ php.net から取得します。

.PARAMETER DownloadDir
    ダウンロードした zip の置き場所。既定は %TEMP%\xampp-security-update です。

.PARAMETER NoHarden
    php.ini を変更しません。

.PARAMETER Restore
    いちばん新しいバックアップに戻します（apache\bin で更新・追加した DLL と CA バンドルも戻します）。

.PARAMETER Yes
    確認の問い合わせを省略します。

.PARAMETER Force
    PHP のバージョン系列が違う場合や、動作中のプロセスがある場合でも続行します。

.PARAMETER Staging
    XAMPP 一式の zip を組み立てるときに使います（build-package.ps1 から呼ばれます）。
    バックアップ、動作中のプロセスの確認、起動の確認を行いません。

.PARAMETER PassThru
    結果をオブジェクトで返します。

.EXAMPLE
    .\update-xampp-php.ps1

.EXAMPLE
    .\update-xampp-php.ps1 -XamppDir D:\xampp

.EXAMPLE
    .\update-xampp-php.ps1 -Restore
#>
[CmdletBinding()]
param(
    [string]$XamppDir,
    [string]$PhpZip,
    [string]$DownloadDir = (Join-Path ([IO.Path]::GetTempPath()) 'xampp-security-update'),
    [switch]$NoHarden,
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

# 入れ替え先の PHP。SHA-256 は php.net の releases.json で公開されている値。
$Release = @{
    Version = '8.2.35'
    File    = 'php-8.2.35-Win32-vs16-x64.zip'
    Sha256  = 'cfa6000be835931961e40740bd3b51111700061d6655ddbfe5a2125807947457'
    Urls    = @(
        'https://downloads.php.net/~windows/releases/php-8.2.35-Win32-vs16-x64.zip'
        'https://downloads.php.net/~windows/releases/archives/php-8.2.35-Win32-vs16-x64.zip'
    )
    Fixes   = 'CVE-2026-109618, CVE-2026-109619'
}
$VcRedistUrl = 'https://aka.ms/vc14/vc_redist.x64.exe'
# バックアップの中で、apache\bin から退避したファイルと追加した DLL の一覧を置くフォルダ
$ApacheBackupName = '_apache_bin'

# XAMPP の PEAR（php\pear。PHP の include_path に入っている）の Archive_Tar。SHA-256 は pear.php.net の配布物から求めた値
# （中の Tar.php は GitHub の pear/Archive_Tar のタグ 1.6.0 と同じで、配布物の package.xml の MD5 とも一致する）。
$ArchiveTar = @{
    Version = '1.6.0'
    Date    = '2025-07-19'
    Time    = '14:50:47'
    File    = 'Archive_Tar-1.6.0.tgz'
    Sha256  = 'F856095F64BB3FFA44F870202FFCA8F4E6ECEEF3CB74674F12BE3362FAAFA7D3'
    Urls    = @('https://download.pear.php.net/package/Archive_Tar-1.6.0.tgz')
}
# php.ini の curl.cainfo と openssl.cafile が指す CA バンドル。curl.se が Mozilla のデータから作っているもので、
# SHA-256 は curl.se が公開している値。Original は XAMPP 8.2.12 に同梱の 2022-04-26 版の SHA-256（これだけを置き換える）。
$CaBundle = @{
    Version  = '2026-10-20'
    File     = 'cacert-2026-10-20.pem'
    Sha256   = '796F1389BFEA13C0ED78F663B765BAAFF54A508E5483786BD6ECE73C5E3E3CBE'
    Urls     = @('https://curl.se/ca/cacert-2026-10-20.pem')
    Name     = 'curl-ca-bundle.crt'
    Original = '08DF40E8F528ED283B0E480BA4BCDBFDD2FDCF695A7ADA1668243072D80F8B6F'
}
# PEAR の登録情報（php\pear\.registry\*.reg。PHP の serialize 形式）のバージョン、日時、ファイルの MD5 を書き換える PHP のコード
$RegistryHelper = @'
<?php
// php -n update-registry.php <registry> <version> <date> <time> <name in package> <installed file>
[, $reg, $version, $date, $time, $name, $file] = $argv;
$data = unserialize(file_get_contents($reg));
if (!is_array($data)) {
    fwrite(STDERR, "cannot read $reg\n");
    exit(1);
}
$md5 = md5_file($file);
$data['version'] = ['release' => $version, 'api' => $version];
$data['date'] = $date;
$data['time'] = $time;
if (isset($data['filelist'][$name])) {
    $data['filelist'][$name]['md5sum'] = $md5;
}
$list = $data['contents']['dir']['file'] ?? null;
if (is_array($list)) {
    $single = isset($list['attribs']);
    $items = $single ? [$list] : $list;
    foreach ($items as $i => $item) {
        if (($item['attribs']['name'] ?? '') === $name) {
            $items[$i]['attribs']['md5sum'] = $md5;
        }
    }
    $data['contents']['dir']['file'] = $single ? $items[0] : $items;
}
$data['_lastmodified'] = time();
file_put_contents($reg, serialize($data));
'@

function Get-PhpVersion([string]$PhpDir) {
    $dll = Join-Path $PhpDir 'php8ts.dll'
    if (-not (Test-Path -LiteralPath $dll)) {
        return $null
    }
    return (Get-Item -LiteralPath $dll).VersionInfo.ProductVersion.Trim()
}

# apache\bin にある DLL のうち、いまの php フォルダの同名の DLL と中身が同じもの（XAMPP が PHP からコピーしたもの）
function Get-PhpCopyInApacheBin([string]$Root) {
    $apacheBin = Join-Path $Root 'apache\bin'
    if (-not (Test-Path -LiteralPath $apacheBin)) {
        return
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $apacheBin -Filter '*.dll' -File)) {
        $source = Join-Path $Root "php\$($file.Name)"
        if ((Test-Path -LiteralPath $source) -and (Test-SameFile $file.FullName $source)) {
            $file.Name
        }
    }
}

# apache\bin の PHP 用 DLL を新しい PHP のものにし、足りない依存 DLL を追加する。
# $Backup を渡すと、上書きする DLL と追加した DLL の一覧をバックアップの中に残す。
function Sync-ApacheBin([string]$Root, [string[]]$Copies, [string]$Backup) {
    $phpDir = Join-Path $Root 'php'
    $apacheBin = Join-Path $Root 'apache\bin'
    $updated = @()
    $added = @()
    if (-not (Test-Path -LiteralPath $apacheBin)) {
        return [pscustomobject]@{ Updated = $updated; Added = $added; Unresolved = @() }
    }
    $saved = $null
    if ($Backup) {
        $saved = Join-Path $Backup $ApacheBackupName
        New-Item -ItemType Directory -Force -Path $saved | Out-Null
    }

    foreach ($name in $Copies) {
        $source = Join-Path $phpDir $name
        $target = Join-Path $apacheBin $name
        if (-not (Test-Path -LiteralPath $source) -or (Test-SameFile $source $target)) {
            continue
        }
        if ($saved) {
            Copy-Item -LiteralPath $target -Destination (Join-Path $saved $name) -Force
        }
        Copy-Item -LiteralPath $source -Destination $target -Force
        $updated += $name
    }

    $missing = Find-ApacheMissingDependency $Root
    foreach ($name in $missing.Add) {
        if ($saved) {
            Add-Content -LiteralPath (Join-Path $saved 'added.txt') -Value $name -Encoding Ascii
        }
        Copy-Item -LiteralPath (Join-Path $phpDir $name) -Destination (Join-Path $apacheBin $name) -Force
        $added += $name
    }
    return [pscustomobject]@{ Updated = $updated; Added = $added; Unresolved = $missing.Unresolved }
}

# Sync-ApacheBin で変えた apache\bin を、バックアップの中の記録から元に戻す。
# $ReplacedPhpDir（入れ替え後の php フォルダ）を渡すと、そこからコピーしたときのままの DLL だけを戻す。
# その後の Apache の更新で Apache のものに置き換わった DLL（brotlidec.dll など）は、そのまま残す。
function Restore-ApacheBin([string]$Root, [string]$Backup, [string]$ReplacedPhpDir) {
    $saved = Join-Path $Backup $ApacheBackupName
    if (-not (Test-Path -LiteralPath $saved)) {
        return
    }
    $apacheBin = Join-Path $Root 'apache\bin'
    $isOurCopy = {
        param([string]$Name)
        $target = Join-Path $apacheBin $Name
        if (-not (Test-Path -LiteralPath $target)) {
            return $false
        }
        if (-not $ReplacedPhpDir) {
            return $true
        }
        $copied = Join-Path $ReplacedPhpDir $Name
        return (Test-Path -LiteralPath $copied) -and (Test-SameFile $target $copied)
    }
    $added = Join-Path $saved 'added.txt'
    if (Test-Path -LiteralPath $added) {
        foreach ($name in [IO.File]::ReadAllLines($added)) {
            if ($name -and (& $isOurCopy $name)) {
                Remove-Item -LiteralPath (Join-Path $apacheBin $name) -Force
            }
        }
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $saved -Filter '*.dll' -File)) {
        if (& $isOurCopy $file.Name) {
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $apacheBin $file.Name) -Force
        }
    }
    # CA バンドルは、入れ替えたときのまま（そのあと変更されていない）なら戻す
    $savedCa = Join-Path $saved $CaBundle.Name
    $currentCa = Join-Path $apacheBin $CaBundle.Name
    if ((Test-Path -LiteralPath $savedCa) -and (Test-Path -LiteralPath $currentCa) -and
        (Get-FileHash -LiteralPath $currentCa -Algorithm SHA256).Hash -eq $CaBundle.Sha256) {
        Copy-Item -LiteralPath $savedCa -Destination $currentCa -Force
    }
    Remove-Item -LiteralPath $saved -Recurse -Force
}

function Write-ApacheBinChange($Sync) {
    foreach ($name in $Sync.Updated) {
        Write-Info "更新: apache\bin\$name"
    }
    foreach ($name in $Sync.Added) {
        Write-Info "追加: apache\bin\$name"
    }
    if (@($Sync.Updated).Count -eq 0 -and @($Sync.Added).Count -eq 0) {
        Write-Info '変更はありません。'
    }
}

# php.exe -m を実行し、警告やエラーの行を返す
function Get-PhpStartupMessage([string]$Root) {
    $phpDir = Join-Path $Root 'php'
    $ini = Join-Path $phpDir 'php.ini'
    $arguments = @('-m')
    if (Test-Path -LiteralPath $ini) {
        $arguments = @('-c', $ini, '-m')
    }
    # php.ini の \xampp\... という書き方は実行中のドライブが基準になるので、XAMPP のフォルダで実行する
    Push-Location -LiteralPath $Root
    try {
        $result = Invoke-Native (Join-Path $phpDir 'php.exe') $arguments
    } finally {
        Pop-Location
    }
    $messages = @($result.Output -split "`n" | Where-Object { $_ -match '(?i)\b(warning|error|deprecated)\b' } | ForEach-Object { $_.Trim() })
    if ($result.ExitCode -ne 0) {
        $messages += "php.exe -m の終了コード: $($result.ExitCode)"
    }
    return $messages
}

# php.ini に session.upload_progress.enabled = Off を入れる。変更したら $true を返す。
function Set-UploadProgressOff([string]$IniPath) {
    # 文字コードを崩さないよう、1 バイトを 1 文字として扱う Latin-1 で読み書きする
    $encoding = [Text.Encoding]::GetEncoding(28591)
    $text = [IO.File]::ReadAllText($IniPath, $encoding)
    $newline = "`n"
    if ($text.Contains("`r`n")) {
        $newline = "`r`n"
    }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.AddRange([string[]]($text -split "`r?`n"))

    $active = -1
    $commented = -1
    $value = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*session\.upload_progress\.enabled\s*=\s*(.*?)\s*$') {
            $active = $i
            $value = $Matches[1]
        } elseif ($lines[$i] -match '^\s*;\s*session\.upload_progress\.enabled\s*=') {
            $commented = $i
        }
    }
    if ($active -ge 0 -and $value -match '^"?(?i:off|0|false|no|none)?"?$') {
        return $false
    }

    $note = '; Added by update-xampp-php.ps1: mitigation for CVE-2026-109619 (PHP default is On)'
    $setting = 'session.upload_progress.enabled = Off'
    if ($active -ge 0) {
        $lines[$active] = $setting
        $lines.Insert($active, $note)
    } elseif ($commented -ge 0) {
        $lines.InsertRange($commented + 1, [string[]]@($note, $setting))
    } else {
        $at = $lines.Count
        if ($at -gt 0 -and $lines[$at - 1] -eq '') {
            $at--
        }
        $lines.InsertRange($at, [string[]]@('[Session]', $note, $setting))
    }
    [IO.File]::WriteAllText($IniPath, ($lines -join $newline), $encoding)
    return $true
}

# php\pear の Archive_Tar のバージョン（PEAR の登録情報から読む）。入っていなければ $null
function Get-ArchiveTarVersion([string]$PhpDir) {
    $reg = Join-Path $PhpDir 'pear\.registry\archive_tar.reg'
    if (-not (Test-Path -LiteralPath (Join-Path $PhpDir 'pear\Archive\Tar.php')) -or -not (Test-Path -LiteralPath $reg)) {
        return $null
    }
    if ([IO.File]::ReadAllText($reg) -match 's:7:"version";a:2:\{s:7:"release";s:\d+:"([^"]+)"') {
        return $Matches[1]
    }
    return $null
}

# Archive_Tar を $Tgz（pear.php.net の配布物）の Tar.php に入れ替え、PEAR の登録情報のバージョンと MD5 を書き換える
function Update-ArchiveTar([string]$PhpDir, [string]$Tgz) {
    $work = Join-Path ([IO.Path]::GetTempPath()) ('xampp-archive-tar-' + [guid]::NewGuid().ToString('N'))
    try {
        Expand-ZipFile $Tgz $work
        $source = Join-Path $work "Archive_Tar-$($ArchiveTar.Version)\Archive\Tar.php"
        if (-not (Test-Path -LiteralPath $source)) {
            throw "$($ArchiveTar.File) の中身が想定と違います。"
        }
        $target = Join-Path $PhpDir 'pear\Archive\Tar.php'
        Copy-Item -LiteralPath $source -Destination $target -Force
        $helper = Join-Path $work 'update-registry.php'
        Set-Content -LiteralPath $helper -Encoding Ascii -Value $RegistryHelper
        $result = Invoke-Native (Join-Path $PhpDir 'php.exe') @('-n', $helper, (Join-Path $PhpDir 'pear\.registry\archive_tar.reg'),
            $ArchiveTar.Version, $ArchiveTar.Date, $ArchiveTar.Time, 'Archive/Tar.php', $target)
        if ($result.ExitCode -ne 0) {
            throw "PEAR の登録情報を書き換えられませんでした: $($result.Output.Trim())"
        }
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# CA バンドルの状態。current（新しいもの）、original（XAMPP の元のもの）、custom（変更されている）、$null（ない）
function Get-CaBundleState([string]$Root) {
    $path = Join-Path $Root "apache\bin\$($CaBundle.Name)"
    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if ($hash -eq $CaBundle.Sha256) {
        return 'current'
    }
    if ($hash -eq $CaBundle.Original) {
        return 'original'
    }
    return 'custom'
}

# CA バンドルを $Pem にする。$Backup を渡すと、元のものをバックアップの中の apache\bin の退避先に残す。
function Update-CaBundle([string]$Root, [string]$Pem, [string]$Backup) {
    $target = Join-Path $Root "apache\bin\$($CaBundle.Name)"
    if ($Backup) {
        $saved = Join-Path $Backup $ApacheBackupName
        New-Item -ItemType Directory -Force -Path $saved | Out-Null
        Copy-Item -LiteralPath $target -Destination (Join-Path $saved $CaBundle.Name) -Force
    }
    Copy-Item -LiteralPath $Pem -Destination $target -Force
}

# Archive_Tar と CA バンドルのうち、更新が必要なもの
function Get-ExtraNeed([string]$Root) {
    $from = Get-ArchiveTarVersion (Join-Path $Root 'php')
    $version = ConvertTo-Version $from
    $state = Get-CaBundleState $Root
    if ($state -eq 'custom') {
        Write-Note "apache\bin\$($CaBundle.Name) が XAMPP の元のものから変わっているため、CA バンドルは置き換えません。"
    }
    return [pscustomobject]@{
        ArchiveTarFrom = $(if ($version -and $version -lt [version]$ArchiveTar.Version) { $from } else { $null })
        CaBundle       = ($state -eq 'original')
    }
}

# 更新が必要な Archive_Tar と CA バンドルの配布物を用意する。取得できなかったものは、
# 組み立て中（-Staging）でなければ注意を出して飛ばす（あとでもう一度実行すると更新する）。
function Save-ExtraFile($Need) {
    $files = [pscustomobject]@{ ArchiveTar = $null; ArchiveTarFrom = $Need.ArchiveTarFrom; CaBundle = $null }
    if (-not $Need.ArchiveTarFrom -and -not $Need.CaBundle) {
        return $files
    }
    Write-Step 'PEAR の Archive_Tar と CA バンドルを用意'
    $hint = 'を入手し、このスクリプトと同じフォルダに置いてから、もう一度実行してください。'
    if ($Need.ArchiveTarFrom) {
        try {
            $files.ArchiveTar = Get-ReleaseFile $null $ArchiveTar $DownloadDir "PEAR の Archive_Tar を取得できなかったため、更新しません。$($ArchiveTar.File) $hint"
            Write-Info "SHA-256 一致: $($files.ArchiveTar)"
        } catch {
            if ($Staging) {
                throw
            }
            Write-Note $_.Exception.Message
        }
    }
    if ($Need.CaBundle) {
        try {
            $files.CaBundle = Get-ReleaseFile $null $CaBundle $DownloadDir "CA バンドルを取得できなかったため、更新しません。$($CaBundle.File) $hint"
            Write-Info "SHA-256 一致: $($files.CaBundle)"
        } catch {
            if ($Staging) {
                throw
            }
            Write-Note $_.Exception.Message
        }
    }
    return $files
}

function Install-ExtraUpdate([string]$Root, $Files, [string]$Backup) {
    $phpDir = Join-Path $Root 'php'
    if ($Files.ArchiveTar) {
        Write-Step "PEAR の Archive_Tar を $($ArchiveTar.Version) に更新"
        Update-ArchiveTar $phpDir $Files.ArchiveTar
        Write-Info "Archive_Tar: $($Files.ArchiveTarFrom) -> $(Get-ArchiveTarVersion $phpDir)"
    }
    if ($Files.CaBundle) {
        Write-Step "CA バンドルを $($CaBundle.Version) 版に更新"
        Update-CaBundle $Root $Files.CaBundle $Backup
        Write-Info "apache\bin\$($CaBundle.Name)"
    }
}

# PHP がすでに新しい場合は、apache\bin に足りない依存 DLL の追加と、Archive_Tar・CA バンドルの更新だけを行う
function Invoke-Repair([string]$Root, [string]$Current) {
    Write-Host ''
    Write-Host "PHP はすでに $Current です。" -ForegroundColor Green
    $phpDir = Join-Path $Root 'php'
    $missing = Find-ApacheMissingDependency $Root
    foreach ($item in $missing.Unresolved) {
        Write-Note "見つからない DLL: $item"
    }
    $need = Get-ExtraNeed $Root
    if (@($missing.Add).Count -eq 0 -and -not $need.ArchiveTarFrom -and -not $need.CaBundle) {
        Write-Host '更新の必要はありません。'
        return $null
    }
    if (@($missing.Add).Count -gt 0) {
        Write-Note ('Apache から読み込めない DLL があります: {0}' -f ($missing.Add -join ', '))
    }
    if ($need.ArchiveTarFrom) {
        Write-Note "PEAR の Archive_Tar が $($need.ArchiveTarFrom) です（$($ArchiveTar.Version) で脆弱性が修正されています）。"
    }
    if ($need.CaBundle) {
        Write-Note "CA バンドル（apache\bin\$($CaBundle.Name)）が、XAMPP 8.2.12 に同梱の古いものです。"
    }
    if (-not $Staging) {
        Write-Step 'Apache / PHP が止まっていることを確認'
        Assert-NotRunning $Root $Force
        Confirm-Continue '足りない DLL を補い、Archive_Tar と CA バンドルを更新します。よろしいですか？' $Yes
    }
    $files = Save-ExtraFile $need
    if (@($missing.Add).Count -eq 0 -and -not $files.ArchiveTar -and -not $files.CaBundle) {
        Write-Host ''
        Write-Host '更新できるものはありませんでした。' -ForegroundColor Yellow
        return $null
    }

    $backup = $null
    if (-not $Staging) {
        Write-Step 'php フォルダをバックアップ'
        $backup = Join-Path $Root ('php_backup_{0}_{1}' -f $Current, (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Invoke-Robocopy $phpDir $backup @('/E', '/COPY:DAT', '/DCOPY:T')
        Write-Info $backup
    }
    $sync = $null
    try {
        if (@($missing.Add).Count -gt 0) {
            Write-Step 'Apache から読み込む DLL をそろえる（apache\bin）'
            $sync = Sync-ApacheBin $Root @() $backup
            Write-ApacheBinChange $sync
        }
        Install-ExtraUpdate $Root $files $backup
    } catch {
        if ($backup) {
            Write-Note '途中で失敗したため、バックアップから元に戻します。'
            Restore-ApacheBin $Root $backup
            Invoke-Robocopy $backup $phpDir @('/MIR', '/COPY:DAT')
        }
        throw
    }

    Write-Host ''
    Write-Host '完了しました。XAMPP コントロールパネルで Apache を Start してください。' -ForegroundColor Green
    if ($backup) {
        Write-Host "バックアップ: $backup（動作に問題がなければ削除してかまいません）"
    }
    return [pscustomobject]@{
        XamppDir      = $Root
        FromVersion   = $Current
        ToVersion     = $Current
        PhpZip        = $null
        Backup        = $backup
        ApacheUpdated = @()
        ApacheAdded   = @(if ($sync) { $sync.Added })
        Hardened      = @()
        ArchiveTar    = $(if ($files.ArchiveTar) { $ArchiveTar.Version } else { $null })
        CaBundle      = $(if ($files.CaBundle) { $CaBundle.Version } else { $null })
        Problems      = @(if ($sync) { $sync.Unresolved | ForEach-Object { "見つからない DLL: $_" } })
    }
}

function Invoke-Update {
    $root = Resolve-XamppDir $XamppDir
    $phpDir = Join-Path $root 'php'
    Write-Step "XAMPP: $root"

    $current = Get-PhpVersion $phpDir
    if (-not $current) {
        throw "スレッドセーフ版の PHP（php\php8ts.dll）が見つかりません。XAMPP のフォルダか確認してください: $root"
    }
    Write-Info "いまの PHP      : $current"
    Write-Info "入れ替え後の PHP: $($Release.Version)（$($Release.Fixes) を修正）"

    $currentVersion = ConvertTo-Version $current
    $targetVersion = [version]$Release.Version
    if (-not $currentVersion -or $currentVersion.Major -ne $targetVersion.Major -or $currentVersion.Minor -ne $targetVersion.Minor) {
        if (-not $Force) {
            throw ('この更新は PHP {0}.{1} 系の XAMPP（XAMPP 8.2.x）用です。いまの PHP は {2} です。XAMPP 8.0 / 8.1 系は、XAMPP 8.2.12 に移行してから適用してください。' -f $targetVersion.Major, $targetVersion.Minor, $current)
        }
        Write-Note 'バージョン系列が違いますが、-Force が指定されているため続行します。'
    } elseif ($currentVersion -ge $targetVersion -and -not $Force) {
        return Invoke-Repair $root $current
    }

    $apacheBefore = $null
    $baseline = @()
    if (-not $Staging) {
        Write-Step 'Apache / PHP が止まっていることを確認'
        Assert-NotRunning $root $Force
        Confirm-Continue "$phpDir を PHP $($Release.Version) に入れ替えます。よろしいですか？" $Yes
    }

    Write-Step '公式の PHP を用意'
    $zip = Get-ReleaseFile $PhpZip $Release $DownloadDir "公式の PHP を取得できませんでした。php.net から $($Release.File) を入手し、-PhpZip で指定してください。"
    Write-Info "SHA-256 一致: $zip"
    $extra = Save-ExtraFile (Get-ExtraNeed $root)

    $backup = $null
    $sync = $null
    $extract = Join-Path ([IO.Path]::GetTempPath()) ('xampp-php-' + [guid]::NewGuid().ToString('N'))
    try {
        Expand-ZipFile $zip $extract
        $newVersion = Get-PhpVersion $extract
        if ($newVersion -ne $Release.Version -or -not (Test-Path -LiteralPath (Join-Path $extract 'php8apache2_4.dll'))) {
            throw "zip の中身が想定と違います（php8ts.dll のバージョン: $newVersion）。"
        }

        if (-not $Staging) {
            # 更新前から出ている警告を、更新で増えたものと区別するために控えておく
            $baseline = @(Get-PhpStartupMessage $root)
            $apacheBefore = Test-ApacheConfig $root

            Write-Step 'php フォルダをバックアップ'
            $backup = Join-Path $root ('php_backup_{0}_{1}' -f $current, (Get-Date -Format 'yyyyMMdd-HHmmss'))
            Invoke-Robocopy $phpDir $backup @('/E', '/COPY:DAT', '/DCOPY:T')
            Write-Info $backup
        }

        # 上書きする前に、XAMPP が apache\bin にコピーしている PHP の DLL を調べておく
        $copies = @(Get-PhpCopyInApacheBin $root)
        try {
            Write-Step "PHP $($Release.Version) を上書き"
            Invoke-Robocopy $extract $phpDir @('/E', '/IS', '/IT', '/COPY:DAT')
            Write-Info "php8ts.dll: $(Get-PhpVersion $phpDir)"

            Write-Step 'Apache から読み込む DLL をそろえる（apache\bin）'
            $sync = Sync-ApacheBin $root $copies $backup
            Write-ApacheBinChange $sync

            Install-ExtraUpdate $root $extra $backup
        } catch {
            if ($backup) {
                Write-Note '途中で失敗したため、バックアップから元に戻します。'
                Restore-ApacheBin $root $backup
                Invoke-Robocopy $backup $phpDir @('/MIR', '/COPY:DAT')
            }
            throw
        }
    } finally {
        Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue
    }

    $hardened = @()
    if (-not $NoHarden) {
        Write-Step 'php.ini の追加対策（session.upload_progress.enabled = Off）'
        foreach ($ini in @((Join-Path $phpDir 'php.ini'), (Join-Path $root 'apache\bin\php.ini'))) {
            if (-not (Test-Path -LiteralPath $ini)) {
                continue
            }
            if (Set-UploadProgressOff $ini) {
                Write-Info "変更しました: $ini"
                $hardened += $ini
            } else {
                Write-Info "設定済みです: $ini"
            }
        }
    }

    $problems = @($sync.Unresolved | ForEach-Object { "Apache から読み込めない DLL: $_" })
    if (-not $Staging) {
        Write-Step '起動の確認'
        $cli = Invoke-Native (Join-Path $phpDir 'php.exe') @('-n', '-r', 'echo PHP_VERSION;')
        if ($cli.ExitCode -eq 0 -and $cli.Output.Trim() -eq $Release.Version) {
            Write-Info "php.exe: $($cli.Output.Trim())"
        } else {
            $problems += "php.exe が正しく起動しません: $($cli.Output.Trim())"
            if ($cli.Output -match '(?i)vcruntime') {
                $problems += "Microsoft Visual C++ 再頒布可能パッケージ（x64）の最新版をインストールしてください: $VcRedistUrl"
            }
        }

        $added = @(Get-PhpStartupMessage $root | Where-Object { $baseline -notcontains $_ })
        if ($added.Count -eq 0) {
            Write-Info 'php.exe -m: 新しい警告はありません'
        } else {
            $problems += @($added | ForEach-Object { "php.exe -m: $_" })
        }

        $apacheAfter = Test-ApacheConfig $root
        if ($apacheAfter) {
            if ($apacheAfter.Ok) {
                Write-Info 'httpd.exe -t: Syntax OK'
            } elseif ($apacheBefore -and -not $apacheBefore.Ok) {
                Write-Note "httpd.exe -t は更新前からエラーでした: $($apacheAfter.Output)"
            } else {
                $problems += "httpd.exe -t: $($apacheAfter.Output)"
            }
        }
    }

    Write-Host ''
    if ($problems.Count -gt 0) {
        Write-Host 'PHP の入れ替えは終わりましたが、確認で問題が見つかりました:' -ForegroundColor Yellow
        foreach ($problem in $problems) {
            Write-Host "  - $problem" -ForegroundColor Yellow
        }
        if (-not $Staging) {
            Write-Host '元に戻すには、update-xampp-php.bat -Restore を実行してください。'
        }
    } else {
        Write-Host "完了しました: PHP $current -> $($Release.Version)" -ForegroundColor Green
    }
    if (-not $Staging) {
        Write-Host 'XAMPP コントロールパネルで Apache を Start してください。'
        Write-Host "バックアップ: $backup（動作に問題がなければ削除してかまいません）"
    }

    return [pscustomobject]@{
        XamppDir      = $root
        FromVersion   = $current
        ToVersion     = $Release.Version
        PhpZip        = $zip
        Backup        = $backup
        ApacheUpdated = $sync.Updated
        ApacheAdded   = $sync.Added
        Hardened      = $hardened
        ArchiveTar    = $(if ($extra.ArchiveTar) { $ArchiveTar.Version } else { $null })
        CaBundle      = $(if ($extra.CaBundle) { $CaBundle.Version } else { $null })
        Problems      = $problems
    }
}

function Invoke-Restore {
    $root = Resolve-XamppDir $XamppDir
    $phpDir = Join-Path $root 'php'
    $backups = @(Get-BackupFolder $root 'php_backup_')
    if ($backups.Count -eq 0) {
        Write-Host ''
        Write-Host "PHP のバックアップ（php_backup_*）がないため、何もしません: $root"
        return
    }
    $backup = $backups[0]
    $backupVersion = Get-PhpVersion $backup.FullName
    if (-not $backupVersion) {
        throw "バックアップに php8ts.dll がありません: $($backup.FullName)"
    }

    Write-Step "バックアップから元に戻す: $($backup.FullName)"
    Assert-NotRunning $root $Force
    Confirm-Continue "$phpDir を $($backup.Name)（PHP $backupVersion）に戻します。よろしいですか？" $Yes

    $aside = 'php_replaced_' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    if (Test-Path -LiteralPath $phpDir) {
        Rename-Item -LiteralPath $phpDir -NewName $aside
    }
    try {
        Rename-Item -LiteralPath $backup.FullName -NewName 'php'
    } catch {
        Rename-Item -LiteralPath (Join-Path $root $aside) -NewName 'php'
        throw
    }
    # バックアップだったフォルダ（いまの php フォルダ）に残した記録から、apache\bin も戻す
    Restore-ApacheBin $root $phpDir (Join-Path $root $aside)

    Write-Host ''
    Write-Host "元に戻しました: PHP $(Get-PhpVersion $phpDir)" -ForegroundColor Green
    Write-Host "入れ替え後の php フォルダは $aside として残しています。"
    Write-OlderBackupNote $root 'php_backup_' 'update-xampp-php.bat'
    Write-Host 'XAMPP コントロールパネルで Apache を Start してください。'
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
