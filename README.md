# omarchy-ocr

Локальное распознавание **текста и математических формул** с экрана в Markdown + LaTeX для [Omarchy](https://omarchy.org/) / Hyprland.

Выделяешь область экрана, нажимаешь хоткей — в буфере обмена уже готовый Markdown:

```markdown
Теорема Пифагора: $a^{2}+b^{2}=c^{2}$ верна для прямоугольных
треугольников, а $E=m c^{2}$ связывает массу и энергию.
```

Никаких облаков и API-ключей: всё считается локально на CPU (GPU).

## Возможности

- **Русский и английский текст** через EasyOCR.
- **Формулы → LaTeX**: строчные `$...$` и выключные `$$...$$` (Pix2Text MFD + MFR).
- **Быстро**: демон держит модели в памяти, распознавание занимает 1–3 секунды вместо 15–20.
- **Живёт только при открытом Obsidian** (по желанию): закрыл Obsidian — 1.4 ГБ RAM освободились.
- **Выбор хоткея** при установке, включая свою комбинацию.
- **Fallback**: если демон недоступен, срабатывает медленный one-shot режим, а не ошибка.
- Распознавание происходит в фоне

## Требования

- Arch Linux / Omarchy, Hyprland (Wayland).
- `grim`, `slurp`, `hyprpicker`, `wl-clipboard`, `socat`, `jq`, `uv`, `python`.
- ~2.5 ГБ на диске (venv + torch CPU + модели).
- ~1.4 ГБ RAM, пока демон запущен.

Установщик сам поставит недостающие пакеты через `pacman` (на других дистрибутивах установи их вручную и запусти с `--skip-deps`).

## Установка

```bash
git clone https://github.com/mumunikita/omarchy-ocr.git
cd omarchy-ocr
./install.sh
```

Установщик:

1. Проверит и поставит системные зависимости.
2. Спросит режим работы демона (Obsidian / всегда).
3. Создаст venv `~/.local/share/pix2text-venv` и поставит Pix2Text, EasyOCR и CPU-сборку torch.
4. Скачает модели (~450 МБ) в `~/.pix2text` и `~/.EasyOCR`.
5. Скопирует скрипты в `~/.local/share/omarchy-ocr` и `~/.local/bin`.
6. Спросит хоткей и запишет его в конфиг Hyprland.
7. Включит нужные systemd-юниты.

Первый запуск занимает несколько минут: качаются пакеты и модели.

### Без вопросов

```bash
./install.sh --hotkey "SUPER + ALT + PRINT" --obsidian
./install.sh --always-on --skip-deps --skip-models
```

| Опция | Значение |
|---|---|
| `--hotkey "..."` | хоткей без интерактивного выбора |
| `--obsidian` | демон только при открытом Obsidian |
| `--always-on` | демон в автозапуске, выход после часа простоя |
| `--skip-deps` | не трогать системные пакеты |
| `--skip-models` | не скачивать модели повторно |
| `-y`, `--yes` | значения по умолчанию без вопросов |

### Выбор хоткея

По умолчанию предлагаются:

- `SUPER + ALT + SHIFT + PRINT`
- `SUPER + ALT + PRINT`
- `SUPER + SHIFT + PRINT`
- своя комбинация

Хоткей записывается в `~/.config/hypr/bindings.lua` (Omarchy 4) или
`~/.config/hypr/hyprland.conf` (классический Hyprland) в блок с маркерами
`>>> omarchy-ocr >>>`. Перед изменением делается резервная копия конфига.
Поменять хоткей можно повторным запуском установщика.

## Использование

1. Нажми хоткей.
2. Выдели область с текстом или формулами.
3. Дождись уведомления «Текст и формулы в буфере».
4. Вставь куда нужно.

Если Obsidian закрыт и выбран режим «только при Obsidian», демон не
запускается: срабатывает резервный one-shot режим (~15–20 с), и в памяти
ничего не остаётся висеть.

## Как это работает

```
hyprpicker + slurp + grim
        │  PNG
        ▼
omarchy-capture-formula ──socat──▶ omarchy-ocr.service (демон)
                                    ├─ MFD (Pix2Text) → где формулы
                                    ├─ MFR (Pix2Text) → LaTeX формул
                                    └─ EasyOCR        → текст (ru + en)
        ◀──────── OK + Markdown ────┘
        │
        ▼
     wl-copy + уведомления
```

Демон слушает Unix-сокет `$XDG_RUNTIME_DIR/omarchy-ocr.sock`. Модели
загружаются один раз при старте демона, а не на каждое нажатие.

### Жизненный цикл

| Режим | Поведение |
|---|---|
| **Obsidian** (по умолчанию, если Obsidian установлен) | `omarchy-ocr-obsidian.service` слушает события Hyprland: открылось окно Obsidian — демон запущен, закрылось последнее — остановлен. |
| **Всегда** | Демон в автозапуске, сам выходит после часа без запросов. |

Watcher работает на событийном сокете Hyprland (`.socket2.sock`), без
опроса, и отслеживает несколько окон Obsidian по адресам. Класс окна
определяется по подстроке `obsidian` (`md.obsidian.Obsidian`).

## Скорость

| Случай | Время |
|---|---|
| Только текст | ~0.7–0.9 с |
| Формулы в строке | ~2.3 с |
| Текст + 2 формулы | ~2.9 с |
| Полный цикл с выделением и буфером | ~3–5 с |
| Холодный старт демона | ~11 с, в фоне |

Для сравнения: one-shot вариант без демона — 15–20 с на каждый вызов.

## Настройки

Переменные окружения юнита `~/.config/systemd/user/omarchy-ocr.service`:

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `OMARCHY_OCR_LANGS` | `ru,en` | языки EasyOCR; принимает и `ru,en`, и `eng+rus` |
| `OMARCHY_OCR_IDLE` | `0` / `3600` | простой до выхода, секунды (`0` — никогда) |
| `OMARCHY_OCR_RESIZED_SHAPE` | `768` | ширина, до которой масштабируется картинка |
| `OMARCHY_OCR_MFD_CONF` | `0.5` | порог детектора формул |

Порог `0.5` важен: при дефолтном `0.25` детектор принимает точки над «ё»
за математические акценты и портит русский текст. Реальные формулы дают
уверенность ~0.7–0.9.

Watcher можно перенастроить на другое приложение:

```bash
systemctl --user edit omarchy-ocr-obsidian.service
# [Service]
# Environment=OMARCHY_OCR_WATCH_PATTERN=zathura
```

`OMARCHY_OCR_SERVICE` позволяет управлять другим юнитом (по умолчанию
`omarchy-ocr.service`).

После изменения юнита:

```bash
systemctl --user daemon-reload
systemctl --user restart omarchy-ocr-obsidian.service
```

## Управление

```bash
systemctl --user status omarchy-ocr-obsidian.service   # watcher
systemctl --user status omarchy-ocr.service            # демон
journalctl --user -u omarchy-ocr.service -f            # логи
```

## Если что-то не работает

**Хоткей не срабатывает.** Проверь конфиг Hyprland:

```bash
hyprctl configerrors
```

и что блок `>>> omarchy-ocr >>>` есть в `~/.config/hypr/bindings.lua`
или `~/.config/hypr/hyprland.conf`.

**Демон не отвечает.** Посмотри логи и проверь сокет:

```bash
journalctl --user -u omarchy-ocr.service -n 50
printf '%s\n' /путь/картинка.png | socat - UNIX-CONNECT:"$XDG_RUNTIME_DIR/omarchy-ocr.sock"
```

**Ошибка `cannot import name 'resolve_model_key'`.** `cnstd` (зависимость
Pix2Text) ломается с `rapidocr >= 3.10`. Версия закреплена установщиком:

```bash
uv pip install --python ~/.local/share/pix2text-venv/bin/python 'rapidocr==3.9.2'
```

**Модели не скачались.** Удали `~/.pix2text` и `~/.EasyOCR`, затем:

```bash
./install.sh --skip-deps
```

**Плохое качество.** Выделяй область плотно по тексту, без больших полей и
размытия. Для мелкого текста помогает увеличение масштаба страницы.

**Нет уведомлений.** Нужен `omarchy-notification-send` (Omarchy) или
`notify-send` (`libnotify`). На Omarchy уже есть.

## Обновление

```bash
cd omarchy-ocr
git pull
./install.sh --skip-deps --skip-models
```

Установщик перезапишет скрипты и юниты, сохранит выбранный хоткей
(спросит заново) и сделает резервную копию конфига Hyprland.

## Удаление

```bash
./uninstall.sh           # сервисы, скрипты, хоткей
./uninstall.sh --purge   # плюс venv и модели (~2.5 ГБ)
```

## Лицензия

MIT. См. [LICENSE](LICENSE).
