#!/usr/bin/env python3
"""`make cases` for onnx_radar_attention: radar_attention's tformer_case.py,
pointed at this app's build (onnx_radar_attention.elf / .readelf) and
writing onnx_radar_attention-<class>.ihex, for

    upload onnx_radar_attention <class>

main.c declares tf_features, tf_logits_golden, tf_true_class and tf_case_id
exactly as radar_attention does, so the same images apply.  Arguments are
tformer_case.py's (--classes, --bin, --out, --data, --weights).
"""
import sys
from pathlib import Path

RADAR_DIR = Path(__file__).resolve().parent.parent / 'radar_attention'
sys.path.insert(0, str(RADAR_DIR))
import tformer_case  # noqa: E402

tformer_case.APP = 'onnx_radar_attention'

if __name__ == '__main__':
    raise SystemExit(tformer_case.main())
