#!/usr/bin/env python3
"""Live window for onnx_radar_attention: radar_attention's UART view plus the
ONNX model the firmware runs.

    python3 onnx_uart_viewer.py --port /dev/ttyUSB3 --model models/tformer_encoder.onnx
    python3 onnx_uart_viewer.py --replay build-host/uart.log --model ...   # no board

Left: the feature window and the decision, exactly as tformer_uart_viewer.py
draws them (its UART decoding is reused unchanged).  Right: the ONNX graph,
Netron style -- one box per node, the tensor shapes on the edges, the
residual connections on the side.  Click a node for its properties
(attributes, inputs with their weight shapes and ranges) in the panel at the
bottom left.  While a run arrives the input node is highlighted; with the
logits the graph is marked as executed and the output shows the decision.

--netron also opens the model in the real Netron (pip install netron), in the
browser, next to this window.
"""
from __future__ import annotations

import argparse
import queue
import re
import sys
import threading
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'radar_attention'))
import tformer_uart_viewer as tv  # noqa: E402

COST = re.compile(r'\[TFORMER\] launches=(\d+) barriers=(\d+)$')

# Netron-like node colors, by kind; text is white on all of them.
KIND_COLOR = {'MatMul': '#33598a', 'Gemm': '#33598a', 'Add': '#4b4b4b',
              'ReduceMean': '#2b6f55', 'isolde': '#6f4a8e'}
IO_FACE, EDGE, DONE = '#eeedea', '#8a8a8a', '#fbe3d7'


class Decoder(tv.Decoder):
    """tformer_uart_viewer's decoder, plus the schedule cost line."""

    def __init__(self):
        super().__init__()
        self.cost = None

    def start(self, case_id, mode):
        super().start(case_id, mode)
        self.cost = None

    def line(self, raw):
        super().line(raw)
        try:
            cost = COST.search(raw.decode('ascii').strip())
        except UnicodeDecodeError:
            return
        if cost and self.case_id is not None:
            self.cost = (int(cost.group(1)), int(cost.group(2)))


# ---------------------------------------------------------------------------
# The ONNX graph
# ---------------------------------------------------------------------------
def shape_of(info):
    dims = info.type.tensor_type.shape.dim
    return tuple(d.dim_value if d.HasField('dim_value') else d.dim_param
                 for d in dims)


def fmt_shape(shape):
    return '×'.join(str(d) for d in shape) if shape else 'scalar'


def short(name):
    return name.replace('encoder.', '')


class Graph:
    """Nodes, tensors and a top-to-bottom layout of an ONNX model."""

    def __init__(self, path):
        import onnx
        from onnx import numpy_helper
        model = onnx.load(str(path))
        g = model.graph
        self.path = Path(path)
        self.inits = {t.name: numpy_helper.to_array(t) for t in g.initializer}
        self.shapes = {}
        for info in list(g.input) + list(g.output) + list(g.value_info):
            self.shapes[info.name] = shape_of(info)
        for name, array in self.inits.items():
            self.shapes[name] = array.shape
        self.inputs = [i.name for i in g.input if i.name not in self.inits]
        self.outputs = [o.name for o in g.output]
        self.opset = {o.domain or 'ai.onnx': o.version
                      for o in model.opset_import}

        # One entry per box: graph inputs, nodes, graph outputs.
        self.boxes = []
        producer = {}
        for name in self.inputs:
            producer[name] = len(self.boxes)
            self.boxes.append(dict(kind='input', title=name, sub=fmt_shape(
                self.shapes.get(name)), tensors=[name], node=None))
        for node in g.node:
            weights = [i for i in node.input if i in self.inits]
            wtxt = ' '.join(
                f'{i.rsplit(".", 1)[-1]}' for i in weights
                if self.inits[i].ndim >= 2)
            wshape = {fmt_shape(self.inits[i].shape) for i in weights
                      if self.inits[i].ndim >= 2}
            sub = short(node.name)
            if wtxt:
                sub += f'   {wtxt} ' + ('/'.join(sorted(wshape)))
            index = len(self.boxes)
            self.boxes.append(dict(
                kind=('isolde' if node.domain == 'com.isolde'
                      else node.op_type),
                title=node.op_type, sub=sub, node=node,
                preds=sorted({producer[i] for i in node.input
                              if i in producer}),
                edge_tensor={producer[i]: i for i in node.input
                             if i in producer}))
            for o in node.output:
                producer[o] = index
        for name in self.outputs:
            self.boxes.append(dict(
                kind='output', title=name,
                sub=fmt_shape(self.shapes.get(name)), node=None,
                preds=[producer[name]], edge_tensor={producer[name]: name}))

        # Longest-path layers (a chain here; residual Adds skip a layer).
        self.layer = []
        for b in self.boxes:
            preds = b.get('preds', [])
            self.layer.append(1 + max((self.layer[p] for p in preds),
                                      default=-1))
        self.columns = {}
        for i, lay in enumerate(self.layer):
            self.columns.setdefault(lay, []).append(i)

    def position(self, i):
        lay = self.layer[i]
        row = self.columns[lay]
        return (row.index(i) - (len(row) - 1) / 2) * 1.2, -lay

    def properties(self, i):
        b = self.boxes[i]
        node = b['node']
        if node is None:
            kind = 'graph input' if b['kind'] == 'input' else 'graph output'
            return f'{kind}  {b["title"]}\n  float16  {b["sub"]}'
        from onnx import helper
        lines = [f'{node.op_type}  ({node.domain or "ai.onnx"} opset '
                 f'{self.opset.get(node.domain or "ai.onnx", "?")})',
                 f'name  {node.name}']
        if node.attribute:
            attrs = ', '.join(
                f'{a.name}={_attr(helper.get_attribute_value(a))}'
                for a in node.attribute)
            lines.append(f'attributes  {attrs}')
        lines.append('inputs')
        for name in node.input:
            if name in self.inits:
                a = self.inits[name]
                if a.ndim >= 1 and a.size > 1:
                    lines.append(f'  {name}  {a.dtype} {fmt_shape(a.shape)}  '
                                 f'[{float(a.min()):.3g}, {float(a.max()):.3g}]')
                else:
                    lines.append(f'  {name}  = {a.ravel().tolist()}')
            else:
                lines.append(f'  {name}  {fmt_shape(self.shapes.get(name))}')
        lines.append('outputs')
        for name in node.output:
            lines.append(f'  {name}  {fmt_shape(self.shapes.get(name))}')
        return '\n'.join(lines)


def _attr(v):
    if isinstance(v, bytes):
        return v.decode()
    if isinstance(v, float):
        return f'{v:g}'
    return v


def draw_graph(ax, graph):
    """Draw the boxes and edges; returns (patches by box, output text)."""
    from matplotlib.patches import FancyArrowPatch, FancyBboxPatch
    width, height = 2.6, 0.62
    patches = []
    for i, b in enumerate(graph.boxes):
        x, y = graph.position(i)
        io = b['kind'] in ('input', 'output')
        face = IO_FACE if io else KIND_COLOR.get(b['kind'], '#5b5b5b')
        text = '#1f1f1f' if io else 'white'
        patch = FancyBboxPatch((x - width / 2, y - height / 2), width, height,
                               boxstyle='round,pad=0.02,rounding_size=0.12',
                               facecolor=face, edgecolor=face, linewidth=2.0,
                               zorder=3)
        ax.add_patch(patch)
        patches.append(patch)
        ax.text(x, y + 0.11, b['title'], ha='center', va='center',
                fontsize=8, fontweight='bold', color=text, zorder=4)
        ax.text(x, y - 0.14, b['sub'], ha='center', va='center',
                fontsize=6.3, color=text, zorder=4)
        for p in b.get('preds', []):
            px, py = graph.position(p)
            skip = graph.layer[i] - graph.layer[p] > 1
            arrow = FancyArrowPatch(
                (px + (width / 2 if skip else 0), py - (0 if skip else height / 2)),
                (x + (width / 2 if skip else 0), y + (0 if skip else height / 2)),
                arrowstyle='-|>', mutation_scale=8, color=EDGE, linewidth=1.0,
                connectionstyle='arc3,rad=-0.55' if skip else 'arc3',
                zorder=2)
            ax.add_patch(arrow)
            tensor = b['edge_tensor'][p]
            label = fmt_shape(graph.shapes.get(tensor))
            if skip:
                ax.text(x + width / 2 + 0.55, (py + y) / 2, label,
                        fontsize=5.5, color=EDGE, va='center')
            else:
                ax.text(x + 0.08, (py + y) / 2, label, fontsize=5.5,
                        color=EDGE, va='center')
    ys = [graph.position(i)[1] for i in range(len(graph.boxes))]
    ax.set_xlim(-2.2, 3.4)
    ax.set_ylim(min(ys) - 0.6, max(ys) + 0.6)
    ax.set_axis_off()
    x, y = graph.position(len(graph.boxes) - 1)
    result = ax.text(x, y - 0.55, '', ha='center', va='top', fontsize=7.5,
                     color='#1f1f1f')
    return patches, result


def box_at(graph, xdata, ydata):
    for i in range(len(graph.boxes)):
        x, y = graph.position(i)
        if abs(xdata - x) <= 1.3 and abs(ydata - y) <= 0.31:
            return i
    return None


# ---------------------------------------------------------------------------
# Sources: the board, or a captured log
# ---------------------------------------------------------------------------
def replay(path, lines_per_second, chunks, stop, errors):
    try:
        data = Path(path).read_bytes().splitlines(keepends=True)
        print(f'replaying {path}', flush=True)
        for line in data:
            if stop.is_set():
                return
            chunks.put(line)
            time.sleep(1.0 / lines_per_second)
    except Exception as exc:                                  # noqa: BLE001
        errors.append(f'{type(exc).__name__}: {exc}')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawTextHelpFormatter)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--port', help='e.g. /dev/ttyUSB3')
    source.add_argument('--replay', type=Path, metavar='LOG',
                        help='a captured UART / Verilator log instead')
    parser.add_argument('--baud', type=int, default=921600)
    parser.add_argument('--speed', type=float, default=300.0,
                        help='--replay: lines per second (default 300)')
    parser.add_argument('--model', type=Path,
                        default=HERE / 'models/tformer_encoder.onnx')
    parser.add_argument('--netron', action='store_true',
                        help='also open the model in Netron (pip install netron)')
    parser.add_argument('--save', type=Path, metavar='PNG',
                        help=argparse.SUPPRESS)       # headless test hook
    args = parser.parse_args(argv)
    if args.port:
        tv.require_pyserial()
    if not args.model.exists():
        raise SystemExit(f'{args.model} not found: run `make golden` first')
    graph = Graph(args.model)

    if args.netron:
        try:
            import netron
        except ImportError:
            raise SystemExit('--netron: pip install netron')
        address = netron.start(str(args.model), browse=True, verbosity=0)
        print(f'Netron: http://{address[0]}:{address[1]}', flush=True)

    import matplotlib.pyplot as plt
    from matplotlib.animation import FuncAnimation
    from matplotlib.colors import LinearSegmentedColormap

    ramp = LinearSegmentedColormap.from_list('isolde_blue', tv.RAMP)
    ramp.set_bad(tv.PENDING)
    figure = plt.figure(figsize=(13.5, 8.2), layout='constrained')
    grid = figure.add_gridspec(3, 2, width_ratios=[1.35, 1.0],
                               height_ratios=[1.25, 1.0, 0.9])
    left = figure.add_subplot(grid[0, 0])
    right = figure.add_subplot(grid[1, 0])
    props = figure.add_subplot(grid[2, 0])
    model_ax = figure.add_subplot(grid[:, 1])
    figure.canvas.manager.set_window_title('onnx_radar_attention live')

    FRAMES, FEATURES, TILE, CLASSES = tv.FRAMES, tv.FEATURES, tv.TILE, tv.CLASSES
    blank = np.ma.array(np.zeros((FRAMES, FEATURES)), mask=True)
    image = left.imshow(blank, aspect='auto', cmap=ramp, vmin=0.0, vmax=1.0,
                        interpolation='nearest',
                        extent=[0, FEATURES, FRAMES - 0.5, -0.5])
    left.axvline(TILE, color='#fcfcfb', linewidth=2.0)
    left.set_xticks([TILE / 2, TILE + TILE / 2])
    left.set_xticklabels(['bearing', 'range'])
    left.set_ylabel('frame')
    left.set_yticks(range(0, FRAMES, 2))
    left.tick_params(length=0)
    left.set_title('feature window')

    bars = right.barh(range(CLASSES), np.zeros(CLASSES), color=tv.MUTED,
                      height=0.62)
    right.set_yticks(range(CLASSES))
    right.set_yticklabels(tv.CLASS_NAMES)
    right.invert_yaxis()
    right.set_xlim(-1, 1)
    right.set_xlabel('logit')
    right.grid(axis='x', alpha=0.25)
    right.set_title('decision')

    props.set_axis_off()
    props_text = props.text(0.0, 1.0, 'click a node of the model for its '
                            'properties', va='top', ha='left', fontsize=7.5,
                            family='monospace', transform=props.transAxes)

    patches, result = draw_graph(model_ax, graph)
    model_title = model_ax.set_title(graph.path.name, fontsize=10)
    title = figure.suptitle('', fontsize=11)

    selected = [None]

    def on_click(event):
        if event.inaxes is not model_ax or event.xdata is None:
            return
        i = box_at(graph, event.xdata, event.ydata)
        if i is None:
            return
        selected[0] = i
        props_text.set_text(graph.properties(i))
        figure.canvas.draw_idle()

    figure.canvas.mpl_connect('button_press_event', on_click)

    decoder = Decoder()
    chunks, stop, errors = queue.Queue(), threading.Event(), []
    if args.port:
        worker = (tv.reader, (args.port, args.baud, chunks, stop, errors))
    else:
        worker = (replay, (args.replay, args.speed, chunks, stop, errors))
    threading.Thread(target=worker[0], args=worker[1], daemon=True).start()

    def style_graph(receiving, done, failed):
        for i, (b, patch) in enumerate(zip(graph.boxes, patches)):
            io = b['kind'] in ('input', 'output')
            face = IO_FACE if io else KIND_COLOR.get(b['kind'], '#5b5b5b')
            edge = face
            if io and done:
                face = DONE
            if (b['kind'] == 'input' and receiving) or \
               (b['kind'] == 'output' and done):
                edge = '#c0392b' if failed else tv.ACCENT
            if i == selected[0]:
                edge = '#1f1f1f'
            patch.set_facecolor(face)
            patch.set_edgecolor(edge)

    def tick(_frame):
        while True:
            try:
                decoder.feed(chunks.get_nowait())
            except queue.Empty:
                break
        values = decoder.window.view(np.float16).astype(np.float64)
        values = values.reshape(2, FRAMES, TILE).transpose(1, 0, 2)
        image.set_data(np.ma.array(
            values.reshape(FRAMES, FEATURES),
            mask=~decoder.seen.reshape(2, FRAMES, TILE).transpose(1, 0, 2)
            .reshape(FRAMES, FEATURES)))

        done = bool(decoder.logits_seen.all())
        if done:
            logits = decoder.logits.view(np.float16).astype(np.float64)
            best = int(np.argmax(tv.ordered(decoder.logits)))
            for index, bar in enumerate(bars):
                bar.set_width(logits[index])
                bar.set_color(tv.ACCENT if index == best else tv.MUTED)
            span = max(1e-3, float(np.abs(logits).max()))
            right.set_xlim(-1.5 * span if logits.min() < 0 else -0.05 * span,
                           1.4 * span if logits.max() > 0 else 0.05 * span)
            right.set_title(f'decision: {tv.CLASS_NAMES[best]}')
            result.set_text(f'{tv.CLASS_NAMES[best]}\n'
                            + '  '.join(f'{v:.2f}' for v in logits))
        else:
            result.set_text('')
        receiving = decoder.case_id is not None and not done
        style_graph(receiving, done, decoder.verdict == 'FAILED')
        cost = (f'   |   graph.ll: {decoder.cost[0]} launches, '
                f'{decoder.cost[1]} barriers' if decoder.cost else '')
        model_title.set_text(graph.path.name + cost)
        title.set_text(errors[-1] if errors else decoder.status())

    animation = FuncAnimation(figure, tick, interval=200, repeat=False,
                              cache_frame_data=False)
    try:
        if args.save:                      # headless: run the source, save
            time.sleep(2.0 + 1.2 * 420 / max(args.speed, 1.0))
            selected[0] = 3
            props_text.set_text(graph.properties(3))
            tick(0)
            figure.savefig(args.save, dpi=110)
        else:
            plt.show()
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
    del animation
    if errors:
        print(errors[-1], file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
