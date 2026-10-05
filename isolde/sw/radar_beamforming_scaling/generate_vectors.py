#!/usr/bin/env python3
"""Reuse the original scene and FP16 golden model, without requiring ONNX."""
from pathlib import Path
import sys

APP = Path(__file__).resolve().parent
sys.path.insert(0, str(APP.parent / 'radar_beamforming'))
import beamforming  # noqa: E402

if __name__ == '__main__':
    data = beamforming.prepare(seed=7)
    beamforming.emit_header(APP / 'inc/radar_vectors.h', data)
    print(f'Generated inc/radar_vectors.h; case={data["case_id"]}')
