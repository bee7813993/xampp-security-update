; XAMPP for Windows 8.2.12 の PHP と Apache を更新したものを入れるインストーラー（非公式）。
; build-installer.ps1 が ISCC.exe に次の値を渡してコンパイルする。
;   StageDir           部品ごとに分けたファイル（core、mariadb、phpmyadmin の各フォルダ）
;   AppVersion         表示用のバージョン（例: 8.2.12-php8.2.35-apache2.4.69）
;   PhpVersion, ApacheVersion, MariaDbVersion, PhpMyAdminVersion
;   FileVersion        セットアップ自体のファイルバージョン（数字 4 つ）
;   OutputDir, OutputBaseFilename

#ifndef StageDir
  #error build-installer.ps1 から実行してください
#endif

[Setup]
AppId={{BB7364E5-EE3F-4445-8B9B-B8B60ACC0445}
AppName=XAMPP セキュリティ更新版（非公式）
AppVersion={#AppVersion}
AppVerName=XAMPP 8.2.12 セキュリティ更新版（PHP {#PhpVersion} / Apache {#ApacheVersion} / MariaDB {#MariaDbVersion}、非公式）
AppPublisher=xampp-security-update
AppPublisherURL=https://github.com/bee7813993/xampp-security-update
AppSupportURL=https://github.com/bee7813993/xampp-security-update/issues
VersionInfoVersion={#FileVersion}
DefaultDirName=C:\xampp
DisableProgramGroupPage=yes
DirExistsWarning=no
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog commandline
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
InfoBeforeFile=notice-ja.txt
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseFilename}
Compression=lzma2/ultra64
SolidCompression=yes
LZMAUseSeparateProcess=yes
WizardStyle=modern
UninstallDisplayIcon={app}\xampp-control.exe
UninstallDisplayName=XAMPP セキュリティ更新版（非公式）
SetupLogging=yes
ShowLanguageDialog=no

[Languages]
Name: "ja"; MessagesFile: "compiler:Languages\Japanese.isl"

[Types]
Name: "full"; Description: "すべて（MariaDB と phpMyAdmin を含む）"
Name: "web"; Description: "Apache と PHP だけ"
Name: "custom"; Description: "選んで入れる"; Flags: iscustom

[Components]
Name: "core"; Description: "Apache {#ApacheVersion}、PHP {#PhpVersion}、XAMPP コントロールパネル"; Types: full web custom; Flags: fixed
Name: "mariadb"; Description: "MariaDB {#MariaDbVersion}（MySQL 互換のデータベース）"; Types: full
Name: "phpmyadmin"; Description: "phpMyAdmin {#PhpMyAdminVersion}（データベースの管理画面）"; Types: full

[Tasks]
Name: "startmenuicon"; Description: "スタートメニューに XAMPP コントロールパネルを登録する"
Name: "desktopicon"; Description: "デスクトップに XAMPP コントロールパネルのアイコンを作る"; Flags: unchecked

[Files]
Source: "{#StageDir}\core\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Components: core
Source: "{#StageDir}\mariadb\*"; DestDir: "{app}"; Excludes: "\mysql\data"; Flags: ignoreversion recursesubdirs createallsubdirs; Components: mariadb
; データベースの中身は、アンインストールしても消さない
Source: "{#StageDir}\mariadb\mysql\data\*"; DestDir: "{app}\mysql\data"; Flags: recursesubdirs createallsubdirs onlyifdoesntexist uninsneveruninstall; Components: mariadb
Source: "{#StageDir}\phpmyadmin\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Components: phpmyadmin

[Icons]
Name: "{autoprograms}\XAMPP\XAMPP コントロールパネル"; Filename: "{app}\xampp-control.exe"; WorkingDir: "{app}"; Tasks: startmenuicon
Name: "{autodesktop}\XAMPP コントロールパネル"; Filename: "{app}\xampp-control.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\xampp-control.exe"; Description: "XAMPP コントロールパネルを起動する"; WorkingDir: "{app}"; Flags: postinstall nowait skipifsilent unchecked

[UninstallDelete]
; インストール後に作るファイル
Type: files; Name: "{app}\install\install.sys"
Type: files; Name: "{app}\apache\conf\ssl.crt\server.crt"
Type: files; Name: "{app}\apache\conf\ssl.key\server.key"

[Code]
const
  VcRedistUrl = 'https://aka.ms/vc14/vc_redist.x64.exe';

{ ファイルのバージョンが Major.Minor.Build 以上か }
function VersionAtLeast(const FileName: String; Major, Minor, Build: Cardinal): Boolean;
var
  MS, LS, MinMS, MinLS: Cardinal;
begin
  MinMS := (Major shl 16) or Minor;
  MinLS := Build shl 16;
  Result := GetVersionNumbers(FileName, MS, LS) and ((MS > MinMS) or ((MS = MinMS) and (LS >= MinLS)));
end;

{ Apache Lounge の VS18 ビルドには Visual C++ ランタイム 14.51.36247 以上が必要 }
function InitializeSetup(): Boolean;
var
  ErrorCode: Integer;
begin
  Result := VersionAtLeast(ExpandConstant('{sys}\vcruntime140.dll'), 14, 51, 36247) and
    VersionAtLeast(ExpandConstant('{sys}\msvcp140.dll'), 14, 51, 36247);
  if not Result then
  begin
    if SuppressibleMsgBox('Apache {#ApacheVersion} の実行には、Microsoft Visual C++ 再頒布可能パッケージ（x64）14.51 以上が必要です。' + #13#10#13#10 +
      'ダウンロードを開きますか？ インストールしたあとで、このセットアップをもう一度実行してください。' + #13#10 + VcRedistUrl,
      mbConfirmation, MB_YESNO, IDNO) = IDYES then
      ShellExec('open', VcRedistUrl, '', '', SW_SHOWNORMAL, ewNoWait, ErrorCode);
  end;
end;

{ インストール先に使えない場合は、その理由を返す }
function CheckInstallDir(const Dir: String): String;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(Dir) do
    if (Ord(Dir[I]) <= 32) or (Ord(Dir[I]) > 126) then
    begin
      Result := 'XAMPP は、空白や日本語を含むフォルダでは動きません。C:\xampp のようなフォルダを指定してください。';
      Exit;
    end;
  if FileExists(AddBackslash(Dir) + 'xampp-control.exe') or FileExists(AddBackslash(Dir) + 'apache\bin\httpd.exe') then
    Result := 'このフォルダには既に XAMPP があります。既存の XAMPP を更新するときは、配布ページの update-xampp.bat を使ってください。';
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  Message: String;
begin
  Result := True;
  if CurPageID = wpSelectDir then
  begin
    Message := CheckInstallDir(WizardDirValue);
    if Message <> '' then
    begin
      MsgBox(Message, mbError, MB_OK);
      Result := False;
    end;
  end;
end;

{ サイレントインストールでも確かめる }
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := CheckInstallDir(ExpandConstant('{app}'));
end;

function RunHidden(const FileName, Params, WorkDir: String): Boolean;
var
  ResultCode: Integer;
begin
  Result := Exec(FileName, Params, WorkDir, SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0);
  if not Result then
    Log(Format('失敗しました（終了コード %d）: %s %s', [ResultCode, FileName, Params]));
end;

{ localhost 用の自己署名証明書を、この PC だけの鍵で作る }
function CreateCertificate(const App: String): Boolean;
var
  Config: String;
  Lines: TArrayOfString;
begin
  Config := ExpandConstant('{tmp}\openssl.cnf');
  SetArrayLength(Lines, 12);
  Lines[0] := '[req]';
  Lines[1] := 'distinguished_name = dn';
  Lines[2] := 'x509_extensions = v3';
  Lines[3] := 'prompt = no';
  Lines[4] := '[dn]';
  Lines[5] := 'CN = localhost';
  Lines[6] := '[v3]';
  Lines[7] := 'basicConstraints = critical, CA:FALSE';
  Lines[8] := 'keyUsage = critical, digitalSignature, keyEncipherment';
  Lines[9] := 'extendedKeyUsage = serverAuth';
  Lines[10] := 'subjectAltName = DNS:localhost, IP:127.0.0.1';
  Lines[11] := 'subjectKeyIdentifier = hash';
  SaveStringsToFile(Config, Lines, False);
  ForceDirectories(App + '\apache\conf\ssl.crt');
  ForceDirectories(App + '\apache\conf\ssl.key');
  Result := RunHidden(App + '\apache\bin\openssl.exe',
    'req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes -config "' + Config + '"' +
    ' -keyout "' + App + '\apache\conf\ssl.key\server.key" -out "' + App + '\apache\conf\ssl.crt\server.crt"', App);
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  App: String;
begin
  if CurStep <> ssPostInstall then
    Exit;
  App := ExpandConstant('{app}');

  { XAMPP 標準の手順（setup_xampp.bat と同じ）で、設定ファイルのパスをインストール先に書き換える }
  WizardForm.StatusLabel.Caption := '設定ファイルのパスをインストール先に合わせています...';
  if not RunHidden(App + '\php\php.exe', '-n -d output_buffering=0 install\install.php', App) then
    SuppressibleMsgBox('設定ファイルのパスを書き換えられませんでした。インストール先の setup_xampp.bat を実行してください。', mbError, MB_OK, IDOK);

  WizardForm.StatusLabel.Caption := 'HTTPS 用の証明書を作っています...';
  if not CreateCertificate(App) then
    SuppressibleMsgBox('HTTPS 用の証明書を作れませんでした。このままでは Apache が起動しないため、apache\makecert.bat で証明書を作ってください。', mbError, MB_OK, IDOK);
end;

function InitializeUninstall(): Boolean;
begin
  Result := SuppressibleMsgBox('アンインストールの前に、XAMPP コントロールパネルで Apache と MySQL を Stop してください。' + #13#10 +
    'htdocs に置いたファイルと、MySQL のデータ（mysql\data）は削除しません。続けますか？',
    mbConfirmation, MB_YESNO, IDYES) = IDYES;
end;
