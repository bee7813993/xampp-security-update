<#
.SYNOPSIS
    XAMPP for Windows の PHP、Apache、MariaDB、phpMyAdmin を、この順に更新します（入っていない部品は飛ばします）。

.DESCRIPTION
    部品ごとのスクリプト（update-xampp-php.ps1、update-xampp-apache.ps1、update-xampp-mariadb.ps1、
    update-xampp-phpmyadmin.ps1）を順に実行します。オプションは、それを受け付けるスクリプトにだけ渡します
    （たとえば -NoHarden は PHP、-KeepCertificate は Apache だけに渡します）。

    確認の問い合わせで N と答えた部品は飛ばして、次の部品に進みます。エラーで止まった部品があれば、
    残りの部品は実行せずに終わります。

    -Restore のときは、更新とは逆の順（phpMyAdmin、MariaDB、Apache、PHP）に戻します。PHP のあとに Apache を
    更新すると、PHP の更新で apache\bin に追加した DLL が Apache のバックアップに入るため、PHP を先に戻すと
    その DLL が残ってしまいます。

.EXAMPLE
    .\update-xampp.ps1

.EXAMPLE
    .\update-xampp.ps1 -XamppDir D:\xampp -NoHarden

.EXAMPLE
    .\update-xampp.ps1 -Restore
#>
[CmdletBinding()]
param(
    [string]$XamppDir,
    [string]$DownloadDir,
    [string]$PhpZip,
    [switch]$NoHarden,
    [string]$ApacheZip,
    [switch]$KeepCertificate,
    [string]$MariaDbZip,
    [string]$PhpMyAdminZip,
    [switch]$Restore,
    [switch]$Yes,
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Parts = @(
    [pscustomobject]@{ Name = 'php'; Label = 'PHP' }
    [pscustomobject]@{ Name = 'apache'; Label = 'Apache' }
    [pscustomobject]@{ Name = 'mariadb'; Label = 'MariaDB' }
    [pscustomobject]@{ Name = 'phpmyadmin'; Label = 'phpMyAdmin' }
)
if ($Restore) {
    [array]::Reverse($Parts)
}

$skipped = @()
for ($i = 0; $i -lt $Parts.Count; $i++) {
    $part = $Parts[$i]
    $script = Join-Path $PSScriptRoot "update-xampp-$($part.Name).ps1"
    # このスクリプトに渡されたオプションのうち、部品のスクリプトが受け付けるものだけを渡す
    $accepted = @((Get-Command -Name $script).Parameters.Keys)
    $arguments = @()
    foreach ($name in $PSBoundParameters.Keys) {
        if ($accepted -notcontains $name) {
            continue
        }
        $value = $PSBoundParameters[$name]
        if ($value -is [switch]) {
            if ($value.IsPresent) {
                $arguments += "-$name"
            }
            continue
        }
        # 空白を含む値は引用符で囲まれて渡るので、末尾の \ が引用符を打ち消さないように取る
        $text = [string]$value
        if ($text -match '\s' -and $text.EndsWith('\')) {
            $text = $text.TrimEnd('\')
        }
        $arguments += @("-$name", $text)
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script @arguments
    $code = $LASTEXITCODE
    if ($code -eq 2) {
        $skipped += $part.Label
        Write-Host "（$($part.Label) は飛ばして、次に進みます）"
        continue
    }
    if ($code -ne 0) {
        $rest = @()
        if ($i + 1 -lt $Parts.Count) {
            $rest = @($Parts[($i + 1)..($Parts.Count - 1)] | ForEach-Object Label)
        }
        Write-Host ''
        if ($rest.Count -gt 0) {
            Write-Host "$($part.Label) で問題があったため、ここで終わります（$($rest -join '、') は実行していません）。" -ForegroundColor Red
        }
        exit $code
    }
}
if ($skipped.Count -gt 0) {
    Write-Host ''
    Write-Host "飛ばした部品: $($skipped -join '、')"
}
exit 0
