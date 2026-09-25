#!/usr/bin/env python3
"""Test cases from the dataset, as ihex files for OpenOCD's load_image.

    python3 tformer_case.py                      # static, receding, crossing
    python3 tformer_case.py --classes approaching

For each class, takes that class's first sequence in the test split and writes
isolde/system/sw/bin/radar_attention-<class>.ihex. The file holds the 12 x 32
window at the address of tf_features[384], plus the FP16 reference logits
(tf_logits_golden), the true class and a case id, so the firmware's own check
still means something. Addresses come from the build's radar_attention.readelf,
so rebuild the firmware first and re-run this after every rebuild.

In the OpenOCD telnet session, after `source jtag_upload.tcl`:

    upload radar_attention static
"""
from __future__ import annotations

import argparse
import hashlib
import re
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import radar_scene as rs                                           # noqa: E402
import tformer as tf                                               # noqa: E402

APP = 'radar_attention'
BIN = HERE.parent.parent / 'system/sw/bin'
# name -> size in bytes, as main.c and the generated headers declare them.
SYMBOLS = {'tf_features': 768, 'tf_logits_golden': 8, 'tf_true_class': 4,
           'tf_case_id': 17}


def symbols(readelf_text):
    """Address of each SYMBOLS entry in a `readelf -a` listing."""
    found = {}
    for line in readelf_text.splitlines():
        parts = line.split()
        if len(parts) >= 8 and parts[3] == 'OBJECT' and parts[-1] in SYMBOLS:
            found.setdefault(parts[-1], []).append(
                (int(parts[1], 16), int(parts[2], 0)))
    for name, size in SYMBOLS.items():
        if name not in found:
            raise SystemExit(f'{name} is not in the build; rebuild {APP}')
        if len(found[name]) != 1:
            raise SystemExit(f'{name} appears {len(found[name])} times in the '
                             'build; expected exactly one')
        if found[name][0][1] != size:
            raise SystemExit(f'{name} is {found[name][0][1]} bytes, expected '
                             f'{size}; rebuild {APP}')
    return {name: entries[0][0] for name, entries in found.items()}


def case_bytes(features, logits, label):
    """The four objects' contents, keyed by symbol name."""
    window = np.stack([features[:, :tf.TILE_N], features[:, tf.TILE_N:]])
    window = np.ascontiguousarray(window, dtype=np.float16).astype('<f2')
    case_id = hashlib.sha256(window.tobytes()).hexdigest()[:16]
    return case_id, {
        'tf_features': window.tobytes(),
        'tf_logits_golden': np.asarray(logits, dtype=np.float16)
                              .astype('<f2').tobytes(),
        'tf_true_class': int(label).to_bytes(4, 'little'),
        'tf_case_id': case_id.encode() + b'\0'}


def write_ihex(path, addresses, contents):
    from intelhex import IntelHex
    image = IntelHex()
    for name, data in contents.items():
        for offset, byte in enumerate(data):
            image[addresses[name] + offset] = byte
    image.write_hex_file(str(path))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawTextHelpFormatter)
    parser.add_argument('--classes', nargs='+', choices=rs.CLASSES,
                        default=['static', 'receding', 'crossing'])
    parser.add_argument('--bin', type=Path, default=BIN,
                        help='where the radar_attention build put its files')
    parser.add_argument('--data', type=Path,
                        default=HERE / 'results/radar_sequences.npz')
    parser.add_argument('--weights', type=Path,
                        default=HERE / 'inc/tformer_weights.h')
    args = parser.parse_args(argv)

    elf, listing = args.bin / f'{APP}.elf', args.bin / f'{APP}.readelf'
    for path in (elf, listing, args.data, args.weights):
        if not path.exists():
            raise SystemExit(f'{path} not found')
    # The reference logits are only right for the weights the image carries.
    weights_id = re.search(r'#define TF_WEIGHTS_ID "(\w+)"',
                           args.weights.read_text()).group(1)
    if weights_id.encode() not in elf.read_bytes():
        raise SystemExit(f'{elf.name} was not built with {args.weights.name} '
                         f'(weights {weights_id}); rebuild {APP}')
    addresses = symbols(listing.read_text())
    weights = tf.Weights.from_header(args.weights)

    blob = np.load(args.data)
    x, y = blob['test_x'], blob['test_y']
    print(f'tf_features at 0x{addresses["tf_features"]:08x}')
    for name in args.classes:
        index = int(np.flatnonzero(y == rs.CLASSES.index(name))[0])
        features = x[index].astype(np.float16)
        logits = tf.forward_fp16(weights, features)
        predicted = rs.CLASSES[int(np.argmax(logits.astype(np.float32)))]
        case_id, contents = case_bytes(features, logits, y[index])
        path = args.bin / f'{APP}-{name}.ihex'
        write_ihex(path, addresses, contents)
        print(f'{path.name}: test[{index}] case {case_id}, true {name}, '
              f'expected {predicted}')
    print(f'OpenOCD, after `source jtag_upload.tcl`:  upload {APP} <class>')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
