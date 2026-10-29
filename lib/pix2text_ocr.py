#!/usr/bin/env python3
"""One-shot fallback: recognize text + formulas on an image, print Markdown.

Used by omarchy-capture-formula when the daemon is not running (for example
when Obsidian is closed). Slow (~15 s) because every model is loaded again.
"""

import logging
import os
import re
import sys
import warnings

warnings.filterwarnings("ignore")

# Keep the desktop responsive: don't let torch grab every core.
_cpus = os.cpu_count() or 4
os.environ.setdefault("OMP_NUM_THREADS", str(max(1, _cpus // 2)))
os.environ.setdefault("MKL_NUM_THREADS", str(max(1, _cpus // 2)))

from pix2text import Pix2Text, set_logger  # noqa: E402

set_logger(log_level=logging.ERROR)
logging.disable(logging.WARNING)

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
MFD_CONF = float(os.environ.get("OMARCHY_OCR_MFD_CONF", "0.5"))

CONFIG = {
    "text_formula": {
        # EasyOCR backend is required for anything beyond English/Chinese.
        "languages": LANGS,
        "text": {"verbose": False},
    }
}


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: pix2text_ocr.py <image>", file=sys.stderr)
        return 2

    p2t = Pix2Text.from_config(
        total_configs=CONFIG,
        enable_formula=True,
        enable_table=False,
        device="cpu",
    )

    mfd = getattr(p2t.text_formula_ocr, "mfd", None)
    if mfd is not None:
        original_detect = mfd.detect

        def detect(*args, **kwargs):
            kwargs.setdefault("conf", MFD_CONF)
            return original_detect(*args, **kwargs)

        mfd.detect = detect

    text = p2t.recognize(
        sys.argv[1],
        file_type="text_formula",
        return_text=True,
        resized_shape=RESIZED_SHAPE,
        auto_line_break=True,
    )

    # Drop empty/whitespace-only artifacts (e.g. stray quote marks the text
    # detector sometimes hallucinates next to a formula box).
    lines = [line.rstrip() for line in text.splitlines()]
    cleaned = [line for line in lines if line.strip() not in {"", '"', "'", "“", "”"}]
    sys.stdout.write("\n".join(cleaned).strip() + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
