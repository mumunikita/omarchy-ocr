#!/bin/bash
# Remove omarchy-ocr: services, scripts, hotkey binding.
# Models and the Python venv are kept unless --purge is given.

set -euo pipefail

APP_DIR="$HOME/.local/share/omarchy-ocr"
BIN_DIR="$HOME/.local/bin"
VENV_DIR="$HOME/.local/share/pix2text-venv"
UNIT_DIR="$HOME/.config/systemd/user"
CONF_DIR="$HOME/.config/omarchy-ocr"

PURGE=0
for arg in "$@"; do
  case $arg in
    --purge) PURGE=1 ;;
    -h|--help)
      echo "Usage: ./uninstall.sh [--purge]"
      echo "  --purge  also remove the Python venv and downloaded models"
      exit 0
      ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

echo "==> Останавливаю сервисы"
systemctl --user disable --now omarchy-ocr-obsidian.service >/dev/null 2>&1 || true
systemctl --user disable --now omarchy-ocr.service >/dev/null 2>&1 || true

echo "==> Удаляю юниты и скрипты"
rm -f "$UNIT_DIR/omarchy-ocr.service" "$UNIT_DIR/omarchy-ocr-obsidian.service"
systemctl --user daemon-reload
rm -rf "$APP_DIR" "$CONF_DIR"
rm -f "$BIN_DIR/omarchy-capture-formula"

echo "==> Убираю хоткей из конфига Hyprland"
python3 - <<'PY'
import pathlib, re

pattern = re.compile(r"\n?(?:--|#) >>> omarchy-ocr >>>.*?(?:--|#) <<< omarchy-ocr <<<\n?", re.S)
for path in (
    pathlib.Path.home() / ".config/hypr/bindings.lua",
    pathlib.Path.home() / ".config/hypr/hyprland.conf",
):
    if not path.is_file():
        continue
    text = path.read_text()
    if pattern.search(text):
        path.with_name(path.name + ".bak.omarchy-ocr").write_text(text)
        path.write_text(pattern.sub("\n", text))
        print(f"  {path}")
PY

if command -v hyprctl >/dev/null 2>&1; then
  hyprctl reload >/dev/null 2>&1 || true
fi

if (( PURGE )); then
  echo "==> Удаляю venv и модели"
  echo "    (venv, ~/.pix2text и ~/.EasyOCR могут использоваться другими программами)"
  rm -rf "$VENV_DIR" "$HOME/.pix2text" "$HOME/.EasyOCR"
fi

echo "Готово."
