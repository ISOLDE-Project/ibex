

## The programming model 



| Concern |  Primitive | CSR |
|---|---|---|
| **Select device** | `isolde_set_tile(t)` / `isolde_get_tile()` | `0x7C2` |
| **Enable which tiles wake CPU** | `isolde_set_intr_en(mask)` | `0x7C3` |
| **# devices** | `isolde_get_tile_cnt()` | `0x7C5` |
| **Which device is free** | `isolde_get_tile_status()` (busy level) | `0x7C8` |
| **Which device finished** | `isolde_get_tile_ip()` + `isolde_clear_tile_ip(mask)` (W1C) | `0x7C9` |
| **Upload / download** | `spm_write` / `spm_read` (TILESEL-routed) | — |
| **Launch** | `redmule.gemm t0,t1,t2,N,M,K` | — |

**Note:**  
-  **3-NOP delay** before reading `STATUS` —  `busy` needs 3 cycles to assert after issue. The scheduler must account for this (read STATUS *after* the accept propagates, not the same cycle as launch).
- `isolde_clear_tile_ip(-1)` clears all bits (W1C with `0xFFFFFFFF`) — confirms W1C semantics are live in the RTL now.

## SPM access policy
| Path                | Intended use                                                             |
| ------------------- | ------------------------------------------------------------------------ |
| CPU → SPM           | Small/sparse configuration writes, inspection, debug, bring-up, recovery |
| Loader → SPM        | Bulk program, weights, state, and data transfers                         |
| SPM → CPU           | Occasional status/debug reads                                            |
| SPM → loader → DMEM | Bulk result download                                                     |

The system provides both CPU-direct and hardware-loader access to the scratchpad memory (SPM). CPU-direct access is intended for small or sparse configuration transfers, inspection, debugging, bring-up, and recovery, whereas the SPM loader is the preferred path for bulk uploads and downloads between DMEM and SPM. Concurrent CPU and loader access to shared DMEM or SPM is not guaranteed: a CPU memory transaction may be delayed until the loader completes, and software must not access the SPM directly while the loader is busy. This is an intentional design trade-off because the CPU primarily acts as a tile manager. Software should configure and start the loader, wait for its completion event—preferably using wfi—and resume memory-dependent management operations afterward. Fair arbitration would be required only if simultaneous CPU and loader memory progress becomes a system requirement.