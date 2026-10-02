#!/usr/bin/env python3
"""
slang_hier_to_dot.py

Block diagrams straight out of the elaborated design, one per hierarchy level.

The design is elaborated with pyslang using exactly the same command files the
synthesis flow uses (``-f <top>_all_deps.f`` or the broad ``*.slang``
manifests), so what gets drawn is the design as it is *elaborated*: parameters
resolved, generate branches taken, `ifdef`s applied.  Nothing is drawn that the
compiler did not build.

For each requested level (a module name) the script draws one graph containing:

  * the child module instances of that level, as boxes;
  * the SystemVerilog interface instances declared at that level, as dashed
    boxes;
  * the level's own ports, as boundary nodes on the left/right;
  * a single "RTL glue" node standing for the assigns and procedural blocks
    written directly at that level, when there are any;
  * edges between them.

Edge direction comes from real direction information: port directions for
ordinary nets, and for an interface port the *modport* member directions --
so `bus.master` and `bus.slave` produce arrows that point opposite ways.

Replication is collapsed: an instance array, or a `for` generate block, is
drawn once with a multiplicity marker (e.g. `x4`).  Connections are unioned
over all the replicas, so nothing that exists only for `i > 0` is lost.

Backends
--------

``--format`` takes a comma separated list:

  svg / png / pdf   rendered by Graphviz; read-only, good for a doc or a PR
  dot               the Graphviz source
  drawio            an editable diagrams.net file

The draw.io backend exists because a rendered picture is not something you can
correct.  draw.io does no layout on import, so the geometry comes from
Graphviz -- the same DOT is run through ``dot -Tjson`` and every box is placed
at the position Graphviz computed.  The file therefore opens already laid out,
but every block is a real object you can drag, restyle or delete.  Edges are
left to draw.io's orthogonal router instead of being baked as waypoints, so
the wiring re-routes when you move a block rather than trailing behind it.

Usage
-----

    python3 util/slang_hier_to_dot.py \
        --level xilinx_aida --level isolde_cluster --level isolde_tile \
        --outdir doc/diagrams --format svg,drawio \
        -- --top xilinx_aida --ignore-unknown-modules \
           -f xilinx_aida_all_deps.f

Everything after ``--`` is handed to slang unchanged.  ``--list-modules``
prints the module names available as levels and exits.

``--emit-model`` writes the extracted model as JSON and ``--from-model``
renders one back, with no slang involved -- the boundary the C++ extractor
(``slang-blocks``, in the task5.2 repo) sits behind.  A model produced by a
filtered extraction may carry *indirect* edges, left behind where a block was
elided; those are drawn dashed and labelled with what was removed.

Regenerating a ``.drawio`` keeps the position of every block already in the
file, matched by node key, so a diagram you arranged by hand survives an RTL
change; only new blocks are placed by Graphviz.  ``--no-preserve-positions``
turns that off.

Requires: pyslang (``pip install pyslang``), and Graphviz ``dot`` on PATH for
every format except ``dot`` -- including ``drawio``, which needs it for the
layout.
"""

from __future__ import annotations

import argparse
import html
import json
import re
import shlex
import shutil
import subprocess
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path

try:
    from pyslang import ast
    from pyslang import driver as slang_driver
except ImportError:  # pragma: no cover
    sys.exit("error: pyslang is required (pip install pyslang)")


# --------------------------------------------------------------------------
# Defaults
# --------------------------------------------------------------------------

# Nets matched here are not drawn as edges; they are listed in the legend
# instead.  Clock and reset connect to nearly every block and destroy any
# layout Graphviz can produce.
DEFAULT_HIDE_NETS = (
    r"(?i)^("
    r"clk|clk_[a-z0-9_]*|[a-z0-9_]*_clk|[a-z0-9_]*clk_i|"
    r"rst|rst_n|rst_ni|rst_i|reset|reset_n|"
    r"[a-z0-9_]*_rst|[a-z0-9_]*_rst_n|[a-z0-9_]*_rstn|[a-z0-9_]*_reset|"
    r"[a-z0-9_]*_rst_ni|test_en_i|test_mode_i|scan_cg_en_i"
    r")$"
)

IDX = re.compile(r"\[\d+\]")

STYLE = {
    "module": 'shape=box, style="rounded,filled", fillcolor="#e8f0fb", '
              'color="#3b6ea5", penwidth=1.2',
    "iface": 'shape=box, style="rounded,filled,dashed", fillcolor="#fdf3e0", '
             'color="#b07d22"',
    "blackbox": 'shape=box, style="filled,dashed", fillcolor="#eeeeee", '
                'color="#666666"',
    "group": 'shape=box, style="rounded,filled", fillcolor="#eaf3ea", '
             'color="#3a7d52", penwidth=1.2, peripheries=2',
    "glue": 'shape=box, style="filled", fillcolor="#f0f0f0", color="#888888"',
    "bus": 'shape=box, style="filled", fillcolor="#eef4fb", color="#7aa7d0", '
           'fontsize=9, height=0.18, margin="0.06,0.03"',
    "port_in": 'shape=cds, style="filled", fillcolor="#e6f4ea", '
               'color="#3a7d52"',
    "port_out": 'shape=cds, style="filled", fillcolor="#fce8e6", '
                'color="#a5433b"',
    "port_iface": 'shape=cds, style="filled,dashed", fillcolor="#fdf3e0", '
                  'color="#b07d22"',
}


# --------------------------------------------------------------------------
# Model
# --------------------------------------------------------------------------

@dataclass
class Node:
    key: str
    label_name: str          # instance name as written
    label_type: str          # module / interface name
    kind: str                # module | iface | glue | port_in | port_out | port_iface
    count: int = 1           # replication (instance array x generate array)
    params: list = field(default_factory=list)
    gpath: tuple = ()        # enclosing generate blocks


@dataclass
class Endpoint:
    node: str
    port: str
    drives: bool
    reads: bool
    unknown: bool = False   # black box: slang has no direction information


class Level:
    def __init__(self, module, inst=None, path="", params=None):
        self.module = module
        self.inst = inst
        self.path = path or (inst.hierarchicalPath if inst else "")
        self.params = params if params is not None else []
        self.nodes: dict[str, Node] = {}
        self.nets: dict[str, list[Endpoint]] = defaultdict(list)
        self.net_names: dict[str, str] = {}
        self.iface_edges: dict[tuple, set] = defaultdict(set)
        self.net_widths: dict[str, int] = {}
        self.indirect: list = []      # edges left behind by elided blocks
        self.hidden_nets: set = set()

    def add(self, node: Node) -> str:
        cur = self.nodes.get(node.key)
        if cur is None:
            self.nodes[node.key] = node
        else:
            cur.count = max(cur.count, node.count)
        return node.key


# --------------------------------------------------------------------------
# Small helpers over the slang AST
# --------------------------------------------------------------------------

GEN_MULT = re.compile(r"\[x(\d+)\]")


def gpath_multiplicity(gpath) -> int:
    """How many copies a generate-block path stands for."""
    n = 1
    for part in gpath:
        for m in GEN_MULT.finditer(part):
            n *= int(m.group(1))
    return n


def canon(path: str) -> str:
    """Drop array indices so replicas share one key."""
    return IDX.sub("", path)


def rel(path: str, base: str) -> str | None:
    """Path relative to the level instance, or None if not inside it."""
    path, base = canon(path), canon(base)
    if path == base:
        return ""
    if path.startswith(base + "."):
        return path[len(base) + 1:]
    return None


def ref_symbols(expr):
    """Every value symbol referenced anywhere in an expression."""
    out = []
    if expr is None:
        return out
    # Connections on an unknown module come back wrapped, since slang cannot
    # tell a port connection from an assertion argument without a definition.
    if not hasattr(expr, "visit"):
        expr = getattr(expr, "expr", None)
        if expr is None or not hasattr(expr, "visit"):
            return out

    def visit(n):
        k = getattr(n, "kind", None)
        if k in (ast.ExpressionKind.NamedValue,
                 ast.ExpressionKind.HierarchicalValue):
            out.append(n.symbol)

    expr.visit(visit)
    return out


def fmt_value(v):
    """Readable form of a resolved parameter value.

    Wide or negative integers are shown as hex over their own bit pattern:
    an address map is unreadable in signed decimal, and `int` parameters
    holding addresses above 0x8000_0000 come out negative.
    """
    raw = getattr(v, "value", None)
    width = getattr(raw, "bitWidth", None)
    if width is None or getattr(raw, "hasUnknown", False):
        return str(v)
    try:
        i = int(raw)
    except Exception:
        return str(v)
    if width == 1:
        return f"1'b{i & 1}"
    # A string literal in a plain `parameter` is an integral of 8 bits per
    # character; printing that in hex helps nobody.
    if 16 <= width <= 256 and width % 8 == 0 and i > 0:
        try:
            raw_bytes = (i & ((1 << width) - 1)).to_bytes(width // 8, "big")
            if all(0x20 <= c < 0x7F for c in raw_bytes):
                return '"' + raw_bytes.decode("ascii") + '"'
        except Exception:
            pass
    if i < 0 or abs(i) >= 4096:
        return f"0x{i & ((1 << width) - 1):X}"
    return str(i)


PORT_CONN = re.compile(r"\.(\w+)\s*\(")
IDENT = re.compile(r"[A-Za-z_]\w*")


def blackbox_connections(sym):
    """Named port connections of an unknown module, from its syntax.

    slang binds nothing inside an instantiation whose definition it never saw,
    so the elaborated connection expressions are all `InvalidExpression`.  The
    syntax tree still has the text, so the names are recovered from there and
    resolved against the enclosing scope by the caller.  Positional
    connections are not recovered (this is a named-connection codebase).
    """
    text = str(getattr(sym, "syntax", "") or "")
    if not text:
        return []
    text = re.sub(r"//[^\n]*", " ", text)
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)

    out = []
    for mo in PORT_CONN.finditer(text):
        j, depth = mo.end(), 1
        while j < len(text) and depth:
            if text[j] == "(":
                depth += 1
            elif text[j] == ")":
                depth -= 1
            j += 1
        inner = text[mo.end():j - 1]
        out.append((mo.group(1), IDENT.findall(inner)))
    return out


def symbol_width(sym):
    """Declared width of a signal, or 0 when the type has none worth reporting."""
    try:
        t = sym.type
        return int(t.bitWidth if t.isIntegral else t.bitstreamWidth)
    except Exception:
        return 0


def scalar_params(body, limit):
    """Resolved parameter values worth putting on a label."""
    out = []
    for m in body:
        if m.kind != ast.SymbolKind.Parameter or m.isLocalParam:
            continue
        try:
            v = m.value
        except Exception:
            continue
        if v is None:
            continue
        s = fmt_value(v)
        if len(s) > 24 or "\n" in s:
            continue
        out.append(f"{m.name}={s}")
        if len(out) >= limit:
            break
    return out


def modport_directions(modport):
    """(module_drives, module_reads) for a modport."""
    drives = reads = False
    if modport is None:
        return True, True
    for m in modport:
        if m.kind != ast.SymbolKind.ModportPort:
            continue
        d = m.direction
        if d == ast.ArgumentDirection.Out:
            drives = True
        elif d == ast.ArgumentDirection.In:
            reads = True
        else:                       # inout / ref
            drives = reads = True
    if not drives and not reads:
        return True, True
    return drives, reads


def port_direction(port):
    d = getattr(port, "direction", None)
    if d == ast.ArgumentDirection.Out:
        return False, True          # reads, drives  (from the child's view)
    if d == ast.ArgumentDirection.In:
        return True, False
    return True, True               # inout / ref / unknown


# --------------------------------------------------------------------------
# Walking one level
# --------------------------------------------------------------------------

def walk_scope(scope, gpath, on_instance, on_glue, on_blackbox=None):
    """Instances and level-local logic directly in `scope`.

    Recurses through generate blocks (all live branches, all loop entries) but
    never into an instance body.
    """
    for m in scope:
        k = m.kind

        if k in (ast.SymbolKind.UninstantiatedDef,
                 ast.SymbolKind.PrimitiveInstance):
            # A module slang never saw a definition for: a vendor IP core, a
            # technology primitive, an `ifdef`-ed out cell.  It is a real box
            # in the design, so draw it -- but slang knows no port directions
            # for it, so its edges are resolved from the other endpoints.
            if on_blackbox is not None:
                on_blackbox(m, m.name, gpath, scope)
            continue

        if k == ast.SymbolKind.Instance:
            on_instance(m, m.name, 1, gpath)

        elif k == ast.SymbolKind.InstanceArray:
            els = [e for e in m.elements if e.kind == ast.SymbolKind.Instance]
            for e in els:
                on_instance(e, m.name, len(els), gpath)

        elif k == ast.SymbolKind.GenerateBlock:
            if not m.isUninstantiated:
                name = m.externalName or m.name or "genblk"
                walk_scope(m, gpath + (name,), on_instance, on_glue,
                           on_blackbox)

        elif k == ast.SymbolKind.GenerateBlockArray:
            entries = [e for e in m.entries if not e.isUninstantiated]
            name = m.externalName or m.name or "genblk"
            tag = f"{name}[x{len(entries)}]" if len(entries) > 1 else name
            for e in entries:
                walk_scope(e, gpath + (tag,), on_instance, on_glue,
                           on_blackbox)

        elif k in (ast.SymbolKind.ContinuousAssign,
                   ast.SymbolKind.ProceduralBlock):
            on_glue(m)


def build_level(module_name, inst, args):
    lvl = Level(module_name, inst)
    body = inst.body
    base = inst.hierarchicalPath
    lvl.params = scalar_params(body, 8)

    # ---- boundary ports -------------------------------------------------
    port_syms = {}
    # An interface port is resolved by slang to the interface instance in the
    # *parent*, so children of this level connect to something outside it.
    # Map those outside paths back onto this level's own pins.
    iface_ports = {}
    for p in body.portList:
        if p.kind == ast.SymbolKind.InterfacePort:
            key = f"port:{p.name}"
            lvl.add(Node(key, p.name, getattr(p.interfaceDef, "name", "interface"),
                         "port_iface"))
            port_syms[canon(p.hierarchicalPath)] = (key, True, True)
            conn = getattr(p, "connection", None)
            target, mp = conn if isinstance(conn, tuple) else (conn, None)
            outside = canon(getattr(target, "hierarchicalPath", "") or "")
            if outside:
                # Several pins of this level can be different modports of one
                # interface instance in the parent, so the modport is part of
                # the key; the bare path stays as a fallback.
                mp_name = getattr(mp, "name", None) or getattr(p, "modport", None)
                iface_ports.setdefault((outside, mp_name), key)
                iface_ports.setdefault((outside, None), key)
            continue

        internal = getattr(p, "internalSymbol", None)
        reads, drives = port_direction(p)
        # From inside the level an `input` port is a driver.
        kind = "port_in" if getattr(p, "direction", None) == ast.ArgumentDirection.In \
            else "port_out"
        key = f"port:{p.name}"
        lvl.add(Node(key, p.name, "", kind))
        if internal is not None:
            port_syms[canon(internal.hierarchicalPath)] = (
                key, kind == "port_in", kind != "port_in")

    # ---- children -------------------------------------------------------
    glue_syms = []

    def on_instance(sym, name, count, gpath):
        prefix = "/".join(gpath)
        key = ("iface:" if sym.isInterface else "inst:") + \
              (prefix + "/" if prefix else "") + name
        node = Node(
            key=key,
            label_name=name,
            label_type=sym.definition.name,
            kind="iface" if sym.isInterface else "module",
            count=count * gpath_multiplicity(gpath),
            params=[] if sym.isInterface else scalar_params(sym.body, args.child_params),
            gpath=gpath,
        )
        lvl.add(node)
        if not sym.isInterface:
            record_connections(lvl, sym, key, base, iface_ports)

    def on_blackbox(sym, name, gpath, scope):
        prefix = "/".join(gpath)
        key = "bbox:" + (prefix + "/" if prefix else "") + name
        lvl.add(Node(
            key=key,
            label_name=name,
            label_type=getattr(sym, "definitionName", "") or
                       str(getattr(sym, "primitiveType", "")),
            kind="blackbox",
            gpath=gpath,
        ))
        for pname, idents in blackbox_connections(sym):
            for ident in idents:
                try:
                    s = scope.lookupName(ident)
                except Exception:
                    s = None
                if s is None or not getattr(s, "isValue", False):
                    continue
                if s.kind not in (ast.SymbolKind.Net, ast.SymbolKind.Variable,
                                  ast.SymbolKind.Port):
                    continue
                path = canon(s.hierarchicalPath)
                if rel(path, base) is None:
                    continue
                lvl.net_names.setdefault(path, s.name)
                if not lvl.net_widths.get(path):
                    lvl.net_widths[path] = symbol_width(s)
                lvl.nets[path].append(
                    Endpoint(key, pname, False, False, unknown=True))

    def on_glue(sym):
        glue_syms.append(sym)

    walk_scope(body, (), on_instance, on_glue, on_blackbox)

    # ---- level-local logic ---------------------------------------------
    if glue_syms:
        drives, reads = set(), set()
        for sym in glue_syms:
            collect_glue(sym, drives, reads)
        touched = drives | reads
        touched = {p for p in touched if rel(p, base) is not None}
        if touched:
            lvl.add(Node("glue", "RTL glue", "assigns / always blocks", "glue"))
            for p in touched:
                lvl.nets[p].append(
                    Endpoint("glue", "", p in drives, p in reads))

    # ---- boundary ports as net endpoints --------------------------------
    for path, (key, drives, reads) in port_syms.items():
        lvl.nets[path].append(Endpoint(key, "", drives, reads))
        lvl.net_names.setdefault(path, path.rsplit(".", 1)[-1])

    return lvl


def collect_glue(sym, drives, reads):
    def visit(n):
        if getattr(n, "kind", None) == ast.ExpressionKind.Assignment:
            left = getattr(n, "left", None)
            right = getattr(n, "right", None)
            for s in ref_symbols(left):
                drives.add(canon(s.hierarchicalPath))
            for s in ref_symbols(right):
                reads.add(canon(s.hierarchicalPath))
    try:
        sym.visit(visit)
    except Exception:
        pass


def record_connections(lvl, sym, node_key, base, iface_ports):
    """Port connections of one child instance, as net / interface endpoints."""
    for pc in sym.portConnections:
        port = pc.port

        # ---- interface port ---------------------------------------------
        if port.kind == ast.SymbolKind.InterfacePort:
            iface, modport = pc.ifaceConn
            if iface is None:
                continue
            target = iface_node_key(iface, base, lvl, iface_ports,
                                    getattr(modport, "name", None))
            if target is None:
                continue
            drives, reads = modport_directions(modport)
            mp = modport.name if modport is not None else ""
            lvl.iface_edges[(node_key, target)].add((mp, drives, reads))
            continue

        # ---- ordinary port ----------------------------------------------
        reads, drives = port_direction(port)
        for s in ref_symbols(pc.expression):
            path = canon(s.hierarchicalPath)
            if rel(path, base) is None:
                continue
            name = s.name
            lvl.net_names.setdefault(path, name)
            if not lvl.net_widths.get(path):
                lvl.net_widths[path] = symbol_width(s)
            lvl.nets[path].append(
                Endpoint(node_key, port.name or "", drives, reads))


def iface_node_key(iface, base, lvl, iface_ports, modport_name=None):
    """Map a connected interface symbol onto a node of this level."""
    if iface.kind == ast.SymbolKind.InterfacePort:
        # The level passes its own interface port straight down.
        return f"port:{iface.name}"

    path = canon(getattr(iface, "hierarchicalPath", "") or "")
    r = rel(path, base)
    if r is None or r == "":
        # Outside this level: it is what one of our own interface pins was
        # resolved to.
        return (iface_ports.get((path, modport_name)) or
                iface_ports.get((path, None)))
    key = "iface:" + r.replace(".", "/")
    if key in lvl.nodes:
        return key
    # Interface declared inside a generate block: match on the trailing name.
    tail = r.rsplit(".", 1)[-1]
    for k, n in lvl.nodes.items():
        if n.kind == "iface" and n.label_name == tail:
            return k
    return None


# --------------------------------------------------------------------------
# DOT emission
# --------------------------------------------------------------------------

def esc(s):
    return html.escape(str(s), quote=True)


# One description of a node's label, used by both backends and by the box
# sizing.  Each entry is (text, point size, bold, colour).
def label_lines(n):
    lines = [(n.label_name + (f"  x{n.count}" if n.count > 1 else ""),
              11, True, None)]
    if n.label_type:
        lines.append((n.label_type, 9, False, "#555555"))
    for p in n.params:
        lines.append((p, 8, False, "#777777"))
    if n.gpath:
        lines.append(("/".join(n.gpath), 8, False, "#999999"))
    return lines


def node_label(n):
    """Graphviz HTML-like label."""
    out = []
    title = esc(n.label_name)
    if n.count > 1:
        title += f' <font color="#a5433b">&#215;{n.count}</font>'
    out.append(f"<b>{title}</b>")
    if n.label_type:
        out.append(f'<font point-size="9" color="#555555">{esc(n.label_type)}</font>')
    for p in n.params:
        out.append(f'<font point-size="8" color="#777777">{esc(p)}</font>')
    if n.gpath:
        out.append(f'<font point-size="8" color="#999999">'
                   f'{esc("/".join(n.gpath))}</font>')
    return "<" + "<br/>".join(out) + ">"


# Rough Helvetica metrics, in units of the font size.  Only used as a floor:
# what Graphviz measures for itself always wins where it is larger.
CHAR_W = 0.62
BOLD_W = 1.08
LINE_H = 1.32


def html_box(n, kind):
    """Points needed to render this label in a browser, for draw.io.

    Graphviz measures its own text exactly; nothing measures the browser's,
    so this estimate is the floor that keeps a draw.io box from clipping.
    """
    lines = label_lines(n)
    h = sum(size * LINE_H for _, size, _, _ in lines) + 12
    w = max(len(text) * size * CHAR_W * (BOLD_W if bold else 1.0)
            for text, size, bold, _ in lines) + 20
    if kind.startswith("port"):
        w += 14          # the step/cds chevron eats horizontal room
    return w, h


LEGEND_ROWS = (
    '<tr>'
    '<td bgcolor="#e8f0fb" border="1">module instance</td>'
    '<td bgcolor="#fdf3e0" border="1">interface instance</td>'
    '<td bgcolor="#eeeeee" border="1">no definition (IP / primitive)</td>'
    '<td bgcolor="#f0f0f0" border="1">logic written at this level</td>'
    '</tr>'
    '<tr><td colspan="4" align="left">'
    '<font point-size="8" color="#555555">'
    'solid arrow: port direction &#183; '
    'dashed arrow: interface, labelled with the modport &#183; '
    'dotted line: direction unknown &#183; '
    '&#215;N: drawn once, N replicas</font></td></tr>'
)


def compute_edges(lvl, nets, args):
    """Directed edges, undirected edges, and shared-bus hub nodes.

    A net with many drivers and many loads would otherwise become a mesh of
    driver x load edges.  Past a threshold it is drawn the way a schematic
    draws a bus: one small node for the net, everything else hung off it.
    """
    pair_nets = defaultdict(list)
    undirected = defaultdict(list)
    hubs = {}

    for path, eps in nets.items():
        name = lvl.net_names.get(path, path.rsplit(".", 1)[-1])
        drivers = [e for e in eps if e.drives]
        loads = [e for e in eps if e.reads]
        unknown = [e for e in eps if e.unknown]

        # Black-box endpoints carry no direction of their own.  With exactly
        # one of them on a net the direction follows from the other endpoints;
        # with two or more it is genuinely unknown, so those edges are drawn
        # undirected rather than guessed.
        if unknown:
            nodes = {e.node for e in unknown}
            if len(nodes) == 1 and drivers:
                loads = loads + unknown
            elif len(nodes) == 1 and loads:
                drivers = list(unknown)
            else:
                known = drivers + loads
                for i, u in enumerate(unknown):
                    for other in unknown[i + 1:] + known:
                        if u.node != other.node:
                            pair = tuple(sorted((u.node, other.node)))
                            undirected[pair].append(name)
                continue

        if not drivers or not loads:
            continue

        pairs = [(d.node, l.node) for d in drivers for l in loads
                 if d.node != l.node]
        if len(set(pairs)) >= args.bus_threshold:
            hub = f"bus:{path}"
            hubs[hub] = name
            for d in {d.node for d in drivers}:
                pair_nets[(d, hub)].append(name)
            for l in {l.node for l in loads}:
                pair_nets[(hub, l)].append(name)
            continue
        for src, dst in pairs:
            pair_nets[(src, dst)].append(name)

    return pair_nets, undirected, hubs


def edge_label(names, args, sep="\\n"):
    uniq = sorted(set(names))
    if len(uniq) <= args.max_edge_labels:
        return sep.join(uniq), len(uniq)
    return (sep.join(uniq[:args.max_edge_labels]) +
            f"{sep}(+{len(uniq) - args.max_edge_labels} more)"), len(uniq)


@dataclass
class Edge:
    src: str
    dst: str
    names: list
    kind: str               # net | bus | unknown | iface | indirect
    both: bool = False
    via: str = ""           # for indirect edges: the block that was elided


@dataclass
class Graph:
    """What both backends draw: nodes, bus hubs, edges, and the header text."""
    nodes: dict
    hubs: dict
    edges: list
    head: list


def build_graph(lvl, args):
    # Clock and reset connect to nearly everything; dropping them is a
    # drawing decision, so it happens here and not during extraction.
    hide = re.compile(args.hide_nets) if args.hide_nets else None
    nets, lvl.hidden_nets = {}, set()
    for path, eps in lvl.nets.items():
        name = lvl.net_names.get(path, path.rsplit(".", 1)[-1])
        if hide and hide.match(name):
            lvl.hidden_nets.add(name)
            continue
        nets[path] = eps

    pair_nets, undirected, hubs = compute_edges(lvl, nets, args)

    edges = []
    for (a, b), names in sorted(undirected.items()):
        edges.append(Edge(a, b, names, "unknown"))
    for (src, dst), names in sorted(pair_nets.items()):
        kind = "bus" if (src in hubs or dst in hubs) else "net"
        edges.append(Edge(src, dst, names, kind))
    for (a, b), infos in sorted(lvl.iface_edges.items()):
        mps = sorted({m for m, _, _ in infos if m})
        drives = any(d for _, d, _ in infos)
        reads = any(r for _, _, r in infos)
        if drives:
            edges.append(Edge(a, b, mps, "iface", both=drives and reads))
        else:
            edges.append(Edge(b, a, mps, "iface"))

    edges.extend(lvl.indirect)

    # A boundary port whose only nets are hidden (clock, reset) would be drawn
    # as a floating pin; those are reported in the header instead.
    connected = {e.src for e in edges} | {e.dst for e in edges}
    floating = sorted(n.label_name for k, n in lvl.nodes.items()
                      if k.startswith("port:") and k not in connected)
    nodes = {k: n for k, n in lvl.nodes.items()
             if not (k.startswith("port:") and k not in connected)}

    params = lvl.params
    head = [f"<b>{esc(lvl.module)}</b>",
            f'<font point-size="9">{esc(lvl.path)}</font>']
    if params:
        head.append(f'<font point-size="9" color="#555555">'
                    f'{esc("  ".join(params))}</font>')
    if lvl.hidden_nets:
        shown = sorted(lvl.hidden_nets)
        more = "" if len(shown) <= 8 else f" (+{len(shown) - 8} more)"
        head.append(f'<font point-size="8" color="#999999">'
                    f'clock / reset, not drawn: {esc(", ".join(shown[:8]))}'
                    f'{more}</font>')
    if floating:
        more = "" if len(floating) <= 8 else f" (+{len(floating) - 8} more)"
        head.append(f'<font point-size="8" color="#999999">'
                    f'pins with no drawn connection: '
                    f'{esc(", ".join(floating[:8]))}{more}</font>')

    return Graph(nodes=nodes, hubs=hubs, edges=edges, head=head)


# --------------------------------------------------------------------------
# The model: everything the compiler knows, and nothing about drawing
#
# This is the interface between extraction and rendering.  It carries facts
# only -- instances, pins, resolved parameters, every net endpoint with its
# direction, interface connections with their modport.  Which nets are hidden,
# what becomes a bus, how a box is styled: none of that is in here, so a
# different front end (a C++ tool linking libslang, say) can produce this file
# and the renderer stays unchanged.
# --------------------------------------------------------------------------

MODEL_SCHEMA = "slang-blocks-model/2"
MODEL_SCHEMAS = ("slang-blocks-model/1", "slang-blocks-model/2")


def model_from_levels(levels):
    return {
        "schema": MODEL_SCHEMA,
        "levels": [
            {
                "module": lvl.module,
                "instance": lvl.path,
                "params": list(lvl.params),
                "nodes": [
                    {
                        "key": n.key,
                        "name": n.label_name,
                        "type": n.label_type,
                        "kind": n.kind,
                        "count": n.count,
                        "params": list(n.params),
                        "generate": list(n.gpath),
                    }
                    for n in lvl.nodes.values()
                ],
                "edges": [
                    {"bidir": e.both, "from": e.src,
                     "labels": [l for l in e.names if not l.startswith("via ")],
                     "to": e.dst, "via": e.via}
                    for e in lvl.indirect
                ],
                "nets": [
                    {
                        "path": path,
                        "width": lvl.net_widths.get(path, 0),
                        "name": lvl.net_names.get(path,
                                                  path.rsplit(".", 1)[-1]),
                        "endpoints": [
                            {"node": e.node, "port": e.port,
                             "drives": e.drives, "reads": e.reads,
                             "unknown": e.unknown}
                            for e in eps
                        ],
                    }
                    for path, eps in lvl.nets.items()
                ],
                "interfaces": [
                    {"from": a, "to": b, "modport": mp,
                     "drives": drives, "reads": reads}
                    for (a, b), infos in lvl.iface_edges.items()
                    for mp, drives, reads in infos
                ],
            }
            for lvl in levels
        ],
    }


def levels_from_model(data):
    schema = data.get("schema")
    if schema not in MODEL_SCHEMAS:
        sys.exit(f"error: model schema is '{schema}', expected one of "
                 f"{', '.join(MODEL_SCHEMAS)}")

    levels = []
    for entry in data.get("levels", []):
        lvl = Level(entry["module"], None, entry.get("instance", ""),
                    entry.get("params", []))
        for n in entry.get("nodes", []):
            lvl.add(Node(key=n["key"], label_name=n["name"],
                         label_type=n.get("type", ""), kind=n["kind"],
                         count=n.get("count", 1), params=n.get("params", []),
                         gpath=tuple(n.get("generate", []))))
        for net in entry.get("nets", []):
            path = net["path"]
            lvl.net_names[path] = net.get("name",
                                          path.rsplit(".", 1)[-1])
            lvl.net_widths[path] = net.get("width", 0)
            for e in net.get("endpoints", []):
                lvl.nets[path].append(
                    Endpoint(e["node"], e.get("port", ""), e["drives"],
                             e["reads"], e.get("unknown", False)))
        for i in entry.get("interfaces", []):
            lvl.iface_edges[(i["from"], i["to"])].add(
                (i.get("modport", ""), i["drives"], i["reads"]))
        for e in entry.get("edges", []):
            lvl.indirect.append(Edge(e["from"], e["to"],
                                     e.get("labels", []) or
                                     [f"via {e.get('via', '')}"],
                                     "indirect", both=e.get("bidir", False),
                                     via=e.get("via", "")))
        levels.append(lvl)
    return levels


# --------------------------------------------------------------------------
# Backend: Graphviz DOT
# --------------------------------------------------------------------------

def emit_dot(g, lvl, args, sizes=None):
    out = []
    w = out.append

    w(f'digraph "{lvl.module}" {{')
    w('  graph [rankdir=LR, splines=spline, nodesep=0.35, ranksep=1.0, '
      'fontname="Helvetica", labelloc=t, labeljust=l];')
    w('  node  [fontname="Helvetica", fontsize=11, margin="0.14,0.08"];')
    w('  edge  [fontname="Helvetica", fontsize=8, color="#666666", '
      'arrowsize=0.7];')

    rows = "".join(f'<tr><td colspan="4" align="left">{line}</td></tr>'
                   for line in g.head)
    if args.legend:
        rows += ('<tr><td colspan="4"> </td></tr>' + LEGEND_ROWS)
    w('  label=<<table border="0" cellborder="0" cellspacing="0" '
      f'cellpadding="2">{rows}</table>>;')

    ins = [n for n in g.nodes.values() if n.kind == "port_in"]
    outs = [n for n in g.nodes.values()
            if n.kind in ("port_out", "port_iface")]
    if ins:
        w('  { rank=source; ' + " ".join(f'"{n.key}"' for n in ins) + ' }')
    if outs:
        w('  { rank=sink; ' + " ".join(f'"{n.key}"' for n in outs) + ' }')

    def size_attr(key):
        """Pin the box, so Graphviz lays out the boxes draw.io will draw."""
        if not sizes or key not in sizes:
            return ""
        bw, bh = sizes[key]
        return (f', fixedsize=true, width={bw / 72.0:.4f}, '
                f'height={bh / 72.0:.4f}')

    for n in g.nodes.values():
        w(f'  "{n.key}" [{STYLE[n.kind]}, label={node_label(n)}'
          f'{size_attr(n.key)}];')
    for key, name in sorted(g.hubs.items()):
        w(f'  "{key}" [{STYLE["bus"]}, label=<{esc(name)}>{size_attr(key)}];')

    iface_style = 'style=dashed, color="#b07d22", fontcolor="#8a6119"'
    for e in g.edges:
        label, n_sig = edge_label(e.names, args)
        if e.kind == "indirect":
            d = "dir=both, " if e.both else ""
            w(f'  "{e.src}" -> "{e.dst}" [{d}style=dashed, color="#999999", '
              f'fontcolor="#777777", label="via {esc(e.via)}"];')
        elif e.kind == "unknown":
            w(f'  "{e.src}" -> "{e.dst}" '
              f'[dir=none, style=dotted, label="{label}"];')
        elif e.kind == "bus":
            w(f'  "{e.src}" -> "{e.dst}" [color="#7aa7d0"];')
        elif e.kind == "iface":
            d = "dir=both, " if e.both else ""
            w(f'  "{e.src}" -> "{e.dst}" [{d}label="{label}", {iface_style}];')
        else:
            pen = 1.0 + min(n_sig, 8) * 0.12
            w(f'  "{e.src}" -> "{e.dst}" '
              f'[label="{label}", penwidth={pen:.2f}];')

    w("}")
    return "\n".join(out) + "\n"


# --------------------------------------------------------------------------
# Backend: draw.io / diagrams.net
#
# draw.io does no layout of its own on import, so the geometry comes from
# Graphviz: the DOT above is run through `dot -Tjson`, which reports every
# node centre in points and its size in inches.  Edges are left to draw.io's
# orthogonal router rather than baked as waypoints, so the wiring re-routes
# when a block is dragged -- which is the reason to want an editable file in
# the first place.
# --------------------------------------------------------------------------

DRAWIO_STYLE = {
    "module": "rounded=1;whiteSpace=wrap;html=1;fillColor=#e8f0fb;"
              "strokeColor=#3b6ea5;strokeWidth=1.5;verticalAlign=middle;"
              "fontSize=11;",
    "iface": "rounded=1;whiteSpace=wrap;html=1;fillColor=#fdf3e0;"
             "strokeColor=#b07d22;dashed=1;verticalAlign=middle;fontSize=11;",
    "blackbox": "rounded=0;whiteSpace=wrap;html=1;fillColor=#eeeeee;"
                "strokeColor=#666666;dashed=1;verticalAlign=middle;fontSize=11;",
    "group": "rounded=1;whiteSpace=wrap;html=1;fillColor=#eaf3ea;"
             "strokeColor=#3a7d52;strokeWidth=1.5;verticalAlign=middle;"
             "fontSize=11;shadow=1;",
    "glue": "rounded=0;whiteSpace=wrap;html=1;fillColor=#f0f0f0;"
            "strokeColor=#888888;verticalAlign=middle;fontSize=11;",
    "bus": "rounded=0;whiteSpace=wrap;html=1;fillColor=#eef4fb;"
           "strokeColor=#7aa7d0;fontSize=9;verticalAlign=middle;",
    "port_in": "shape=step;perimeter=stepPerimeter;whiteSpace=wrap;html=1;"
               "fixedSize=1;fillColor=#e6f4ea;strokeColor=#3a7d52;fontSize=11;",
    "port_out": "shape=step;perimeter=stepPerimeter;whiteSpace=wrap;html=1;"
                "fixedSize=1;fillColor=#fce8e6;strokeColor=#a5433b;fontSize=11;",
    "port_iface": "shape=step;perimeter=stepPerimeter;whiteSpace=wrap;html=1;"
                  "fixedSize=1;fillColor=#fdf3e0;strokeColor=#b07d22;dashed=1;fontSize=11;",
}

DRAWIO_EDGE = {
    "net": "edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;jettySize=auto;"
           "orthogonalLoop=1;strokeColor=#666666;fontSize=8;",
    "bus": "edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;jettySize=auto;"
           "orthogonalLoop=1;strokeColor=#7aa7d0;fontSize=8;",
    "iface": "edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;jettySize=auto;"
             "orthogonalLoop=1;strokeColor=#b07d22;fontColor=#8a6119;"
             "dashed=1;fontSize=8;",
    "unknown": "edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;jettySize=auto;"
               "orthogonalLoop=1;strokeColor=#666666;dashed=1;dashPattern=1 3;"
               "endArrow=none;fontSize=8;",
    "indirect": "edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;jettySize=auto;"
                "orthogonalLoop=1;strokeColor=#999999;dashed=1;"
                "dashPattern=8 4;fontColor=#777777;fontSize=8;",
}


def dot_json(dot_text):
    """`dot -Tjson`, as (top of the bounding box, {node: (cx, cy, w, h)})."""
    import json

    proc = subprocess.run(["dot", "-Tjson"], input=dot_text, text=True,
                          capture_output=True, check=True)
    data = json.loads(proc.stdout)
    _, _, _, top = (float(v) for v in data["bb"].split(","))

    nodes = {}
    for obj in data.get("objects", []):
        if "pos" not in obj:
            continue
        cx, cy = (float(v) for v in obj["pos"].split(","))
        nodes[obj["name"]] = (cx, cy,
                              float(obj["width"]) * 72.0,
                              float(obj["height"]) * 72.0)
    return top, nodes


def measure_boxes(g, lvl, args):
    """Box size for every node: what Graphviz needs, floored by the browser.

    Graphviz measures its own text exactly, so a first pass is asked what it
    would choose; html_box() supplies the floor for the same label rendered
    in a browser.  Taking the larger of the two per axis means one set of
    boxes satisfies both backends, and the layout is done over the boxes that
    actually get drawn -- no scale factor anywhere.
    """
    _, natural = dot_json(emit_dot(g, lvl, args))
    sizes = {}
    for key, node in g.nodes.items():
        gw, gh = natural.get(key, (0, 0, 0, 0))[2:]
        hw, hh = html_box(node, node.kind)
        sizes[key] = (max(gw, hw), max(gh, hh))
    for key, name in g.hubs.items():
        gw, gh = natural.get(key, (0, 0, 0, 0))[2:]
        hw = len(name) * 9 * CHAR_W + 16
        sizes[key] = (max(gw, hw), max(gh, 9 * LINE_H + 8))
    return sizes


def dot_geometry(dot_text):
    """Node boxes in draw.io pixel space.

    Graphviz reports positions in points with the origin bottom left; draw.io
    counts pixels from the top left, and one point is one pixel here.
    """
    top, nodes = dot_json(dot_text)
    return {name: (round(cx - w / 2, 2), round(top - cy - h / 2, 2),
                   round(w, 2), round(h, 2))
            for name, (cx, cy, w, h) in nodes.items()}


def drawio_label(n):
    """The same label as the DOT backend, in the HTML draw.io accepts."""
    lines = [f"<b>{esc(n.label_name)}</b>" +
             (f' <font color="#a5433b">&#215;{n.count}</font>'
              if n.count > 1 else "")]
    if n.label_type:
        lines.append(f'<font style="font-size:9px" color="#555555">'
                     f'{esc(n.label_type)}</font>')
    for p in n.params:
        lines.append(f'<font style="font-size:8px" color="#777777">'
                     f'{esc(p)}</font>')
    if n.gpath:
        lines.append(f'<font style="font-size:8px" color="#999999">'
                     f'{esc("/".join(n.gpath))}</font>')
    return "<br>".join(lines)


DRAWIO_MARGIN_X = 20
DRAWIO_MARGIN_Y = 110    # room for the title block above the diagram


def existing_positions(path):
    """Geometry of every vertex in an existing .drawio, keyed by cell id.

    Cell ids are node keys, so a block you moved by hand keeps its place when
    the diagram is regenerated: only blocks the file has never seen get a
    position from Graphviz.
    """
    import xml.etree.ElementTree as ET

    try:
        root = ET.parse(path).getroot()
    except Exception:
        return {}

    out = {}
    for cell in root.iter("mxCell"):
        if cell.get("vertex") != "1":
            continue
        geom = cell.find("mxGeometry")
        cid = cell.get("id")
        if geom is None or not cid:
            continue
        try:
            out[cid] = (float(geom.get("x", 0)), float(geom.get("y", 0)),
                        float(geom.get("width", 0)), float(geom.get("height", 0)))
        except ValueError:
            continue
    return out


def emit_drawio(g, lvl, args, dot_text, previous=None):
    # The boxes were sized before layout to satisfy both backends, so the
    # geometry Graphviz reports is used as-is: same boxes, same positions as
    # the SVG.
    boxes = {k: (round(x + DRAWIO_MARGIN_X, 2), round(y + DRAWIO_MARGIN_Y, 2),
                 bw, bh)
             for k, (x, y, bw, bh) in dot_geometry(dot_text).items()}

    # Anything the previous file already placed keeps its position; the size
    # still comes from this run, so a label that grew is not clipped.
    kept = 0
    for key, (x, y, _, _) in (previous or {}).items():
        if key in boxes:
            _, _, bw, bh = boxes[key]
            boxes[key] = (x, y, bw, bh)
            kept += 1
    emit_drawio.kept = kept
    out = []
    w = out.append

    w('<mxfile host="slang_hier_to_dot" type="device">')
    w(f'  <diagram id="{esc(lvl.module)}" name="{esc(lvl.module)}">')
    w('    <mxGraphModel dx="1200" dy="800" grid="1" gridSize="10" '
      'guides="1" tooltips="1" connect="1" arrows="1" fold="1" page="1" '
      'pageScale="1" pageWidth="1169" pageHeight="826" math="0" shadow="0">')
    w("      <root>")
    w('        <mxCell id="0" />')
    w('        <mxCell id="1" parent="0" />')

    # Cell ids are the node keys, so a regenerated file can be matched
    # against a hand-arranged one.
    def cell_id(key):
        return key

    # A title block, so the file carries the same provenance as the SVG.
    title = "<br>".join(re.sub(r"<[^>]+>", "", line) for line in g.head)
    w(f'        <mxCell id="title" value="{esc(title)}" '
      'style="text;html=1;align=left;verticalAlign=top;fontSize=11;'
      'fillColor=none;strokeColor=none;whiteSpace=wrap;" '
      'vertex="1" parent="1">')
    w(f'          <mxGeometry x="{DRAWIO_MARGIN_X}" y="10" width="900" '
      'height="90" as="geometry" />')
    w("        </mxCell>")

    all_nodes = list(g.nodes.values())
    for n in all_nodes:
        x, y, bw, bh = boxes.get(n.key, (0, 0, 120, 40))
        w(f'        <mxCell id="{esc(cell_id(n.key))}" '
          f'value="{esc(drawio_label(n))}" '
          f'style="{DRAWIO_STYLE[n.kind]}" vertex="1" parent="1">')
        w(f'          <mxGeometry x="{x}" y="{y}" width="{bw}" '
          f'height="{bh}" as="geometry" />')
        w("        </mxCell>")

    for key, name in sorted(g.hubs.items()):
        x, y, bw, bh = boxes.get(key, (0, 0, 80, 20))
        w(f'        <mxCell id="{esc(cell_id(key))}" value="{esc(name)}" '
          f'style="{DRAWIO_STYLE["bus"]}" vertex="1" parent="1">')
        w(f'          <mxGeometry x="{x}" y="{y}" width="{bw}" '
          f'height="{bh}" as="geometry" />')
        w("        </mxCell>")

    for i, e in enumerate(g.edges):
        if e.kind == "indirect":
            label = f"via {e.via}"
        else:
            label, _ = edge_label(e.names, args, sep="<br>")
        style = DRAWIO_EDGE[e.kind]
        if e.both:
            style += "startArrow=classic;startFill=1;"
        # The layout runs left to right, so leaving on the right edge and
        # arriving on the left keeps the router from cutting through boxes.
        src_box, dst_box = boxes.get(e.src), boxes.get(e.dst)
        if src_box and dst_box and src_box[0] < dst_box[0]:
            style += "exitX=1;exitY=0.5;exitDx=0;exitDy=0;" \
                     "entryX=0;entryY=0.5;entryDx=0;entryDy=0;"
        w(f'        <mxCell id="{esc(f"edge:{e.kind}:{e.src}>{e.dst}:{i}")}" '
          f'value="{esc(label)}" '
          f'style="{style}" edge="1" parent="1" '
          f'source="{esc(cell_id(e.src))}" target="{esc(cell_id(e.dst))}">')
        w('          <mxGeometry relative="1" as="geometry" />')
        w("        </mxCell>")

    w("      </root>")
    w("    </mxGraphModel>")
    w("  </diagram>")
    w("</mxfile>")
    return "\n".join(out) + "\n"


# --------------------------------------------------------------------------
# Driver
# --------------------------------------------------------------------------

def elaborate(slang_args):
    d = slang_driver.Driver()
    d.addStandardArgs()
    cmd = "slang " + " ".join(shlex.quote(a) for a in slang_args)
    if not d.parseCommandLine(cmd):
        sys.exit("error: slang rejected the command line")
    if not d.processOptions():
        sys.exit("error: slang could not process the given options")
    if not d.parseAllSources():
        sys.exit("error: parsing failed")
    return d, d.createCompilation()


def find_levels(root, wanted):
    """First (shallowest) instance of each requested module."""
    found, seen = {}, set()
    queue = list(root.topInstances)
    while queue:
        nxt = []
        for inst in queue:
            name = inst.definition.name
            if name in wanted and name not in found:
                found[name] = inst
            path = canon(inst.hierarchicalPath)
            if path in seen:
                continue
            seen.add(path)

            def child(sym, _n, _c, _g, acc=nxt):
                if not sym.isInterface:
                    acc.append(sym)

            walk_scope(inst.body, (), child, lambda s: None)
        queue = nxt
        if len(found) == len(wanted):
            break
    return found


def all_module_names(root):
    names = set()
    seen = set()
    queue = list(root.topInstances)
    while queue:
        nxt = []
        for inst in queue:
            names.add(inst.definition.name)
            path = canon(inst.hierarchicalPath)
            if path in seen:
                continue
            seen.add(path)

            def child(sym, _n, _c, _g, acc=nxt):
                if not sym.isInterface:
                    acc.append(sym)

            walk_scope(inst.body, (), child, lambda s: None)
        queue = nxt
    return sorted(names)


def main():
    ap = argparse.ArgumentParser(
        description="Per-level block diagrams from an elaborated slang design.",
        epilog="Arguments after -- are passed to slang unchanged.")
    ap.add_argument("--level", action="append", default=[], metavar="MODULE",
                    help="module to draw (repeatable); default: the top")
    ap.add_argument("--outdir", default=".", type=Path)
    ap.add_argument("--format", default="svg", metavar="FMT[,FMT...]",
                    help="output formats, comma separated: svg, png, pdf, "
                         "dot, drawio (default svg). 'drawio' writes an "
                         "editable diagrams.net file, laid out by Graphviz")
    ap.add_argument("--hide-nets", default=DEFAULT_HIDE_NETS, metavar="REGEX",
                    help="nets not drawn as edges (default: clocks and resets)")
    ap.add_argument("--show-all-nets", action="store_true",
                    help="draw clock/reset nets too")
    ap.add_argument("--child-params", type=int, default=3, metavar="N",
                    help="resolved parameters shown per child box (default 3)")
    ap.add_argument("--max-edge-labels", type=int, default=4, metavar="N",
                    help="signal names shown on one edge (default 4)")
    ap.add_argument("--bus-threshold", type=int, default=4, metavar="N",
                    help="draw a net as a shared bus node once it would need "
                         "N or more point-to-point edges (default 4)")
    ap.add_argument("--no-preserve-positions", dest="preserve_positions",
                    action="store_false",
                    help="place every block from the Graphviz layout, "
                         "discarding positions in an existing .drawio")
    ap.add_argument("--emit-model", metavar="FILE", type=Path,
                    help="write the extracted model as JSON and (unless "
                         "--format is given too) stop there")
    ap.add_argument("--from-model", metavar="FILE", type=Path,
                    help="render from a model JSON file instead of "
                         "elaborating; no slang arguments are needed")
    ap.add_argument("--no-legend", dest="legend", action="store_false",
                    help="omit the legend box")
    ap.add_argument("--list-modules", action="store_true",
                    help="list module names in the elaborated hierarchy, then exit")
    args, rest = ap.parse_known_args()

    if rest and rest[0] == "--":
        rest = rest[1:]

    if args.show_all_nets:
        args.hide_nets = None

    if args.from_model:
        if rest:
            ap.error("--from-model takes no slang arguments")
        levels = levels_from_model(json.loads(args.from_model.read_text()))
        if args.level:
            keep = set(args.level)
            levels = [l for l in levels if l.module in keep]
    else:
        if not rest:
            ap.error("no slang arguments given (put them after --)")

        d, comp = elaborate(rest)
        root = comp.getRoot()
        if not root.topInstances:
            sys.exit("error: no top instance was elaborated")

        if args.list_modules:
            for n in all_module_names(root):
                print(n)
            return 0

        wanted = args.level or [root.topInstances[0].definition.name]
        found = find_levels(root, set(wanted))
        for m in wanted:
            if m not in found:
                print(f"warning: no instance of '{m}' in the elaborated "
                      f"hierarchy", file=sys.stderr)
        levels = [build_level(m, found[m], args) for m in wanted
                  if m in found]

    if args.emit_model:
        args.emit_model.write_text(
            json.dumps(model_from_levels(levels), indent=1, sort_keys=True))
        print(f"model: {len(levels)} level(s) -> {args.emit_model}")
        if args.format == ap.get_default("format"):
            return 0

    formats = [f.strip() for f in args.format.split(",") if f.strip()]
    unknown = [f for f in formats if f not in
               ("svg", "png", "pdf", "dot", "drawio")]
    if unknown:
        ap.error(f"unknown format(s): {', '.join(unknown)}")

    args.outdir.mkdir(parents=True, exist_ok=True)
    have_dot = shutil.which("dot") is not None
    if not have_dot and set(formats) - {"dot"}:
        print("warning: Graphviz 'dot' not found; writing .dot only",
              file=sys.stderr)
        formats = ["dot"]
    rc = 0

    for lvl in levels:
        module = lvl.module
        graph = build_graph(lvl, args)
        if have_dot:
            # Size every box first, then lay out over those boxes, so the SVG
            # and the draw.io file are the same diagram rather than two
            # approximations of it.
            dot_text = emit_dot(graph, lvl, args,
                                sizes=measure_boxes(graph, lvl, args))
        else:
            dot_text = emit_dot(graph, lvl, args)

        n_mod = sum(1 for n in graph.nodes.values() if n.kind == "module")
        n_if = sum(1 for n in graph.nodes.values() if n.kind == "iface")
        n_bb = sum(1 for n in graph.nodes.values() if n.kind == "blackbox")
        extra = f", {n_bb} black boxes" if n_bb else ""
        print(f"{module}: {n_mod} instances, {n_if} interfaces{extra}, "
              f"{len(graph.edges)} edges")

        # The .dot is always written: it is the input the other formats and
        # the draw.io layout are derived from.
        dot_path = args.outdir / f"{module}.dot"
        dot_path.write_text(dot_text)
        written = [dot_path] if "dot" in formats else []

        for fmt in formats:
            if fmt == "dot":
                continue
            if fmt == "drawio":
                out_path = args.outdir / f"{module}.drawio"
                previous = (existing_positions(out_path)
                            if args.preserve_positions and out_path.exists()
                            else {})
                out_path.write_text(
                    emit_drawio(graph, lvl, args, dot_text, previous))
                if previous and getattr(emit_drawio, "kept", 0):
                    print(f"    (kept {emit_drawio.kept} hand-placed "
                          f"position(s) from the existing file)")
            else:
                out_path = args.outdir / f"{module}.{fmt}"
                subprocess.run(["dot", f"-T{fmt}", str(dot_path),
                                "-o", str(out_path)], check=True)
            written.append(out_path)

        if "dot" not in formats:
            dot_path.unlink()
        for path in written:
            print(f"    {path}")

    return rc


if __name__ == "__main__":
    sys.exit(main())
