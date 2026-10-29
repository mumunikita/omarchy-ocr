#!/usr/bin/env python3
"""Persistent OCR daemon: Pix2Text text + formulas, models loaded once.

Uses EasyOCR for text (ru + en) and Pix2Text MFD/MFR for formulas. The models
stay in memory between requests, so a hotkey press only pays inference time.

Requests are newline-terminated image paths over a Unix socket; responses are:

    OK\n<markdown>        on success
    ERR\n<message>       on failure

Environment:
    OMARCHY_OCR_IDLE          seconds without requests before exit (0 = never)
    OMARCHY_OCR_LANGS         EasyOCR language codes, comma-separated
    OMARCHY_OCR_RESIZED_SHAPE image width used by the OCR engine
    OMARCHY_OCR_MFD_CONF      formula detector confidence threshold
"""

import logging
import os
import re
import signal
import socket
import sys
import time

from PIL import Image

# Leave a couple of cores for the desktop.
_CPUS = os.cpu_count() or 4
THREADS = max(1, min(8, _CPUS - 1))
os.environ.setdefault("OMP_NUM_THREADS", str(THREADS))
os.environ.setdefault("MKL_NUM_THREADS", str(THREADS))

import torch  # noqa: E402

torch.set_num_threads(THREADS)
try:
    torch.set_num_interop_threads(1)
except RuntimeError:
    pass

from pix2text import set_logger  # noqa: E402
from pix2text.text_formula_ocr import TextFormulaOCR  # noqa: E402

set_logger(log_level=logging.ERROR)
logging.disable(logging.WARNING)

SOCK_PATH = os.path.join(
    os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "omarchy-ocr.sock"
)
IDLE_TIMEOUT = int(os.environ.get("OMARCHY_OCR_IDLE", "3600"))

# Accept both EasyOCR codes ("ru,en") and the Tesseract-style value used by
# older setups ("eng+rus"), so an inherited environment cannot break OCR.
_LANG_ALIASES = {
    "eng": "en",
    "rus": "ru",
    "ukr": "uk",
    "deu": "de",
    "fra": "fr",
    "spa": "es",
    "ita": "it",
    "por": "pt",
    "pol": "pl",
    "ces": "cs",
    "tur": "tr",
    "ara": "ar",
    "jpn": "ja",
    "kor": "ko",
    "chi_sim": "ch_sim",
    "chi_tra": "ch_tra",
}


def _parse_langs(value):
    langs = []
    for part in re.split(r"[+,]", value):
        part = part.strip().lower()
        if part:
            langs.append(_LANG_ALIASES.get(part, part))
    return langs or ["ru", "en"]


LANGS = _parse_langs(os.environ.get("OMARCHY_OCR_LANGS", "ru,en"))
RESIZED_SHAPE = int(os.environ.get("OMARCHY_OCR_RESIZED_SHAPE", "768"))
# Default 0.25 lets the detector mistake Cyrillic diaeresis marks (ё) for math
# accents. Real formulas score ~0.7+, so 0.5 keeps them and drops the noise.
MFD_CONF = float(os.environ.get("OMARCHY_OCR_MFD_CONF", "0.5"))

_engine = None


def _build_engine():
    engine = TextFormulaOCR.from_config(
        total_configs={
            "languages": LANGS,
            "text": {"verbose": False},
        },
        enable_formula=True,
        device="cpu",
    )
    mfd = getattr(engine, "mfd", None)
    if mfd is not None:
        original_detect = mfd.detect

        def detect(*args, **kwargs):
            kwargs.setdefault("conf", MFD_CONF)
            return original_detect(*args, **kwargs)

        mfd.detect = detect
    return engine


def get_engine():
    global _engine
    if _engine is None:
        _engine = _build_engine()
    return _engine


def ocr_image(path):
    engine = get_engine()
    img = Image.open(path).convert("RGB")
    text = engine.recognize(
        img,
        return_text=True,
        resized_shape=RESIZED_SHAPE,
        auto_line_break=True,
    )

    # Drop empty/whitespace-only artifacts (e.g. stray quote marks the text
    # detector sometimes hallucinates next to a formula box).
    lines = [line.rstrip() for line in text.splitlines()]
    cleaned = [
        line for line in lines if line.strip() not in {"", '"', "'", "“", "”"}
    ]
    return "\n".join(cleaned).strip()


def _remove_socket():
    try:
        os.unlink(SOCK_PATH)
    except OSError:
        pass


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "--once":
        print(ocr_image(sys.argv[2]))
        return 0

    # A leftover socket from a killed daemon must not look like a live one.
    _remove_socket()

    def _on_signal(_signum, _frame):
        _remove_socket()
        sys.exit(0)

    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)

    # Load the models before opening the socket: once it exists, we are ready.
    get_engine()

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(SOCK_PATH)
    os.chmod(SOCK_PATH, 0o600)
    server.listen(4)
    server.settimeout(30)

    last_request = time.time()
    try:
        while True:
            try:
                conn, _ = server.accept()
            except socket.timeout:
                if IDLE_TIMEOUT > 0 and time.time() - last_request > IDLE_TIMEOUT:
                    break
                continue
            last_request = time.time()
            with conn:
                conn.settimeout(180)
                try:
                    data = b""
                    while not data.endswith(b"\n"):
                        chunk = conn.recv(4096)
                        if not chunk:
                            break
                        data += chunk
                    path = data.decode("utf-8", "replace").strip()
                    if not path:
                        conn.sendall(b"ERR\nempty request\n")
                        continue
                    markdown = ocr_image(path)
                    conn.sendall(b"OK\n" + markdown.encode("utf-8"))
                except Exception as exc:  # keep the daemon alive
                    message = f"{type(exc).__name__}: {exc}"[:500]
                    conn.sendall(b"ERR\n" + message.encode("utf-8"))
    finally:
        server.close()
        _remove_socket()
    return 0


if __name__ == "__main__":
    sys.exit(main())
