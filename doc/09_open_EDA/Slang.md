
## The flags for "what files/modules does this top need"

| Flag | What it gives you |
|---|---|
| `--Mall` (`--all-deps`) | **All** files used during parsing (sources + includes) |
| `--Mmodule` (`--module-deps`) | Source files parsed, **excluding** includes |
| `--Minclude` (`--include-deps`) | Just the include files used |
| `--depfile-trim` | **Trim unreferenced files** — this is the key one for "minimal set" |
| `--depfile-sort` | Topologically sort the output |
| `--depfile-target` | Emit in makefile `target:` format |

## Recommended invocation for your case

Get the minimal source-file set actually needed by `$(SLANG_TOP_MODULE)`:

```
slang --top $(SLANG_TOP_MODULE) \
    --timescale 1ns/1ps \
    -f ibex_sim.slang -f manifest.slang \
    --Mmodule top_modules.f \
    --depfile-trim
```

- `--Mmodule` → source files only (no `.svh` noise)
- `--depfile-trim` → drops files not referenced from the top (also implies `--depfile-sort`)

Result: `top_modules.f` is the pruned filelist for that top.

### If you want everything including headers:
```
slang --top $(SLANG_TOP_MODULE) -f ibex_sim.slang -f manifest.slang \
    --Mall top_all_deps.f --depfile-trim
```

### If you want to plug it into Make:
```
slang --top $(SLANG_TOP_MODULE) -f ibex_sim.slang -f manifest.slang \
    --Mall $(SLANG_TOP_MODULE).d --depfile-target --depfile-trim
```

## For the module → file mapping (not just files)
Combine with AST JSON:
```
slang --top $(SLANG_TOP_MODULE) -f ibex_sim.slang -f manifest.slang \
    --ast-json ast.json --ast-json-source-info
```
Then each instance carries its source location → module-to-file mapping.

## Key insight
`--depfile-trim` is what makes this answer the exact question you asked: **"which files are actually needed by this top."** Without it, `--Mmodule`/`--Mall` list everything parsed; with it, unreferenced files are removed, leaving the true dependency set for `--top`.