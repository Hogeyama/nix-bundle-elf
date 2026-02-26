---
name: nix-setup
description: Install Nix in environments where it is not available. Use when you need to run nix commands like `nix flake check`, `nix build`, `nix develop` but Nix is not installed.
user-invocable: false
---

# Nix Setup

Nixがインストールされていない環境でNixコマンドを実行する必要がある場合、以下の手順でセットアップする。

## 前提条件の確認

```bash
which nix 2>/dev/null && echo "Nix is already installed" || echo "Nix is not installed"
```

Nixがすでにインストールされている場合はこの手順をスキップする。

## インストール手順

Determinate Systems の nix-installer バイナリを GitHub Releases から直接ダウンロードして実行する。

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

## オプションの説明

- `--no-confirm`: 対話的な確認をスキップする
- `--init none`: systemdが存在しないコンテナ環境向けのオプション
- `--extra-conf "sandbox = false"`: コンテナ内ではサンドボックスが動作しないため無効化する
