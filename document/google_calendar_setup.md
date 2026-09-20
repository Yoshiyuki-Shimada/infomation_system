# Googleカレンダー連携の初回設定

1. Google CloudでGoogle Calendar APIを有効にします。
2. OAuth同意画面を設定し、種類が「デスクトップアプリ」のOAuthクライアントを作成します。
3. OAuthクライアントのJSONを運用PCへ保存します。
4. インフォメーションシステムを実行するWindowsユーザーで、次のコマンドを1回実行します。

```powershell
.\bin\setup_google_calendar_oauth.ps1 -CredentialsPath "C:\path\credentials.json"
```

認証情報は `database/runtime/google_calendar_auth.json` にWindowsユーザー暗号化で保存されます。このディレクトリはGitおよび更新パッケージの対象外です。予定名と説明は取得せず、表示データには時間帯、件数、市区町村だけを保存します。
