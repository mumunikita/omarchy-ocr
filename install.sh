#!/bin/bash
# omarchy-ocr installer: dependencies, Python venv, models, scripts, systemd
# units, Hyprland hotkey.
#
# Usage:
#   ./install.sh
#   ./install.sh --hotkey "SUPER + ALT + PRINT" --obsidian
#   ./install.sh --always-on --skip-deps
#
# Run as your normal user, not as root.

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$HOME/.local/share/omarchy-ocr"
BIN_DIR="$HOME/.local/bin"
VENV_DIR="$HOME/.local/share/pix2text-venv"
UNIT_DIR="$HOME/.config/systemd/user"
CONF_DIR="$HOME/.config/omarchy-ocr"

HOTKEY=""
MODE=""
SKIP_DEPS=0
SKIP_MODELS=0
ASSUME_YES=0

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
  YELLOW=$'\033[33m'; RESET=$'\033[0m'
else
  BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; RESET=""
fi

info() { printf '%s==>%s %s\n' "$BOLD" "$RESET" "$*"; }
ok()   { printf '%s  ✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s  !%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '%s  ✗%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
omarchy-ocr installer

Опции:
  --hotkey "SUPER + ALT + O"   хоткей без интерактивного выбора
  --obsidian                   демон работает только при открытом Obsidian
  --always-on                  демон запускается при входе и живёт постоянно
  --skip-deps                  не устанавливать системные пакеты
  --skip-models                не скачивать модели (они уже есть)
  -y, --yes                    без вопросов, значения по умолчанию
  -h, --help                   эта справка
EOF
}

while (($#)); do
  case $1 in
    --hotkey)
      [[ -n ${2:-} ]] || die "После --hotkey нужна комбинация, например \"SUPER + ALT + O\"."
      HOTKEY=$2; shift 2 ;;
    --hotkey=*)   HOTKEY="${1#*=}"; shift ;;
    --obsidian)   MODE=obsidian; shift ;;
    --always-on)  MODE=always; shift ;;
    --skip-deps)  SKIP_DEPS=1; shift ;;
    --skip-models) SKIP_MODELS=1; shift ;;
    -y|--yes)     ASSUME_YES=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) die "Неизвестный аргумент: $1 (см. --help)" ;;
  esac
done

[[ $EUID -ne 0 ]] || die "Запусти установщик от обычного пользователя, не через sudo."
[[ -n ${HOME:-} ]] || die "HOME не задан."
[[ -f $SRC_DIR/lib/daemon.py ]] || die "Запусти install.sh из корня репозитория."

command -v hyprctl >/dev/null 2>&1 || die "hyprctl не найден. Нужен Hyprland."
systemctl --user show-environment >/dev/null 2>&1 || die "Нет пользовательской сессии systemd."

# --- 1. dependencies ---------------------------------------------------------

install_deps() {
  local need=() spec bin pkg
  for spec in \
    "grim:grim" "slurp:slurp" "hyprpicker:hyprpicker" \
    "wl-copy:wl-clipboard" "socat:socat" "jq:jq" \
    "uv:uv" "python3:python"; do
    bin=${spec%%:*}; pkg=${spec##*:}
    command -v "$bin" >/dev/null 2>&1 || need+=("$pkg")
  done
  if ! command -v omarchy-notification-send >/dev/null 2>&1 \
     && ! command -v notify-send >/dev/null 2>&1; then
    need+=("libnotify")
  fi

  ((${#need[@]})) || { ok "все системные зависимости на месте"; return; }

  if command -v pacman >/dev/null 2>&1; then
    info "Ставлю пакеты: ${need[*]}"
    sudo pacman -S --needed --noconfirm "${need[@]}"
  else
    die "Не хватает пакетов: ${need[*]}. Установи их вручную и запусти с --skip-deps."
  fi
}

# --- 2. python environment ---------------------------------------------------

install_python() {
  if [[ -x $VENV_DIR/bin/python ]] \
     && "$VENV_DIR/bin/python" -c 'import sys; raise SystemExit(0 if sys.version_info[:2] == (3, 12) else 1)' 2>/dev/null; then
    ok "виртуальное окружение уже есть (Python 3.12)"
  else
    info "Создаю виртуальное окружение ($VENV_DIR)"
    uv venv --clear --python 3.12 "$VENV_DIR"
  fi

  info "Ставлю Pix2Text, EasyOCR и CPU-сборку torch (первый раз это долго)"
  uv pip install --python "$VENV_DIR/bin/python" \
    --index-strategy unsafe-best-match \
    --extra-index-url https://download.pytorch.org/whl/cpu \
    pix2text easyocr 'rapidocr==3.9.2'
  ok "Python-пакеты установлены"
}

download_models() {
  info "Скачиваю модели OCR (~450 МБ, один раз)"
  "$VENV_DIR/bin/python" - <<'PY'
import logging
import os

logging.disable(logging.WARNING)
from pix2text import set_logger
set_logger(log_level=logging.ERROR)
from pix2text.text_formula_ocr import TextFormulaOCR

langs = [
    lang.strip()
    for lang in os.environ.get("OMARCHY_OCR_LANGS", "ru,en").split(",")
    if lang.strip()
]
TextFormulaOCR.from_config(
    total_configs={"languages": langs, "text": {"verbose": False}},
    enable_formula=True,
    device="cpu",
)
print("модели готовы")
PY
  ok "модели готовы"
}

# --- 3. files and units ------------------------------------------------------

install_files() {
  install -d "$APP_DIR" "$BIN_DIR" "$UNIT_DIR" "$CONF_DIR"

  install -m755 "$SRC_DIR/bin/omarchy-capture-formula" "$BIN_DIR/omarchy-capture-formula"
  install -m755 "$SRC_DIR/lib/obsidian_watch.sh" "$APP_DIR/obsidian_watch.sh"
  install -m644 "$SRC_DIR/lib/daemon.py" "$APP_DIR/daemon.py"
  install -m755 "$SRC_DIR/lib/pix2text_ocr.py" "$APP_DIR/pix2text_ocr.py"
  install -m644 "$SRC_DIR/README.md" "$APP_DIR/README.md"

  local threads idle
  threads=$(( $(nproc) - 1 ))
  if (( threads < 1 )); then threads=1; fi
  if (( threads > 8 )); then threads=8; fi

  if [[ $MODE == obsidian ]]; then
    idle=0
  else
    idle=3600
  fi

  sed -e "s|@HOME@|$HOME|g" -e "s|@THREADS@|$threads|g" -e "s|@IDLE@|$idle|g" \
    "$SRC_DIR/systemd/omarchy-ocr.service.in" > "$UNIT_DIR/omarchy-ocr.service"
  sed -e "s|@HOME@|$HOME|g" \
    "$SRC_DIR/systemd/omarchy-ocr-obsidian.service.in" > "$UNIT_DIR/omarchy-ocr-obsidian.service"

  printf '%s\n' "$MODE" > "$CONF_DIR/mode"
  ok "скрипты и systemd-юниты установлены"
}

# --- 4. hotkey ---------------------------------------------------------------

normalize_hotkey() {
  local raw=${1^^} key
  raw=$(printf '%s' "$raw" | tr -s ' ')
  raw=$(printf '%s' "$raw" | sed -E 's/ *\+ */ + /g; s/^ +| +$//g')
  [[ $raw == *" + "* ]] || return 1
  key=${raw##* + }
  case $key in
    SUPER|ALT|SHIFT|CTRL|CONTROL) return 1 ;;
  esac
  printf '%s\n' "$raw"
}

select_hotkey() {
  if [[ -n $HOTKEY ]]; then
    normalize_hotkey "$HOTKEY" || die "Некорректный хоткей: $HOTKEY"
    return
  fi

  if (( ASSUME_YES )) || [[ ! -t 0 ]]; then
    printf '%s\n' "SUPER + ALT + SHIFT + PRINT"
    return
  fi

  cat >&2 <<'EOF'

Выбери хоткей для распознавания:
  1) SUPER + ALT + SHIFT + PRINT  (по умолчанию)
  2) SUPER + ALT + PRINT
  3) SUPER + SHIFT + PRINT
  4) Другая комбинация
EOF

  local choice key
  while true; do
    read -r -p "Номер [1]: " choice </dev/tty
    case ${choice:-1} in
      1) printf '%s\n' "SUPER + ALT + SHIFT + PRINT"; return ;;
      2) printf '%s\n' "SUPER + ALT + PRINT"; return ;;
      3) printf '%s\n' "SUPER + SHIFT + PRINT"; return ;;
      4)
        read -r -p "Комбинация (например, SUPER + CTRL + O): " key </dev/tty
        if normalize_hotkey "$key"; then return; fi
        warn "Нужен модификатор и клавиша, например SUPER + ALT + O."
        ;;
      *) warn "Введи 1–4." ;;
    esac
  done
}

edit_lua_binding() {
  local file="$HOME/.config/hypr/bindings.lua"
  cp -a "$file" "$file.bak.$(date +%s)"
  HOTKEY="$HOTKEY" CMD="$BIN_DIR/omarchy-capture-formula" python3 - "$file" <<'PY'
import os, pathlib, re, sys

path = pathlib.Path(sys.argv[1])
hotkey = os.environ["HOTKEY"]
cmd = os.environ["CMD"]
block = (
    "-- >>> omarchy-ocr >>>\n"
    "-- Extract text + formulas (Markdown + LaTeX) via omarchy-ocr.\n"
    f'hl.unbind("{hotkey}")\n'
    f'o.bind("{hotkey}", "Extract text + formulas (OCR to LaTeX)", "{cmd}")\n'
    "-- <<< omarchy-ocr <<<\n"
)
text = path.read_text()

# Drop an older non-block binding for the same command, if any, so an upgrade
# from a manual install does not leave two bindings behind.
out, in_block = [], False
for line in text.splitlines(keepends=True):
    if "-- >>> omarchy-ocr >>>" in line:
        in_block = True
    if (not in_block and "omarchy-capture-formula" in line
            and line.lstrip().startswith("o.bind")):
        continue
    out.append(line)
    if "-- <<< omarchy-ocr <<<" in line:
        in_block = False
text = "".join(out)

pattern = re.compile(r"\n?-- >>> omarchy-ocr >>>.*?-- <<< omarchy-ocr <<<\n?", re.S)
if pattern.search(text):
    text = pattern.sub("\n" + block, text)
else:
    text = text.rstrip() + "\n\n" + block
path.write_text(text)
PY
}

edit_conf_binding() {
  local file="$HOME/.config/hypr/hyprland.conf"
  local mods key hyprmods
  mods=${HOTKEY% + *}
  key=${HOTKEY##* + }
  hyprmods=${mods// + / }
  cp -a "$file" "$file.bak.$(date +%s)"
  HYPRMODS="$hyprmods" KEY="$key" CMD="$BIN_DIR/omarchy-capture-formula" python3 - "$file" <<'PY'
import os, pathlib, re, sys

path = pathlib.Path(sys.argv[1])
block = (
    "# >>> omarchy-ocr >>>\n"
    f'bind = {os.environ["HYPRMODS"]}, {os.environ["KEY"]}, exec, {os.environ["CMD"]}\n'
    "# <<< omarchy-ocr <<<\n"
)
text = path.read_text()

out, in_block = [], False
for line in text.splitlines(keepends=True):
    if "# >>> omarchy-ocr >>>" in line:
        in_block = True
    if (not in_block and "omarchy-capture-formula" in line
            and line.lstrip().startswith("bind")):
        continue
    out.append(line)
    if "# <<< omarchy-ocr <<<" in line:
        in_block = False
text = "".join(out)

pattern = re.compile(r"\n?# >>> omarchy-ocr >>>.*?# <<< omarchy-ocr <<<\n?", re.S)
if pattern.search(text):
    text = pattern.sub("\n" + block, text)
else:
    text = text.rstrip() + "\n\n" + block
path.write_text(text)
PY
}

install_binding() {
  HOTKEY=$(select_hotkey)

  if [[ -f $HOME/.config/hypr/bindings.lua ]]; then
    edit_lua_binding
    ok "хоткей записан в ~/.config/hypr/bindings.lua"
  elif [[ -f $HOME/.config/hypr/hyprland.conf ]]; then
    edit_conf_binding
    ok "хоткей записан в ~/.config/hypr/hyprland.conf"
  else
    warn "Не нашёл конфиг Hyprland. Добавь вручную:"
    warn "  bind = ${HOTKEY% + *}, ${HOTKEY##* + }, exec, $BIN_DIR/omarchy-capture-formula"
  fi

  if command -v hyprctl >/dev/null 2>&1; then
    hyprctl reload >/dev/null 2>&1 || true
    sleep 0.3
    local errors
    errors=$(hyprctl configerrors 2>/dev/null || true)
    if [[ -n $errors ]]; then
      warn "Hyprland сообщает об ошибках конфига: $errors"
    fi
  fi
}

# --- 5. mode -----------------------------------------------------------------

choose_mode() {
  if [[ -n $MODE ]]; then
    printf '%s\n' "$MODE"
    return
  fi

  local default=always
  command -v obsidian >/dev/null 2>&1 && default=obsidian

  if (( ASSUME_YES )) || [[ ! -t 0 ]]; then
    printf '%s\n' "$default"
    return
  fi

  cat >&2 <<'EOF'

Демон OCR занимает ~1.4 ГБ RAM. Когда его держать запущенным?
  1) Только при открытом Obsidian (экономит память)
  2) Всегда (автозапуск при входе, выход после часа простоя)
EOF
  local choice
  read -r -p "Номер [1]: " choice </dev/tty
  case ${choice:-1} in
    2) printf '%s\n' always ;;
    *) printf '%s\n' obsidian ;;
  esac
}

enable_services() {
  systemctl --user daemon-reload

  if [[ $MODE == obsidian ]]; then
    systemctl --user disable --now omarchy-ocr.service >/dev/null 2>&1 || true
    systemctl --user enable omarchy-ocr-obsidian.service
    # Restart, not just start: sync_windows() must run to pick up an already
    # open Obsidian window and start the daemon.
    systemctl --user restart omarchy-ocr-obsidian.service
    ok "watcher включён: демон живёт только при открытом Obsidian"
  else
    systemctl --user disable --now omarchy-ocr-obsidian.service >/dev/null 2>&1 || true
    systemctl --user enable --now omarchy-ocr.service
    ok "демон включён в автозапуск (выход после часа простоя)"
  fi
}

# --- main --------------------------------------------------------------------

printf '\n%s=== omarchy-ocr: установка ===%s\n\n' "$BOLD" "$RESET"

if (( SKIP_DEPS )); then
  ok "проверка пакетов пропущена (--skip-deps)"
else
  info "Проверяю системные зависимости"
  install_deps
fi

MODE=$(choose_mode)
info "Режим: $([[ $MODE == obsidian ]] && echo 'только при открытом Obsidian' || echo 'всегда')"

info "Готовлю Python-окружение"
install_python

if (( SKIP_MODELS )); then
  ok "загрузка моделей пропущена (--skip-models)"
else
  download_models
fi

info "Устанавливаю скрипты и юниты"
install_files

info "Настраиваю хоткей"
install_binding

info "Включаю сервисы"
enable_services

sleep 1
printf '\n%sГотово.%s\n\n' "$GREEN" "$RESET"
printf '  Хоткей:  %s%s%s\n' "$BOLD" "$HOTKEY" "$RESET"
printf '  Режим:   %s\n' "$([[ $MODE == obsidian ]] && echo 'только при открытом Obsidian' || echo 'всегда')"
if [[ $MODE == obsidian ]]; then
  printf '  Демон:   запустится при открытии Obsidian\n'
else
  printf '  Демон:   %s\n' "$(systemctl --user is-active omarchy-ocr.service 2>/dev/null || true)"
fi
printf '\n  Выдели область экрана и нажми хоткей.\n'
printf '  Логи: %sjournalctl --user -u omarchy-ocr.service -f%s\n\n' "$DIM" "$RESET"
