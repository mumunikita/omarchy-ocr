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
- **Гибкий жизненный цикл**: только при открытом Obsidian, по расписанию (дни недели + часы) или всегда.
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
2. Спросит режим работы демона (Obsidian / расписание / всегда).
3. Создаст venv `~/.local/share/pix2text-venv` и поставит Pix2Text, EasyOCR и CPU-сборку torch.
4. Скачает модели (~450 МБ) в `~/.pix2text` и `~/.EasyOCR`.
5. Скопирует скрипты в `~/.local/share/omarchy-ocr` и `~/.local/bin`.
6. Спросит хоткей и запишет его в конфиг Hyprland.
7. Включит нужные systemd-юниты.

Первый запуск занимает несколько минут: качаются пакеты и модели.

### Без вопросов

```bash
./install.sh --hotkey "SUPER + ALT + PRINT" --obsidian
./install.sh --schedule "09:00-18:00" --days "1-5"
./install.sh --always-on --skip-deps --skip-models
```

| Опция | Значение |
|---|---|
| `--hotkey "..."` | хоткей без интерактивного выбора |
| `--obsidian` | демон только при открытом Obsidian |
| `--schedule "09:00-18:00"` | демон работает по расписанию |
| `--days "1-5"` | дни недели для расписания (`1`=Пн … `7`=Вс) |
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

Если выбран режим «только при Obsidian» и он закрыт, или выбран режим
расписания и текущее время вне окна, демон не запускается: срабатывает
резервный one-shot режим (~15–20 с), и в памяти ничего не остаётся висеть.

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
| **Расписание** | Демон запущен только внутри заданного окна времени и в выбранные дни. Obsidian при этом не важен. |
| **Всегда** | Демон в автозапуске, сам выходит после часа без запросов. |

Watcher работает на событийном сокете Hyprland (`.socket2.sock`) и
отслеживает несколько окон Obsidian по адресам. Дополнительно он раз в
30 секунд проверяет часы, поэтому переходы по расписанию могут
запаздывать до 30 секунд. Класс окна определяется по подстроке
`obsidian` (`md.obsidian.Obsidian`).

### Расписание

Формат окна — `HH:MM-HH:MM`, дни — номера ISO (`1` — понедельник,
`7` — воскресенье). Можно указывать диапазоны и списки: `1-5`,
`1,3,5`, `6-7`.

```text
09:00-18:00   # будни, днём
22:00-06:00   # ночная смена, переход через полночь поддерживается
00:00-23:59   # почти весь день (для «совсем всегда» есть режим always)
```

Конец окна не включается: окно `09:00-18:00` работает до `17:59:59`.
Если время начала больше времени конца, окно считается ночным. Для
ночного окна день берётся по дате начала: `22:00-06:00` с днями `1-5`
включает ночь с пятницы на субботу до `06:00`.

Настройки хранятся в файлах:

| Файл | Значение |
|---|---|
| `~/.config/omarchy-ocr/mode` | `obsidian`, `schedule` или `always` |
| `~/.config/omarchy-ocr/schedule` | окно `HH:MM-HH:MM`; пусто — без ограничения |
| `~/.config/omarchy-ocr/days` | `1-7`, `1-5`, `1,3,5`; пусто — все дни |

Переключить режим вручную:

```bash
echo schedule > ~/.config/omarchy-ocr/mode
echo "09:00-18:00" > ~/.config/omarchy-ocr/schedule
echo "1-5" > ~/.config/omarchy-ocr/days
systemctl --user restart omarchy-ocr-obsidian.service  # применить сразу
```

Watcher и так перечитывает файлы раз в 30 секунд, перезапуск нужен только
чтобы не ждать.

Вернуться к Obsidian:

```bash
echo obsidian > ~/.config/omarchy-ocr/mode
: > ~/.config/omarchy-ocr/schedule
: > ~/.config/omarchy-ocr/days
systemctl --user restart omarchy-ocr-obsidian.service
```

В режиме `obsidian` пустой `schedule` означает «без ограничения по
времени». Если заполнить `schedule` и `days`, демон будет работать только
когда Obsidian открыт **и** время попадает в окно. Это удобно, если не
хочется держать 1.4 ГБ RAM за пределами рабочих часов.

Проще всего задать расписание установщиком:

```bash
./install.sh --schedule "09:00-18:00" --days "1-5"
```

Повторная установка в режимах `obsidian` или `always` очищает файлы
`schedule` и `days`. Если нужна комбинация «Obsidian + рабочие часы»,
установи режим `obsidian`, а затем заполни эти файлы вручную.

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

Режим и расписание читают watcher и скрипт захвата. Их можно задать
файлами (см. выше) или переменными окружения — последние удобны для
проверки и переопределяют файлы:

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `OMARCHY_OCR_MODE` | из файла `mode` (`obsidian`) | `obsidian`, `schedule`, `always` |
| `OMARCHY_OCR_SCHEDULE` | из файла `schedule` (пусто) | окно `HH:MM-HH:MM` |
| `OMARCHY_OCR_SCHEDULE_DAYS` | из файла `days` (`1-7`) | дни недели |

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

**Демон не запускается по расписанию.** Проверь режим, окно и дни, затем
перезапусти watcher или подожди до 30 секунд:

```bash
cat ~/.config/omarchy-ocr/mode
cat ~/.config/omarchy-ocr/schedule
cat ~/.config/omarchy-ocr/days
date +'%H:%M, день %u'
systemctl --user restart omarchy-ocr-obsidian.service  # или подожди до 30 с
journalctl --user -u omarchy-ocr-obsidian.service -n 30
```

Помни, что проверка часов идёт раз в 30 секунд, а конец окна не
включается. Если в `schedule` опечатка, watcher пишет предупреждение в
лог и работает без ограничения по времени.

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

Установщик перезапишет скрипты и юниты, заново спросит режим, расписание
и хоткей, а также сделает резервную копию конфига Hyprland.

## Удаление

```bash
./uninstall.sh           # сервисы, скрипты, хоткей
./uninstall.sh --purge   # плюс venv и модели (~2.5 ГБ)
```

## Лицензия

MIT. См. [LICENSE](LICENSE).
