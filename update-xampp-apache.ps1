<#
.SYNOPSIS
    XAMPP for Windows の Apache を、Apache Lounge の Apache 2.4.69（Win64、VS18 ビルド、OpenSSL 3.5.9）に入れ替えます。

.DESCRIPTION
    XAMPP 8.2.12 の Apache 2.4.58 は、2.4.69 までに修正された 72 件の脆弱性の影響を受け、同梱の OpenSSL 3.1.3 も
    サポートが終わっています。Apache Lounge の Windows 版を用意して SHA-256 を照合し、apache フォルダの bin、modules、
    include、lib とライセンス文書だけを上書きします。設定（conf）と、XAMPP が apache\bin に置いている PHP 用の DLL は
    そのまま残ります。

      1. XAMPP のフォルダと、いまの Apache のバージョンを確認する
      2. Microsoft Visual C++ 再頒布可能パッケージ（14.51 以上）が入っていることを確認する
      3. Apache や PHP が動いていないことを確認する
      4. Apache Lounge の zip を用意して SHA-256 を照合する
      5. 上書きするファイルを apache_backup_<元のバージョン>_<日時> に退避してから上書きする
      6. HTTPS の証明書が弱い（RSA 鍵が 2048 ビット未満、または SHA-1 / MD5 署名）場合は作り直す
         （XAMPP 付属の証明書は 1024 ビット鍵のため、OpenSSL 3.5 では読み込めず Apache が起動しなくなる）
      7. httpd.exe -v と httpd.exe -t で確認する

    Apache がすでに 2.4.69 の場合は、証明書が弱ければ作り直しだけを行います。

.PARAMETER XamppDir
    XAMPP のフォルダ。省略すると C:\xampp を使い、なければ各ドライブ直下の \xampp を探します。

.PARAMETER ApacheZip
    手元にある Apache Lounge の zip。省略すると、このスクリプトと同じフォルダにある zip を使い、なければダウンロードします。

.PARAMETER DownloadDir
    ダウンロードした zip の置き場所。既定は %TEMP%\xampp-security-update です。

.PARAMETER KeepCertificate
    証明書が弱くても作り直しません（その場合 HTTPS の設定が読み込めず、Apache が起動しません）。

.PARAMETER Restore
    いちばん新しいバックアップに戻します。

.PARAMETER Yes
    確認の問い合わせを省略します。

.PARAMETER Force
    Apache のバージョン系列が違う場合や、動作中のプロセスがある場合でも続行します。

.PARAMETER Staging
    XAMPP 一式の zip を組み立てるときに使います（build-package.ps1 から呼ばれます）。
    バックアップ、動作中のプロセスの確認、起動の確認を行いません。

.PARAMETER PassThru
    結果をオブジェクトで返します。

.EXAMPLE
    .\update-xampp-apache.ps1

.EXAMPLE
    .\update-xampp-apache.ps1 -Restore
#>
[CmdletBinding()]
param(
    [string]$XamppDir,
    [string]$ApacheZip,
    [string]$DownloadDir = (Join-Path ([IO.Path]::GetTempPath()) 'xampp-security-update'),
    [switch]$KeepCertificate,
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

# 入れ替え先の Apache。SHA-256 は Apache Lounge が zip と一緒に公開している値。
# Apache Lounge は最新版しか置かないため、同じ zip をこのリポジトリのリリースにも置いている。
$Release = @{
    Version   = '2.4.69'
    File      = 'httpd-2.4.69-261002-Win64-VS18.zip'
    Sha256    = 'CA272E0B75ABAD78B1E4029A0753B20FF2232D2D857E8EEBEEA5D469C5776977'
    Urls      = @(
        'https://www.apachelounge.com/download/VS18/binaries/httpd-2.4.69-261002-Win64-VS18.zip'
        'https://github.com/bee7813993/xampp-security-update/releases/download/mirror-httpd-2.4.69-261002/httpd-2.4.69-261002-Win64-VS18.zip'
    )
    OpenSsl   = '3.5.9'
    VcRuntime = '14.51.36247'
}
$VcRedistUrl = 'https://aka.ms/vc14/vc_redist.x64.exe'
# Apache Lounge の zip から上書きする範囲（conf、htdocs、logs などは XAMPP のものを残す）
$OverlayDirs = 'bin', 'modules', 'include', 'lib'
$OverlayFiles = 'ABOUT_APACHE.txt', 'CHANGES.txt', 'INSTALL.txt', 'LICENSE.txt', 'NOTICE.txt'

function Get-ApacheVersion([string]$ApacheDir) {
    $exe = Join-Path $ApacheDir 'bin\httpd.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        return $null
    }
    return ((Get-Item -LiteralPath $exe).VersionInfo.FileVersion -split ' ')[0].Trim()
}

function ConvertTo-Version([string]$Text) {
    $version = $null
    if ([version]::TryParse($Text, [ref]$version)) {
        return $version
    }
    return $null
}

# Apache Lounge の VS18 ビルドに必要な Visual C++ ランタイムが入っているか
function Test-VcRuntime {
    $required = [version]$Release.VcRuntime
    foreach ($dll in 'vcruntime140.dll', 'msvcp140.dll') {
        $path = Join-Path (Get-SystemDir) $dll
        if (-not (Test-Path -LiteralPath $path)) {
            return "$dll がありません"
        }
        $version = ConvertTo-Version (((Get-Item -LiteralPath $path).VersionInfo.FileVersion -split ' ')[0])
        if (-not $version -or $version -lt $required) {
            return "$dll が $version です"
        }
    }
    return $null
}

function Get-ReleaseZip {
    if ($ApacheZip) {
        $path = (Resolve-Path -LiteralPath $ApacheZip).Path
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
        throw "Apache を取得できませんでした。$($Release.File) を入手し、-ApacheZip で指定してください。"
    }
    return $dest
}

# Apache Lounge の zip のうち、apache フォルダに上書きするファイル（apache フォルダからの相対パス）
function Get-OverlayItem([string]$Source) {
    foreach ($dir in $OverlayDirs) {
        $path = Join-Path $Source $dir
        if (Test-Path -LiteralPath $path) {
            foreach ($file in @(Get-ChildItem -LiteralPath $path -File -Recurse)) {
                $file.FullName.Substring($Source.Length + 1)
            }
        }
    }
    foreach ($name in $OverlayFiles) {
        if (Test-Path -LiteralPath (Join-Path $Source $name)) {
            $name
        }
    }
}

# $Items を $Source から $Target に上書きする。$Backup を渡すと、上書き前のファイルを同じ相対パスで退避し、
# 新しく増えたファイルは added.txt に記録する。PHP と Apache の両方が使う DLL（brotlidec.dll など）も
# Apache のものにそろえる（Apache の中では、PHP も apache\bin の DLL を使うため）。
function Copy-Overlay([string]$Source, [string]$Target, [string[]]$Items, [string]$Backup) {
    $updated = @()
    $added = @()
    foreach ($item in $Items) {
        $from = Join-Path $Source $item
        $to = Join-Path $Target $item
        if (Test-Path -LiteralPath $to) {
            if (Test-SameFile $from $to) {
                continue
            }
            if ($Backup) {
                $saved = Join-Path $Backup $item
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $saved) | Out-Null
                Copy-Item -LiteralPath $to -Destination $saved -Force
            }
            Copy-Item -LiteralPath $from -Destination $to -Force
            $updated += $item
        } else {
            if ($Backup) {
                Add-Content -LiteralPath (Join-Path $Backup 'added.txt') -Value $item -Encoding Ascii
            }
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to) | Out-Null
            Copy-Item -LiteralPath $from -Destination $to -Force
            $added += $item
        }
    }
    return [pscustomobject]@{ Updated = $updated; Added = $added }
}

# Copy-Overlay と証明書の作り直しで変えたファイルを、バックアップから元に戻す
function Restore-Overlay([string]$ApacheDir, [string]$Backup) {
    $addedList = Join-Path $Backup 'added.txt'
    if (Test-Path -LiteralPath $addedList) {
        foreach ($item in [IO.File]::ReadAllLines($addedList)) {
            if ($item) {
                Remove-Item -LiteralPath (Join-Path $ApacheDir $item) -Force -ErrorAction SilentlyContinue
            }
        }
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $Backup -File -Recurse)) {
        $item = $file.FullName.Substring($Backup.Length + 1)
        if ($item -eq 'added.txt') {
            continue
        }
        $to = Join-Path $ApacheDir $item
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to) | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $to -Force
    }
}

# httpd-ssl.conf で使われている証明書と秘密鍵（httpd.conf から読み込まれていない場合は $null）
function Get-SslCertificatePair([string]$ApacheDir) {
    $main = Join-Path $ApacheDir 'conf\httpd.conf'
    $conf = Join-Path $ApacheDir 'conf\extra\httpd-ssl.conf'
    if (-not (Test-Path -LiteralPath $conf) -or -not (Select-String -LiteralPath $main -Pattern '^\s*Include\s+"?conf/extra/httpd-ssl\.conf"?\s*$' -Quiet)) {
        return $null
    }
    $cert = $null
    $key = $null
    foreach ($line in [IO.File]::ReadAllLines($conf)) {
        if ($line -match '^\s*SSLCertificateFile\s+"?([^"]+?)"?\s*$') {
            $cert = $Matches[1]
        } elseif ($line -match '^\s*SSLCertificateKeyFile\s+"?([^"]+?)"?\s*$') {
            $key = $Matches[1]
        }
    }
    if (-not $cert -or -not $key) {
        return $null
    }
    $resolve = {
        param([string]$Path)
        $Path = $Path -replace '/', '\'
        if ($Path -match '^[A-Za-z]:') {
            return $Path
        }
        if ($Path.StartsWith('\')) {
            # \xampp\... はドライブ名のない書き方なので、XAMPP と同じドライブとみなす
            return (Split-Path -Qualifier $ApacheDir) + $Path
        }
        return Join-Path $ApacheDir $Path
    }
    return [pscustomobject]@{ Cert = (& $resolve $cert); Key = (& $resolve $key) }
}

function Get-CertificateInfo([string]$OpenSsl, [string]$CertPath) {
    $result = Invoke-Native $OpenSsl @('x509', '-in', $CertPath, '-noout', '-text')
    if ($result.ExitCode -ne 0) {
        return $null
    }
    $bits = 0
    if ($result.Output -match 'Public-Key:\s*\((\d+)\s*bit\)') {
        $bits = [int]$Matches[1]
    }
    $keyType = ''
    if ($result.Output -match 'Public Key Algorithm:\s*(\S+)') {
        $keyType = $Matches[1]
    }
    $signature = ''
    if ($result.Output -match 'Signature Algorithm:\s*(\S+)') {
        $signature = $Matches[1]
    }
    # OpenSSL 3.2 以降の既定のセキュリティレベル 2 では、2048 ビット未満の RSA 鍵などは読み込めない
    $weak = ($keyType -match '(?i)rsa' -and $bits -lt 2048) -or ($keyType -match '(?i)ec' -and $bits -lt 224) -or ($signature -match '(?i)md5|sha1With')
    return [pscustomobject]@{ Bits = $bits; KeyType = $keyType; Signature = $signature; Weak = $weak }
}

# localhost 用の自己署名証明書（RSA 2048 ビット、SHA-256、10 年）を、この PC だけの鍵で作り直す
function New-LocalhostCertificate([string]$OpenSsl, [string]$CertPath, [string]$KeyPath) {
    $config = Join-Path ([IO.Path]::GetTempPath()) ('xampp-openssl-' + [guid]::NewGuid().ToString('N') + '.cnf')
    Set-Content -LiteralPath $config -Encoding Ascii -Value @(
        '[req]'
        'distinguished_name = dn'
        'x509_extensions = v3'
        'prompt = no'
        '[dn]'
        'CN = localhost'
        '[v3]'
        'basicConstraints = critical, CA:FALSE'
        'keyUsage = critical, digitalSignature, keyEncipherment'
        'extendedKeyUsage = serverAuth'
        'subjectAltName = DNS:localhost, IP:127.0.0.1'
        'subjectKeyIdentifier = hash'
    )
    $newCert = "$CertPath.new"
    $newKey = "$KeyPath.new"
    try {
        $result = Invoke-Native $OpenSsl @('req', '-x509', '-newkey', 'rsa:2048', '-sha256', '-days', '3650', '-nodes',
            '-config', $config, '-keyout', $newKey, '-out', $newCert)
        if ($result.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $newCert) -or -not (Test-Path -LiteralPath $newKey)) {
            throw "証明書を作れませんでした: $($result.Output.Trim())"
        }
        Move-Item -LiteralPath $newCert -Destination $CertPath -Force
        Move-Item -LiteralPath $newKey -Destination $KeyPath -Force
    } finally {
        Remove-Item -LiteralPath $config, $newCert, $newKey -Force -ErrorAction SilentlyContinue
    }
}

# 証明書が弱ければ作り直す。作り直したら証明書のパスを返す。
function Update-WeakCertificate([string]$ApacheDir, [string]$Backup, [System.Collections.ArrayList]$Problems) {
    $pair = Get-SslCertificatePair $ApacheDir
    if (-not $pair) {
        Write-Info 'HTTPS の設定（httpd-ssl.conf）は使われていません。'
        return $null
    }
    $openSsl = Join-Path $ApacheDir 'bin\openssl.exe'
    $info = $null
    if ((Test-Path -LiteralPath $pair.Cert) -and (Test-Path -LiteralPath $openSsl)) {
        $info = Get-CertificateInfo $openSsl $pair.Cert
    }
    if (-not $info) {
        [void]$Problems.Add("証明書を読み取れません: $($pair.Cert)")
        return $null
    }
    Write-Info ('{0}（{1} {2} ビット、{3}）' -f $pair.Cert, $info.KeyType, $info.Bits, $info.Signature)
    if (-not $info.Weak) {
        Write-Info '問題ありません。'
        return $null
    }
    if ($KeepCertificate) {
        [void]$Problems.Add("証明書が弱いため、OpenSSL $($Release.OpenSsl) の Apache では HTTPS の設定を読み込めず起動しません: $($pair.Cert)")
        return $null
    }
    $prefix = $ApacheDir + '\'
    if (-not $pair.Cert.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or -not $pair.Key.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        [void]$Problems.Add("証明書が弱く、apache フォルダの外にあるため作り直していません。2048 ビット以上の鍵で作り直してください: $($pair.Cert)")
        return $null
    }
    if ($Backup) {
        foreach ($path in @($pair.Cert, $pair.Key)) {
            $saved = Join-Path $Backup $path.Substring($prefix.Length)
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $saved) | Out-Null
            Copy-Item -LiteralPath $path -Destination $saved -Force
        }
    }
    New-LocalhostCertificate $openSsl $pair.Cert $pair.Key
    $after = Get-CertificateInfo $openSsl $pair.Cert
    Write-Info ('作り直しました（{0} {1} ビット、{2}、CN=localhost）' -f $after.KeyType, $after.Bits, $after.Signature)
    return $pair.Cert
}

function Invoke-CertificateRepair([string]$Root, [string]$Current) {
    Write-Host ''
    Write-Host "Apache はすでに $Current です。" -ForegroundColor Green
    $apacheDir = Join-Path $Root 'apache'
    $pair = Get-SslCertificatePair $apacheDir
    $openSsl = Join-Path $apacheDir 'bin\openssl.exe'
    if (-not $pair -or -not (Test-Path -LiteralPath $pair.Cert) -or -not (Test-Path -LiteralPath $openSsl)) {
        Write-Host '更新の必要はありません。'
        return $null
    }
    $info = Get-CertificateInfo $openSsl $pair.Cert
    if (-not $info -or -not $info.Weak) {
        Write-Host '更新の必要はありません。'
        return $null
    }
    Write-Note "HTTPS の証明書が弱いため、Apache が起動しない可能性があります: $($pair.Cert)"
    if (-not $Staging) {
        Write-Step 'Apache / PHP が止まっていることを確認'
        Assert-NotRunning $Root $Force
        Confirm-Continue 'localhost 用の証明書を作り直します。よろしいですか？' $Yes
    }
    $backup = $null
    if (-not $Staging) {
        $backup = Join-Path $Root ('apache_backup_{0}_{1}' -f $Current, (Get-Date -Format 'yyyyMMdd-HHmmss'))
        New-Item -ItemType Directory -Force -Path $backup | Out-Null
    }
    $problems = New-Object System.Collections.ArrayList
    Write-Step 'HTTPS の証明書を確認'
    $cert = Update-WeakCertificate $apacheDir $backup $problems
    return [pscustomobject]@{
        XamppDir    = $Root
        FromVersion = $Current
        ToVersion   = $Current
        Backup      = $backup
        Updated     = @()
        Added       = @()
        Certificate = $cert
        Problems    = @($problems)
    }
}

function Invoke-Update {
    $root = Resolve-XamppDir $XamppDir
    $apacheDir = Join-Path $root 'apache'
    Write-Step "XAMPP: $root"

    $current = Get-ApacheVersion $apacheDir
    if (-not $current) {
        throw "Apache（apache\bin\httpd.exe）が見つかりません。XAMPP のフォルダか確認してください: $root"
    }
    Write-Info "いまの Apache      : $current"
    Write-Info "入れ替え後の Apache: $($Release.Version)（Apache Lounge、OpenSSL $($Release.OpenSsl)）"

    $currentVersion = ConvertTo-Version $current
    $targetVersion = [version]$Release.Version
    if (-not $currentVersion -or $currentVersion.Major -ne $targetVersion.Major -or $currentVersion.Minor -ne $targetVersion.Minor) {
        if (-not $Force) {
            throw "この更新は Apache 2.4 系の XAMPP 用です。いまの Apache は $current です。"
        }
        Write-Note 'バージョン系列が違いますが、-Force が指定されているため続行します。'
    } elseif ($currentVersion -ge $targetVersion -and -not $Force) {
        return Invoke-CertificateRepair $root $current
    }

    if (-not $Staging) {
        Write-Step 'Visual C++ 再頒布可能パッケージを確認'
        $runtime = Test-VcRuntime
        if ($runtime) {
            throw "Apache $($Release.Version) には Microsoft Visual C++ 再頒布可能パッケージ（x64）$($Release.VcRuntime) 以上が必要です（$runtime）。次の URL から最新版をインストールしてから、もう一度実行してください: $VcRedistUrl"
        }
        Write-Info "問題ありません（$($Release.VcRuntime) 以上）。"

        Write-Step 'Apache / PHP が止まっていることを確認'
        Assert-NotRunning $root $Force
        Confirm-Continue "$apacheDir を Apache $($Release.Version) に入れ替えます。よろしいですか？" $Yes
    }

    Write-Step 'Apache Lounge の Apache を用意'
    $zip = Get-ReleaseZip
    Write-Info "SHA-256 一致: $zip"

    $apacheBefore = $null
    $backup = $null
    $overlay = $null
    $certificate = $null
    $problems = New-Object System.Collections.ArrayList
    $extract = Join-Path ([IO.Path]::GetTempPath()) ('xampp-apache-' + [guid]::NewGuid().ToString('N'))
    try {
        Expand-Archive -LiteralPath $zip -DestinationPath $extract
        $source = Join-Path $extract 'Apache24'
        $newVersion = Get-ApacheVersion $source
        if ($newVersion -ne $Release.Version) {
            throw "zip の中身が想定と違います（httpd.exe のバージョン: $newVersion）。"
        }

        if (-not $Staging) {
            $apacheBefore = Test-ApacheConfig $root
            $backup = Join-Path $root ('apache_backup_{0}_{1}' -f $current, (Get-Date -Format 'yyyyMMdd-HHmmss'))
            New-Item -ItemType Directory -Force -Path $backup | Out-Null
        }
        try {
            Write-Step "Apache $($Release.Version) を上書き"
            $overlay = Copy-Overlay $source $apacheDir @(Get-OverlayItem $source) $backup
            Write-Info ('更新 {0} ファイル、追加 {1} ファイル' -f @($overlay.Updated).Count, @($overlay.Added).Count)
            Write-Info "httpd.exe: $(Get-ApacheVersion $apacheDir)"

            Write-Step 'HTTPS の証明書を確認'
            $certificate = Update-WeakCertificate $apacheDir $backup $problems
        } catch {
            if ($backup) {
                Write-Note '途中で失敗したため、バックアップから元に戻します。'
                Restore-Overlay $apacheDir $backup
            }
            throw
        }
    } finally {
        Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (-not $Staging) {
        Write-Step '起動の確認'
        Push-Location -LiteralPath $root
        try {
            $version = Invoke-Native (Join-Path $apacheDir 'bin\httpd.exe') @('-v')
            $openSslVersion = Invoke-Native (Join-Path $apacheDir 'bin\openssl.exe') @('version')
        } finally {
            Pop-Location
        }
        if ($version.Output -match "Apache/$([regex]::Escape($Release.Version))\b") {
            Write-Info "httpd.exe -v: Apache/$($Release.Version)"
        } else {
            [void]$problems.Add("httpd.exe が正しく起動しません: $($version.Output.Trim())")
            if ($version.Output -match '(?i)vcruntime|msvcp|0xc000007b|side-by-side') {
                [void]$problems.Add("Microsoft Visual C++ 再頒布可能パッケージ（x64）の最新版をインストールしてください: $VcRedistUrl")
            }
        }
        Write-Info "openssl.exe: $($openSslVersion.Output.Trim())"

        $apacheAfter = Test-ApacheConfig $root
        if ($apacheAfter -and $apacheAfter.Ok) {
            Write-Info 'httpd.exe -t: Syntax OK'
        } elseif ($apacheBefore -and -not $apacheBefore.Ok) {
            Write-Note "httpd.exe -t は更新前からエラーでした: $($apacheAfter.Output)"
        } elseif ($apacheAfter) {
            [void]$problems.Add("httpd.exe -t: $($apacheAfter.Output)")
        }

        # Apache の DLL が変わっても、PHP と有効な拡張を Apache から読み込めるか
        $missing = Find-ApacheMissingDependency $root
        foreach ($name in $missing.Add) {
            [void]$problems.Add("PHP 用の DLL が apache\bin にありません: $name（update-xampp-php.bat を実行すると補えます）")
        }
        foreach ($item in $missing.Unresolved) {
            [void]$problems.Add("見つからない DLL: $item")
        }
        if (@($missing.Add).Count -eq 0 -and @($missing.Unresolved).Count -eq 0) {
            Write-Info 'PHP と有効な拡張が使う DLL: すべて見つかります'
        }
    }

    Write-Host ''
    if ($problems.Count -gt 0) {
        Write-Host 'Apache の入れ替えは終わりましたが、確認で問題が見つかりました:' -ForegroundColor Yellow
        foreach ($problem in $problems) {
            Write-Host "  - $problem" -ForegroundColor Yellow
        }
        if (-not $Staging) {
            Write-Host '元に戻すには、update-xampp-apache.bat -Restore を実行してください。'
        }
    } else {
        Write-Host "完了しました: Apache $current -> $($Release.Version)" -ForegroundColor Green
    }
    if (-not $Staging) {
        Write-Host 'XAMPP コントロールパネルで Apache を Start してください。'
        if ($certificate) {
            Write-Host 'HTTPS の証明書を作り直したため、ブラウザーで https://localhost/ を開くと証明書の警告がもう一度表示されます。'
        }
        Write-Host "バックアップ: $backup（動作に問題がなければ削除してかまいません）"
    }

    return [pscustomobject]@{
        XamppDir    = $root
        FromVersion = $current
        ToVersion   = $Release.Version
        Backup      = $backup
        Updated     = $overlay.Updated
        Added       = $overlay.Added
        Certificate = $certificate
        Problems    = @($problems)
    }
}

function Invoke-Restore {
    $root = Resolve-XamppDir $XamppDir
    $apacheDir = Join-Path $root 'apache'
    $backups = @(Get-BackupFolder $root 'apache_backup_')
    if ($backups.Count -eq 0) {
        Write-Host ''
        Write-Host "Apache のバックアップ（apache_backup_*）がないため、何もしません: $root"
        return
    }
    $backup = $backups[0]

    Write-Step "バックアップから元に戻す: $($backup.FullName)"
    Assert-NotRunning $root $Force
    Confirm-Continue "$apacheDir を $($backup.Name) の状態に戻します。よろしいですか？" $Yes

    Restore-Overlay $apacheDir $backup.FullName
    Remove-Item -LiteralPath $backup.FullName -Recurse -Force

    Write-Host ''
    Write-Host "元に戻しました: Apache $(Get-ApacheVersion $apacheDir)" -ForegroundColor Green
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
