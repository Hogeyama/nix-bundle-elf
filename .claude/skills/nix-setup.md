# Nix Setup

Nixがインストールされていない環境で `nix flake check` などのNixコマンドを実行する前に、以下の手順でNixをセットアップする。

## 前提条件の確認

```bash
which nix 2>/dev/null && echo "Nix is already installed" || echo "Nix is not installed"
```

Nixがすでにインストールされている場合はインストール手順をスキップしてよい。

## インストール手順

Determinate Systems の nix-installer を使用する。

### 方法1: curl経由（推奨）

```bash
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install linux \
  --no-confirm \
  --init none \
  --extra-conf "sandbox = false"
```

### 方法2: GitHubリリースからバイナリ直接ダウンロード（方法1が403等で失敗する場合）

```bash
curl -sL -o /tmp/nix-installer https://github.com/DeterminateSystems/nix-installer/releases/latest/download/nix-installer-x86_64-linux
chmod +x /tmp/nix-installer
/tmp/nix-installer install linux \
  --no-confirm \
  --init none \
  --extra-conf "sandbox = false"
```

## インストール後のPATH設定

```bash
export PATH="/nix/var/nix/profiles/default/bin:$PATH"
```

## 使用例: flake check の実行

```bash
nix flake check
```

## オプションの説明

- `--no-confirm`: 対話的な確認をスキップする
- `--init none`: systemdが存在しないコンテナ環境向けのオプション
- `--extra-conf "sandbox = false"`: コンテナ内ではサンドボックスが動作しないため無効化する
- インストール後、`/nix/var/nix/profiles/default/bin` にPATHを通す必要がある
