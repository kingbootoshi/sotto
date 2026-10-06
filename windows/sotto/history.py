"""History: History/yyyy-mm-dd/<uuid>.wav + <uuid>.json (atomic write)."""
import datetime as dt
import json
import os
import uuid

from .config import HISTORY_DIR


def new_take():
    tid = str(uuid.uuid4())
    d = HISTORY_DIR / dt.date.today().isoformat()
    d.mkdir(parents=True, exist_ok=True)
    return tid, d / f"{tid}.wav"


def finalize(wav_path, **record):
    record.setdefault("id", wav_path.stem)
    record.setdefault("createdAt", dt.datetime.now().isoformat(timespec="seconds"))
    out = wav_path.with_suffix(".json")
    tmp = out.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(record, indent=2, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, out)


def unfinished():
    if not HISTORY_DIR.exists():
        return []
    return sorted(p for p in HISTORY_DIR.glob("*/*.wav") if not p.with_suffix(".json").exists())


def last_text():
    recs = sorted(HISTORY_DIR.glob("*/*.json"), key=lambda p: p.stat().st_mtime, reverse=True)
    for p in recs:
        try:
            t = json.loads(p.read_text(encoding="utf-8")).get("text")
            if t:
                return t
        except Exception:
            pass
    return None
