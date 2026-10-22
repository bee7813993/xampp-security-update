# XAMPP セキュリティ更新（PHP2Shell 対策・非公式）

XAMPP for Windows 8.2 系に同梱されている PHP を、2026 年 10 月に公表された PHP の重大な脆弱性（通称 PHP2Shell、CVE-2026-109618 / CVE-2026-109619）を修正した公式の PHP 8.2.35 に入れ替えるスクリプトです。

> [!IMPORTANT]
> Apache Friends（XAMPP の開発元）による公式の配布物ではありません。XAMPP の公式版が更新されるまでのつなぎとしてお使いください。

## 背景

- 2026 年 10 月 21 日、PHP 本体の重大な脆弱性 2 件が公表され、修正版の PHP 8.2.35 / 8.3.36 / 8.4.27 / 8.5.12 が公開されました（CVSS v4 は 9.2）。
  - CVE-2026-109618（GHSA-w8hw-w9fx-j79w）: メモリ不足（OOM）時の中断処理で状態が壊れ、リモートでコードを実行される
  - CVE-2026-109619（GHSA-6wmf-4rv5-p3rp）: リクエストをまたいで残った古いグローバル状態を使ってしまい、リモートでコードを実行される
- XAMPP と同じ「Apache + mod_php」の構成では、初期設定のまま HTTP リクエストだけでリモートコード実行に至ることが確認されています。
- 一方、XAMPP for Windows の最新版は 8.2.12（同梱の PHP は 8.2.12）のままで、修正版はまだ出ていません。

## 対象

| 項目 | 内容 |
| --- | --- |
| XAMPP | XAMPP for Windows 8.2 系（8.2.12 で確認） |
| 入れ替え後の PHP | 8.2.35（php.net 公式の Windows 版。スレッドセーフ版、x64、VS16） |
| OS | Windows 10 / 11（64 ビット） |

XAMPP 8.0 / 8.1 系（PHP 8.0 / 8.1）は、PHP 本体のサポートが終わっていて修正版が出ないため対象外です。XAMPP 8.2.12 に移行してから適用してください。

## 使い方

1. XAMPP コントロールパネルで Apache を Stop します。Apache をサービスとして登録している場合は、サービスも停止します。
2. [Releases](../../releases) から zip をダウンロードして、好きな場所に展開します。
3. `update-xampp-php.bat` をダブルクリックします。
4. 内容を確認して `y` を入力し、Enter キーを押します。
5. 「完了しました」と表示されたら、XAMPP コントロールパネルで Apache を Start します。
6. ブラウザーで `http://localhost/dashboard/phpinfo.php` を開き、PHP Version が 8.2.35 になっていることを確認します。

XAMPP を `C:\xampp` 以外にインストールしている場合、各ドライブ直下の `\xampp` は自動で見つけます。それ以外の場所にある場合は、コマンドプロンプトでフォルダを指定してください。

```bat
update-xampp-php.bat -XamppDir D:\tools\xampp
```

インターネットにつながっていない PC では、別の PC で [php.net の Windows 版ダウンロードページ](https://www.php.net/downloads.php?os=windows) から `php-8.2.35-Win32-vs16-x64.zip` を入手し、`update-xampp-php.bat` と同じフォルダに置いてから実行してください。

公式の zip を手作業で `php` フォルダに上書きして、すでに PHP 8.2.35 にしている場合も、このスクリプトを実行してください。Apache から読み込めない DLL があれば、それだけを補います（下の「何をするか」の 4）。

## 何をするか

1. php.net から公式の PHP 8.2.35 を取得し、php.net が公開している SHA-256 と照合します。一致しないファイルは使いません。
2. XAMPP の `php` フォルダを `php_backup_<元のバージョン>_<日時>` にバックアップします。
3. 新しい PHP のファイルを `php` フォルダに上書きします。`php.ini`、PEAR など XAMPP 独自のファイルはそのまま残ります。
4. `apache\bin` の DLL をそろえます。XAMPP は、Apache から PHP の拡張を読み込めるよう、拡張が使う DLL の一部（ICU、libsasl、libssh2）を `apache\bin` にもコピーしています。これらを新しい PHP のものに更新し、新しい PHP で増えた依存 DLL（PHP 8.2.35 の curl 拡張が使う `brotlidec.dll`）を追加します。これをしないと、Apache 上で curl 拡張を読み込めません。上書き前の DLL はバックアップに残します。
5. `php.ini` に `session.upload_progress.enabled = Off` を追加します。公式のアドバイザリーは、アップロード進捗の機能を使っていないなら、修正版にしたあとも無効にしておくことを勧めています。使っている場合は `-NoHarden` を付けて実行してください。
6. `php.exe` と `httpd.exe -t` で、PHP と Apache が起動できることを確かめます。

## 元に戻す

Apache を止めてから、次のように実行します。いちばん新しいバックアップが `php` フォルダに戻り、`apache\bin` で更新・追加した DLL も元に戻ります。入れ替え後の `php` フォルダは `php_replaced_<日時>` という名前で残します。

```bat
update-xampp-php.bat -Restore
```

## オプション

| オプション | 内容 |
| --- | --- |
| `-XamppDir <フォルダ>` | XAMPP のフォルダを指定します。 |
| `-PhpZip <ファイル>` | 手元にある公式の zip を使います（SHA-256 は照合します）。 |
| `-NoHarden` | `php.ini` を変更しません。 |
| `-Restore` | いちばん新しいバックアップに戻します。 |
| `-Yes` | 確認の問い合わせを省略します。 |
| `-Force` | PHP のバージョン系列が違う場合や、Apache が動いている場合でも続行します（おすすめしません）。 |

## 注意

- PHP 8.2 系のサポートは 2026 年 12 月 31 日で終わります。長く使う場合は、より新しい PHP への移行を検討してください。
- このスクリプトで更新するのは PHP だけです。XAMPP 8.2.12 の Apache 2.4.58 は、2.4.69（2026 年 10 月）までに修正された 72 件の脆弱性の影響を受けます。この中には、Windows 版だけに関係する NTLM ハッシュ漏えい（CVE-2024-38472 など）も含まれます。同梱の OpenSSL 3.1.3 はサポートが終わっていて、MariaDB 10.4.32、phpMyAdmin 5.2.1 も古いままです。XAMPP はインターネットに公開しないでください。
- Apache の中で動く PHP の openssl 拡張と curl 拡張は、`apache\bin` にある Apache 側の OpenSSL（XAMPP 8.2.12 では 3.1.3）を使います。PHP を更新しても、この OpenSSL は新しくなりません。
- 修正版の PHP では、`memory_limit` を大きく超えるメモリー確保（既定では 2 倍。`memory_limit` が 1GB を超える場合は +1GB）で、エラー処理を待たずにプロセスを終了する仕組みが加わりました。上限は新しい設定 `memory_hard_limit_percent` で変えられます。よく使う関数の大きな確保は通常の Fatal error で止まりますが、この上限に当たった場合、XAMPP（Apache + mod_php）では Apache の子プロセスごと終了し、そのとき処理中だった他のリクエストも切断されます。
- PHP 8.2.35 の実行には、XAMPP 8.2.12 と同じく Microsoft Visual C++ 再頒布可能パッケージ（x64）が必要です。確認で `vcruntime` に関する警告が出た場合は、[最新版](https://aka.ms/vs/17/release/vc_redist.x64.exe) をインストールしてください。

## 開発者向け

### XAMPP 一式の zip を作る

公式の `xampp-windows-x64-8.2.12-0-VS16.zip` を SourceForge から取得し（MD5 と SHA-256 を照合）、PHP を入れ替えた zip を `dist` フォルダに作ります。

```powershell
.\build-package.ps1
```

出来上がる zip には GPL のソフトウェアが含まれるため、人に配る場合は「ライセンス」の項を確認してください。

### 動作確認

XAMPP 一式の zip を作業フォルダに展開して Apache を `127.0.0.1:8080` で一時的に起動し、次のことを確かめます。

- PHP のバージョン、読み込まれた DLL と `php.ini`
- 有効な拡張（curl を含む）がすべて読み込まれているか
- ファイルのアップロード
- `memory_limit` を超えたあとの応答

`-ApplyUpdate` を付けると、公式の XAMPP に更新スクリプトを適用したうえで同じことを確かめ、最後に `-Restore` で元どおりに戻るかも確かめます。

```powershell
# build-package.ps1 で作った zip を確かめる
.\tests\smoke-test.ps1 -Zip .\dist\xampp-windows-x64-8.2.12-0-VS16-php8.2.35.zip

# 公式の XAMPP 8.2.12 に update-xampp-php.ps1 を適用して確かめる
.\tests\smoke-test.ps1 -Zip .\downloads\xampp-windows-x64-8.2.12-0-VS16.zip -ApplyUpdate
```

## ライセンス

- このリポジトリのスクリプトは [BSD 3-Clause License](LICENSE) で公開しています。
- このリポジトリと Releases には、PHP や XAMPP のファイルを含めていません。スクリプトの実行時に、それぞれの公式の配布元から取得します。PHP は PHP License、XAMPP は GNU GPL v2 と各コンポーネントのライセンスに従います。
- `build-package.ps1` で作った zip には、XAMPP（GNU GPL v2）、MariaDB、phpMyAdmin などのソフトウェアが含まれます。再配布する場合は、各ライセンスが求める対応ソースコードの提供などの条件を満たす必要があります。

## 参考

- [PHP 公式サイトのニュース（2026 年 10 月 21 日のセキュリティアドバイザリー）](https://www.php.net/)
- [GHSA-w8hw-w9fx-j79w: RCE via OOM corruption](https://github.com/php/php-src/security/advisories/GHSA-w8hw-w9fx-j79w)
- [GHSA-6wmf-4rv5-p3rp: RCE via stale global state](https://github.com/php/php-src/security/advisories/GHSA-6wmf-4rv5-p3rp)
- [PHP for Windows のダウンロード](https://www.php.net/downloads.php?os=windows)
- [Apache HTTP Server 2.4 の脆弱性一覧](https://httpd.apache.org/security/vulnerabilities_24.html)
- [XAMPP for Windows 8.2.12（SourceForge）](https://sourceforge.net/projects/xampp/files/XAMPP%20Windows/8.2.12/)
