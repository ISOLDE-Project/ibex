#!/usr/bin/env python3
"""Does the generated dataset support the task, and does it need the sequence?

Trains the hardware-shaped encoder (2 layers, d_model=16, one head,
ReLU-attention, ReLU MLP, no LayerNorm) and three references:

  majority      - the balanced-class floor, 25%
  linear        - logistic regression on the flattened 12x32 window
  frame-bag     - mean over frames, then an MLP; blind to frame order
  softmax-attn  - same encoder with ordinary softmax attention

The frame-bag reference is the one that matters: if it matches the encoder,
the dataset does not need a sequence model and the demo would be dishonest.
This is a host-side check in float32.  It is not the FP16 export path and it
says nothing about RTL.
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

D_MODEL, D_FF, N_LAYERS, N_CLASSES = 16, 48, 2, 4


class Encoder(nn.Module):
    """Shapes chosen so every matrix product is one 12x16 . 16x16 RedMulE tile."""

    def __init__(self, n_features, frames, attention='relu', pool='mean'):
        super().__init__()
        self.attention, self.pool = attention, pool
        self.proj = nn.Linear(n_features, D_MODEL, bias=False)
        self.pos = nn.Parameter(torch.zeros(frames, D_MODEL))
        nn.init.normal_(self.pos, std=0.02)
        self.qkv = nn.ModuleList()
        self.mlp = nn.ModuleList()
        # One learnable scalar per layer on the attention branch.  It exists
        # only so the 1/L downscale does not start the branch 12x too small;
        # at export it multiplies into W_v and costs nothing on hardware.
        self.gate = nn.Parameter(torch.full((N_LAYERS,), float(np.log(12.0))))
        for _ in range(N_LAYERS):
            self.qkv.append(nn.ModuleDict(dict(
                q=nn.Linear(D_MODEL, D_MODEL, bias=False),
                k=nn.Linear(D_MODEL, D_MODEL, bias=False),
                v=nn.Linear(D_MODEL, D_MODEL, bias=False),
                o=nn.Linear(D_MODEL, D_MODEL, bias=False))))
            self.mlp.append(nn.Sequential(
                nn.Linear(D_MODEL, D_FF, bias=False), nn.ReLU(),
                nn.Linear(D_FF, D_MODEL, bias=False)))
        self.head = nn.Linear(D_MODEL, N_CLASSES, bias=False)

    def forward(self, x):
        length = x.shape[1]
        h = self.proj(x) + self.pos
        for layer, (attn, mlp) in enumerate(zip(self.qkv, self.mlp)):
            q, k, v = attn['q'](h), attn['k'](h), attn['v'](h)
            scores = q @ k.transpose(1, 2) / D_MODEL ** 0.5
            if self.attention == 'relu':
                # Wortsman et al. 2023: ReLU(QK^T)/L in place of softmax.
                # 1/L and the gate are constants; both fold into W_v at export.
                weights = F.relu(scores) * (self.gate[layer].exp() / length)
            else:
                weights = scores.softmax(dim=-1)
            h = h + attn['o'](weights @ v)
            h = h + mlp(h)
        pooled = h.mean(dim=1) if self.pool == 'mean' else h[:, -1]
        return self.head(pooled)


class FrameBag(nn.Module):
    """Order-blind reference: pool over frames first, then classify."""

    def __init__(self, n_features, frames):
        super().__init__()
        del frames
        self.net = nn.Sequential(nn.Linear(n_features, 64), nn.ReLU(),
                                 nn.Linear(64, 64), nn.ReLU(),
                                 nn.Linear(64, N_CLASSES))

    def forward(self, x):
        return self.net(x.mean(dim=1))


class Linear(nn.Module):
    def __init__(self, n_features, frames):
        super().__init__()
        self.net = nn.Linear(n_features * frames, N_CLASSES)

    def forward(self, x):
        return self.net(x.flatten(1))


def accuracy(model, x, y, batch=512):
    model.eval()
    correct = 0
    with torch.no_grad():
        for i in range(0, len(x), batch):
            correct += (model(x[i:i + batch]).argmax(1)
                        == y[i:i + batch]).sum().item()
    return correct / len(x)


def train(model, data, epochs, lr, seed, label):
    torch.manual_seed(seed)
    opt = torch.optim.AdamW(model.parameters(), lr=lr, weight_decay=1e-2)
    sched = torch.optim.lr_scheduler.OneCycleLR(
        opt, max_lr=lr, total_steps=epochs * max(1, len(data['xtr']) // 128))
    best, best_state = 0.0, None
    for _ in range(epochs):
        model.train()
        order = torch.randperm(len(data['xtr']))
        for i in range(0, len(order) - 127, 128):
            idx = order[i:i + 128]
            loss = F.cross_entropy(model(data['xtr'][idx]), data['ytr'][idx])
            opt.zero_grad()
            loss.backward()
            opt.step()
            sched.step()
        val = accuracy(model, data['xva'], data['yva'])
        if val > best:
            best = val
            best_state = {k: v.clone() for k, v in model.state_dict().items()}
    model.load_state_dict(best_state)
    test = accuracy(model, data['xte'], data['yte'])
    print(f'{label:<14} val {best:6.3f}   test {test:6.3f}   '
          f'params {sum(p.numel() for p in model.parameters()):,}')
    return model, test


def confusion(model, x, y, classes):
    with torch.no_grad():
        pred = model(x).argmax(1)
    table = np.zeros((len(classes), len(classes)), dtype=int)
    for t, p in zip(y.tolist(), pred.tolist()):
        table[t, p] += 1
    width = max(len(c) for c in classes)
    print(f'\nconfusion (rows = truth)\n{"":<{width}}  '
          + '  '.join(f'{c[:5]:>5}' for c in classes))
    for i, c in enumerate(classes):
        print(f'{c:<{width}}  ' + '  '.join(f'{v:5d}' for v in table[i]))
    return table


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--data', type=Path,
                        default=Path('results/radar_sequences.npz'))
    parser.add_argument('--epochs', type=int, default=60)
    parser.add_argument('--seed', type=int, default=0)
    args = parser.parse_args()

    blob = np.load(args.data)
    classes = ('static', 'approaching', 'receding', 'crossing')
    data = {}
    for short, name in (('tr', 'train'), ('va', 'val'), ('te', 'test')):
        data['x' + short] = torch.tensor(blob[f'{name}_x'], dtype=torch.float32)
        data['y' + short] = torch.tensor(blob[f'{name}_y'], dtype=torch.long)
    frames, n_features = data['xtr'].shape[1], data['xtr'].shape[2]
    print(f'train {tuple(data["xtr"].shape)}  frames {frames}  '
          f'features {n_features}\n')
    print(f'{"majority":<14} val  0.250   test  0.250   (balanced floor)')

    train(Linear(n_features, frames), data, args.epochs, 3e-3,
          args.seed, 'linear')
    train(FrameBag(n_features, frames), data, args.epochs, 3e-3,
          args.seed, 'frame-bag')
    softmax_model, _ = train(
        Encoder(n_features, frames, attention='softmax'), data,
        args.epochs, 3e-3, args.seed, 'softmax-attn')
    relu_model, _ = train(
        Encoder(n_features, frames, attention='relu'), data,
        args.epochs, 3e-3, args.seed, 'relu-attn')

    del softmax_model
    confusion(relu_model, data['xte'], data['yte'], classes)


if __name__ == '__main__':
    main()
