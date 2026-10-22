# XAMPP セキュリティ更新（非公式）

XAMPP for Windows 8.2.12 の PHP、Apache、MariaDB、phpMyAdmin を、脆弱性を修正した新しいものに入れ替えるための更新スクリプトとインストーラーです。

| 部品 | XAMPP 8.2.12 | 更新後 | 主な理由 |
| --- | --- | --- | --- |
| PHP | 8.2.12 | 8.2.35 | PHP2Shell（CVE-2026-109618 / CVE-2026-109619）ほか |
| Apache | 2.4.58（OpenSSL 3.1.3） | 2.4.69（OpenSSL 3.5.9） | 2.4.59〜2.4.69 で修正された 72 件の脆弱性、OpenSSL 3.1 のサポート終了 |
| MariaDB | 10.4.32 | 11.4.13 | 10.4 のサポート終了（2024 年 6 月）。11.4 は長期サポート版（2029 年 5 月まで） |
| phpMyAdmin | 5.2.1 | 5.2.3 | 5.2.2 で修正された XSS などの脆弱性（PMASA-2025-1〜3） |
| PEAR の Archive_Tar | 1.4.0 | 1.6.0 | CVE-2020-36193（実際の攻撃が確認されている）などの脆弱性 |
| CA バンドル（PHP が証明書の検証に使う） | 2022-04-26 版 | 2026-10-20 版 | その後に信頼されなくなったルート証明書が残り、新しいルート証明書がない |

> [!IMPORTANT]
> Apache Friends（XAMPP の開発元）による公式の配布物ではありません。XAMPP の公式版が更新されるまでのつなぎとしてお使いください。

## 背景

### PHP（PHP2Shell）

- 2026 年 10 月 21 日、PHP 本体の重大な脆弱性 2 件が公表され、修正版の PHP 8.2.35 / 8.3.36 / 8.4.27 / 8.5.12 が公開されました（CVSS v4 は 9.2）。
  - CVE-2026-109618（GHSA-w8hw-w9fx-j79w）: メモリ不足（OOM）時の中断処理で状態が壊れ、リモートでコードを実行される
  - CVE-2026-109619（GHSA-6wmf-4rv5-p3rp）: リクエストをまたいで残った古いグローバル状態を使ってしまい、リモートでコードを実行される
- XAMPP と同じ「Apache + mod_php」の構成では、初期設定のまま HTTP リクエストだけでリモートコード実行に至ることが確認されています。

### Apache

- XAMPP 8.2.12 の Apache 2.4.58（2023 年 10 月）は、2.4.69（2026 年 10 月）までに修正された 72 件の脆弱性の影響を受けます。Windows 版だけに関係する NTLM ハッシュの漏えい（CVE-2024-38472 など）や、実際の攻撃が確認されている mod_rewrite の脆弱性（CVE-2024-38475）も含まれます。
- 同梱の OpenSSL 3.1.3 は 2025 年 3 月にサポートが終わっています。Apache の中で動く PHP の openssl 拡張と curl 拡張も、この OpenSSL を使います。

### MariaDB と phpMyAdmin

- XAMPP 8.2.12 の MariaDB 10.4 は、2024 年 6 月にサポートが終わっています。
- phpMyAdmin 5.2.1 には、5.2.2 で修正された XSS などの脆弱性（PMASA-2025-1〜3）があります。

### PEAR の Archive_Tar と CA バンドル

- XAMPP の PEAR（`php\pear`。PHP の include_path に入っています）の Archive_Tar 1.4.0 には、細工した tar の展開でファイルを書き換えられる脆弱性（CVE-2020-36193、CVE-2021-32610 など）があります。Archive_Tar で信頼できない tar を展開するアプリや、`pear install` を使う場合に影響します。
- PHP の curl 拡張と openssl 拡張は、外部のサイトにつなぐときの証明書の検証に `apache\bin\curl-ca-bundle.crt` を使います（`php.ini` の `curl.cainfo` と `openssl.cafile`）。XAMPP 8.2.12 のものは 2022 年 4 月の版で、その後に Mozilla が信頼をやめた TrustCor、E-Tugra、Entrust などのルート証明書が残っています。

XAMPP for Windows の最新版は 8.2.12 のままで、修正版はまだ出ていません。

## どれを使うか

| 状況 | 使うもの |
| --- | --- |
| すでに XAMPP 8.2.x を使っている | [更新スクリプト](#既存の-xampp-を更新する)（`update-xampp.bat`） |
| これから XAMPP を入れる | [インストーラー](#新しく入れる)（`xampp-8.2.12-php8.2.35-apache2.4.69-mariadb11.4.13-setup.exe`） |

XAMPP 8.0 / 8.1 系（PHP 8.0 / 8.1）は、PHP 本体のサポートが終わっていて修正版が出ないため対象外です。XAMPP 8.2.12 に移行するか、インストーラーで入れ直してください。

## 既存の XAMPP を更新する

1. XAMPP コントロールパネルで Apache と MySQL を Stop します。サービスとして登録している場合は、サービスも停止します。
2. [Releases](../../releases) から `xampp-security-update-*.zip` をダウンロードして、好きな場所に展開します。
3. `update-xampp.bat` をダブルクリックします。PHP、Apache、MariaDB、phpMyAdmin の順に更新します（入っていない部品は飛ばします）。それぞれ内容を確認して `y` を入力し、Enter キーを押します。`n` と答えた部品は飛ばして、次の部品に進みます。
4. 「完了しました」と表示されたら、XAMPP コントロールパネルで Apache と MySQL を Start します。
5. ブラウザーで `http://localhost/dashboard/phpinfo.php` を開き、PHP Version が 8.2.35、Apache Version が Apache/2.4.69 になっていることを確認します。`http://localhost/phpmyadmin/` では、データベースサーバーが 11.4.13-MariaDB になっていることを確認できます。

一部の部品だけを更新するときは、`update-xampp-php.bat`、`update-xampp-apache.bat`、`update-xampp-mariadb.bat`、`update-xampp-phpmyadmin.bat` を使います。

XAMPP を `C:\xampp` 以外にインストールしている場合、各ドライブ直下の `\xampp` は自動で見つけます。それ以外の場所にある場合は、コマンドプロンプトでフォルダを指定してください。

```bat
update-xampp.bat -XamppDir D:\tools\xampp
```

インターネットにつながっていない PC では、別の PC で次のファイルを入手し、`update-xampp.bat` と同じフォルダに置いてから実行してください。

| ファイル | 入手先 |
| --- | --- |
| `php-8.2.35-Win32-vs16-x64.zip` | [php.net](https://www.php.net/downloads.php?os=windows) |
| `httpd-2.4.69-261002-Win64-VS18.zip` | [Apache Lounge](https://www.apachelounge.com/download/) |
| `mariadb-11.4.13-winx64.zip` | [MariaDB](https://mariadb.org/download/) |
| `phpMyAdmin-5.2.3-all-languages.zip` | [phpMyAdmin](https://www.phpmyadmin.net/downloads/) |
| `Archive_Tar-1.6.0.tgz` | [PEAR](https://pear.php.net/package/Archive_Tar/download) |
| `cacert-2026-10-20.pem` | [curl.se](https://curl.se/docs/caextract.html) |

公式の zip を手作業で上書きして、すでに PHP 8.2.35 や Apache 2.4.69 にしている場合や、以前の版のこのスクリプトで更新した場合も、このスクリプトを実行してください。足りない DLL の追加、Archive_Tar と CA バンドルの更新、弱い証明書の作り直しのうち、必要なものだけを行います。

### PHP の更新で行うこと（update-xampp-php.bat）

1. php.net から公式の PHP 8.2.35 を取得し、php.net が公開している SHA-256 と照合します。一致しないファイルは使いません。
2. XAMPP の `php` フォルダを `php_backup_<元のバージョン>_<日時>` にバックアップします。
3. 新しい PHP のファイルを `php` フォルダに上書きします。`php.ini`、PEAR など XAMPP 独自のファイルはそのまま残ります。
4. `apache\bin` の DLL をそろえます。XAMPP は、Apache から PHP の拡張を読み込めるよう、拡張が使う DLL の一部（ICU、libsasl、libssh2）を `apache\bin` にもコピーしています。これらを新しい PHP のものに更新し、新しい PHP で増えた依存 DLL（PHP 8.2.35 の curl 拡張が使う `brotlidec.dll`）を追加します。これをしないと、Apache 上で curl 拡張を読み込めません。
5. PEAR の Archive_Tar を 1.6.0 にします（pear.php.net の配布物の SHA-256 を照合し、`Archive\Tar.php` と PEAR の登録情報を書き換えます）。
6. CA バンドル（`apache\bin\curl-ca-bundle.crt`）を、curl.se が Mozilla のデータから作っている 2026-10-20 版にします（curl.se が公開している SHA-256 と照合します）。XAMPP の元のものから変わっている（自分で CA を足した）場合は置き換えません。
7. `php.ini` に `session.upload_progress.enabled = Off` を追加します。公式のアドバイザリーは、アップロード進捗の機能を使っていないなら、修正版にしたあとも無効にしておくことを勧めています。使っている場合は `-NoHarden` を付けて実行してください（`update-xampp.bat -NoHarden` でもかまいません）。
8. `php.exe` と `httpd.exe -t` で、PHP と Apache が起動できることを確かめます。

PHP がすでに 8.2.35 の場合は、4〜6 のうち必要なものだけを、`php` フォルダをバックアップしてから行います。Archive_Tar と CA バンドルを取得できなかった場合は、注意を表示してその 2 つだけを飛ばします（あとでもう一度実行すると更新します）。

### Apache の更新で行うこと（update-xampp-apache.bat）

1. Microsoft Visual C++ 再頒布可能パッケージ（x64）14.51 以上が入っていることを確かめます。入っていない場合は、[最新版](https://aka.ms/vc14/vc_redist.x64.exe) をインストールしてから実行してください。
2. Apache Lounge の Windows 版（`httpd-2.4.69-261002-Win64-VS18.zip`）を取得し、Apache Lounge が公開している SHA-256 と照合します。Apache Lounge は最新版しか置かないため、取得できない場合は、このリポジトリのリリースに置いた同じ zip を使います。
3. 上書きするファイルを `apache_backup_<元のバージョン>_<日時>` に退避してから、`apache` フォルダの `bin`、`modules`、`include`、`lib` とライセンス文書を上書きします。設定（`conf`）はそのまま残ります。
4. HTTPS の証明書が弱い場合は、この PC だけの鍵で作り直します（localhost 用の自己署名証明書。RSA 2048 ビット、SHA-256）。XAMPP 付属の証明書は 1024 ビット鍵・SHA-1 署名のうえ、すべての XAMPP で同じ鍵です。OpenSSL 3.5 ではこの証明書を読み込めず、そのままでは Apache が起動しません。作り直したくない場合は `-KeepCertificate` を付けます。
5. `httpd.exe -v` と `httpd.exe -t` で起動できることを確かめ、PHP と有効な拡張が使う DLL が Apache から見つかることも確かめます。

### MariaDB の更新で行うこと（update-xampp-mariadb.bat）

1. MariaDB 公式の Windows 版（`mariadb-11.4.13-winx64.zip`）を取得し、MariaDB が公開している SHA-256 と照合します。
2. `mysql` フォルダを、データを含めて丸ごと `mysql_backup_<元のバージョン>_<日時>` にバックアップします（ディスクの空きを先に確かめます）。
3. 元の MariaDB 10.4 を一時的に起動して、正常に終了させます。XAMPP の MySQL の停止はプロセスの強制終了なので、そのままでは新しい版がデータを開けないためです。
4. `bin`、`lib`、`share` を新しい版に入れ替えます。`my.ini` はそのまま使います（新しい版が注意を出す省略形の `key_buffer` だけ、正式名の `key_buffer_size` に書き換えます）。
5. 新しい版を一時的に起動し、`mariadb-upgrade` でシステムテーブルなどを移行してから正常に終了させ、もう一度起動してエラーが出ないことを確かめます。
6. 途中で失敗した場合は、バックアップから元に戻します。

作業中に一時的に起動する MariaDB は、127.0.0.1 の空いているポートだけで待ち受け、権限の確認を省いた状態で動かします（root にパスワードを付けていても移行できます）。作業が終わるまで、XAMPP コントロールパネルで MySQL を操作しないでください。

`my.ini` で、データの置き場所（`datadir`、`innodb_data_home_dir`、`innodb_log_group_home_dir`）を `mysql\data` 以外にしている場合は、何も変更せずに止まります。このスクリプトは `mysql` フォルダの中だけをバックアップして移行するためです。

### phpMyAdmin の更新で行うこと（update-xampp-phpmyadmin.bat）

1. phpMyAdmin 公式の配布物（`phpMyAdmin-5.2.3-all-languages.zip`）を取得し、phpMyAdmin が公開している SHA-256 と照合します。
2. いまの `phpMyAdmin` フォルダの名前を `phpMyAdmin_backup_<元のバージョン>_<日時>` に変えて残し、新しい phpMyAdmin を置いて `config.inc.php` を引き継ぎます。ほかに自分で追加したファイル（テーマなど）がある場合は、バックアップから写してください。

### 元に戻す

Apache と MySQL を止めてから、次のように実行します。更新とは逆の順（phpMyAdmin、MariaDB、Apache、PHP）に、各部品がいちばん新しいバックアップに戻ります（バックアップがない部品は飛ばします）。

```bat
update-xampp.bat -Restore
```

MariaDB を元に戻すと、更新したあとに追加・変更したデータは失われます（入れ替え後の `mysql` フォルダは `mysql_replaced_<日時>` という名前で残します）。PHP と phpMyAdmin も、入れ替え後のフォルダを `php_replaced_<日時>`、`phpMyAdmin_replaced_<日時>` という名前で残します。PHP を戻すと、Archive_Tar と CA バンドルも元に戻ります。

更新を何度か実行してバックアップが複数ある場合は、1 回の `-Restore` で新しいものから 1 つずつ戻ります。さらに古いバックアップが残っているときは、そのことを表示します。

部品ごとに戻すときは、`update-xampp-apache.bat -Restore` のように、各部品の bat に `-Restore` を付けて実行します。PHP と Apache の両方を戻すときは、Apache を先に戻してください。PHP のあとに Apache を更新した場合、PHP の更新で `apache\bin` に追加した DLL が Apache のバックアップに入るため、PHP を先に戻すと、その DLL が残ります。

### オプション

| オプション | 使えるスクリプト | 内容 |
| --- | --- | --- |
| `-XamppDir <フォルダ>` | すべて | XAMPP のフォルダを指定します。 |
| `-Restore` | すべて | いちばん新しいバックアップに戻します。 |
| `-Yes` | すべて | 確認の問い合わせを省略します。 |
| `-Force` | すべて | バージョン系列が違う場合や、Apache や MySQL が動いている場合でも続行します（おすすめしません）。 |
| `-NoHarden` | PHP | `php.ini` を変更しません。 |
| `-PhpZip <ファイル>` | PHP | 手元にある公式の zip を使います（SHA-256 は照合します）。 |
| `-KeepCertificate` | Apache | 証明書が弱くても作り直しません。 |
| `-ApacheZip <ファイル>` | Apache | 手元にある Apache Lounge の zip を使います（SHA-256 は照合します）。 |
| `-MariaDbZip <ファイル>` | MariaDB | 手元にある MariaDB の zip を使います（SHA-256 は照合します）。 |
| `-PhpMyAdminZip <ファイル>` | phpMyAdmin | 手元にある phpMyAdmin の zip を使います（SHA-256 は照合します）。 |

`update-xampp.bat` に付けたオプションは、それを受け付ける部品のスクリプトにだけ渡します（たとえば `-NoHarden` は PHP だけ）。

## 新しく入れる

[Releases](../../releases) の `xampp-8.2.12-php8.2.35-apache2.4.69-mariadb11.4.13-setup.exe` を実行します。XAMPP 8.2.12 の PHP、Apache、MariaDB、phpMyAdmin を更新したものが入ります。

| 部品 | 内容 |
| --- | --- |
| 必須 | Apache 2.4.69、PHP 8.2.35、XAMPP コントロールパネル、ダッシュボードなど |
| 選択 | MariaDB 11.4.13、phpMyAdmin 5.2.3 |
| 入らない | Perl、Tomcat、FileZilla Server、Mercury Mail、Webalizer、fake sendmail（サポートが終わっているか古いため）、PHP の enchant 拡張 |

- 既定のインストール先は `C:\xampp` です。空白や日本語を含むフォルダと、すでに XAMPP があるフォルダには入れられません。
- 管理者権限は必須ではありません。自分だけにインストールした場合は、インストール先を、インストールしたユーザー・SYSTEM・Administrators だけが変更できるようにします（`C:\` の直下に作ったフォルダは、既定では同じ PC のほかのユーザーも変更できるため）。すべてのユーザー向けにインストールした場合は、共用を前提に、継承したアクセス権のままにします。
- HTTPS 用の証明書は、インストールのときにこの PC だけの鍵で作ります。
- 安全のため、XAMPP の初期設定から次の点を変えています。元に戻すときは、`apache\conf\httpd.conf`、`apache\conf\extra\httpd-xampp.conf`、`mysql\bin\my.ini` の「xampp-security-update installer」と書いたコメントの箇所を編集してください。
  - `/php-cgi/` で `php-cgi.exe` を公開しない（PHP は Apache のモジュールとして動くため不要です）
  - `/cgi-bin/` と、ダッシュボードの `phpinfo.php` は、この PC からだけ使える
  - MariaDB は 127.0.0.1 だけで待ち受ける（ほかの PC からは接続できません）
- Microsoft Visual C++ 再頒布可能パッケージ（x64）14.51 以上が必要です。入っていない場合は、セットアップがダウンロードページを案内します。
- セットアップにはコード署名がないため、Windows の SmartScreen の警告が出ることがあります。その場合は、Releases に載せている SHA-256 と照合してから、「詳細情報」→「実行」を選んでください。

## 注意

- PHP 8.2 系のサポートは 2026 年 12 月 31 日で終わります。長く使う場合は、より新しい PHP への移行を検討してください。
- XAMPP は開発用の環境です。MariaDB の root にはパスワードが設定されていません（XAMPP と同じ）。インターネットには公開しないでください。
- 更新スクリプトは、既存の XAMPP の設定（`/php-cgi/` や `/cgi-bin/` の公開、MariaDB の待ち受けなど）を変えません。ほかの PC から接続できるネットワークで使う場合は、[新しく入れる](#新しく入れる)場合と同じ変更を検討してください。
- MariaDB 11.4 の `mysql.exe` でパスワードなしの root に接続すると、「--ssl-verify-server-cert is disabled」という警告が出ます。動作に問題はありません。
- 修正版の PHP では、`memory_limit` を大きく超えるメモリー確保（既定では 2 倍。`memory_limit` が 1GB を超える場合は +1GB）で、エラー処理を待たずにプロセスを終了する仕組みが加わりました。上限は新しい設定 `memory_hard_limit_percent` で変えられます。よく使う関数の大きな確保は通常の Fatal error で止まりますが、この上限に当たった場合、XAMPP（Apache + mod_php）では Apache の子プロセスごと終了し、そのとき処理中だった他のリクエストも切断されます。
- Apache の中で動く PHP の openssl 拡張と curl 拡張は、`apache\bin` にある Apache 側の OpenSSL を使います。PHP だけを更新した場合、この OpenSSL は 3.1.3 のままです。

## 開発者向け

| スクリプト | 内容 |
| --- | --- |
| `update-xampp.ps1` | `update-xampp.bat` の本体です。部品ごとのスクリプトを順に（`-Restore` では逆の順に）実行し、オプションは受け付けるスクリプトにだけ渡します。 |
| `build-package.ps1` | 公式の `xampp-windows-x64-8.2.12-0-VS16.zip` を SourceForge から取得し（SHA-256 を照合）、PHP、Apache、MariaDB、phpMyAdmin を更新した一式の zip を `dist` フォルダに作ります（`-PhpOnly` で PHP だけ）。MariaDB のデータの移行では、MariaDB を 127.0.0.1 の空いているポートで一時的に起動します。 |
| `build-installer.ps1` | `build-package.ps1` の作業フォルダから、Inno Setup（6.3 以降）でインストーラーを作ります。新しく入れる場合の設定の強化（`/php-cgi/` を公開しないなど）は、このときにインストーラーに入れる設定ファイルだけに加えます。 |
| `tests\smoke-test.ps1` | XAMPP 一式の zip またはインストール済みのフォルダで、Apache を `127.0.0.1:8080` / `8443` に、MariaDB を 127.0.0.1 の空いているポートに一時的に起動し、PHP、Apache、MariaDB、phpMyAdmin の動作を確かめます。`-ApplyUpdate` では、元の MariaDB にデータを書き込んで強制終了させてから更新スクリプトを適用し、データの移行と、`update-xampp.bat -Restore` で更新前とまったく同じに戻ることも確かめます。 |
| `tests\installer-test.ps1` | インストーラーを確認用のフォルダにサイレントでインストールし、中身、インストール先のアクセス権、動作を確かめてからアンインストールします。 |

```powershell
.\build-package.ps1
.\build-installer.ps1
.\tests\smoke-test.ps1 -Zip .\downloads\xampp-windows-x64-8.2.12-0-VS16.zip -ApplyUpdate
.\tests\installer-test.ps1 -Setup .\dist\xampp-8.2.12-php8.2.35-apache2.4.69-mariadb11.4.13-setup.exe
```

## ライセンス

- このリポジトリのスクリプトは [BSD 3-Clause License](LICENSE) で公開しています。
- 更新スクリプトは PHP、Apache、MariaDB、phpMyAdmin、Archive_Tar、CA バンドルのファイルを含まず、実行時にそれぞれの公式の配布元から取得します。
- インストーラーと、Releases に置いた Apache Lounge の zip には、次のソフトウェアが含まれます。それぞれのライセンスに従います（インストール先の `licenses` フォルダと、各フォルダ内のライセンス文書も参照してください）。

| ソフトウェア | ライセンス | ソースコード |
| --- | --- | --- |
| XAMPP（コントロールパネルなどのツール） | GNU GPL v2 | インストール先の `src` フォルダ |
| Apache HTTP Server 2.4.69（Apache Lounge の Windows 版） | Apache License 2.0（同梱のライブラリは各ライセンス） | [httpd.apache.org](https://httpd.apache.org/download.cgi)、[Apache Lounge](https://www.apachelounge.com/) |
| PHP 8.2.35（php.net の Windows 版） | PHP License（同梱のライブラリは各ライセンス） | [php.net](https://www.php.net/downloads.php) |
| MariaDB 11.4.13 | GNU GPL v2 | Releases の `mariadb-11.4.13.tar.gz` |
| phpMyAdmin 5.2.3 | GNU GPL v2 | Releases の `phpMyAdmin-5.2.3-source.tar.xz` |
| PEAR の Archive_Tar 1.6.0 | BSD License | [pear.php.net](https://pear.php.net/package/Archive_Tar)、[GitHub](https://github.com/pear/Archive_Tar) |
| CA バンドル（curl.se が Mozilla のデータから作成） | Mozilla Public License 2.0 | [curl.se](https://curl.se/docs/caextract.html)、[Mozilla の certdata.txt](https://hg.mozilla.org/mozilla-central/file/tip/security/nss/lib/ckfw/builtins/certdata.txt) |

PHP の Windows 版に同梱されている LGPL の DLL（enchant 拡張と glib）は、インストーラーに含めていません。

`build-package.ps1` で作った一式の zip には、上の表のほかに Perl、Tomcat などの部品も含まれます。人に配る場合は、各ライセンスが求める対応ソースコードの提供などの条件を満たす必要があります。

## 参考

- [PHP 公式サイトのニュース（2026 年 10 月 21 日のセキュリティアドバイザリー）](https://www.php.net/)
- [GHSA-w8hw-w9fx-j79w: RCE via OOM corruption](https://github.com/php/php-src/security/advisories/GHSA-w8hw-w9fx-j79w)
- [GHSA-6wmf-4rv5-p3rp: RCE via stale global state](https://github.com/php/php-src/security/advisories/GHSA-6wmf-4rv5-p3rp)
- [Apache HTTP Server 2.4 の脆弱性一覧](https://httpd.apache.org/security/vulnerabilities_24.html)
- [Apache Lounge のダウンロード](https://www.apachelounge.com/download/)
- [MariaDB のダウンロード](https://mariadb.org/download/)
- [phpMyAdmin のダウンロード](https://www.phpmyadmin.net/downloads/)
- [PHP for Windows のダウンロード](https://www.php.net/downloads.php?os=windows)
- [XAMPP for Windows 8.2.12（SourceForge）](https://sourceforge.net/projects/xampp/files/XAMPP%20Windows/8.2.12/)
