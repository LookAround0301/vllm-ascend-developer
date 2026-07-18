---
name: weight-load-optimization
description: "State of MoE expert weight-load speedup + cleanup work — committed, what's done, deferred next step."
metadata:
  node_type: memory
  type: project
  originSessionId: dab01221-9e76-4ee5-ac7f-73d7a9e4765d
---

Expert-offload weight loading was ~10 min; reduced to ~3.6 min and the load-path code cleaned up. Committed 2026/06/14 on branch `moe_offload_v5.0` (both repos local/unpushed — normal `git push`, no force):
- `vllm-ascend` `e103aca0` — "refactor(expert_offload): rework expert weight-load path" (4 files: expert_offload_manager.py, ascend_config.py, fused_moe.py, model_runner_v1.py)
- `vllm` `f53bb4fb0` — "fix(expert_offload): log _expert_map override once at info level" (layer.py only)

**Root cause (confirmed by instrumentation + microbenchmarks, NOT hypothesis):** the dominant cost was the single-threaded strided transpose-copy `cpu[:, :I].copy_(w.t())` into pinned memory in `load_w13`/`load_w2` — ~0.24 GB/s single-thread (99072 serial calls). NOT the NZ round-trip (`nz_cast` is ~1s) and NOT disk (dtfs reads at 4.5 GB/s, page cache warm with 2TB RAM).

**Fix applied:** 32-worker `ThreadPoolExecutor`. Each load entry point clones `loaded_weight` synchronously (owns the bytes while the safetensors mmap is still mapped — the mmap unmaps before `_finalize_offload`, so the clone is mandatory for correctness) and submits the strided copy to the pool. `set_num_threads(1)` to stop libgomp spawning nproc threads/worker. `drain_load_pool()` barriers at start of `_finalize_offload`. Result: 546s → ~136s. The clone is now the synchronous bottleneck (~2 GB/s).

**Cleanup also done (in the same commits):**
- scale/offset CPU buffers now allocated 1D (post-flatten shape) → removed 8 copy-site `.reshape()` band-aids. The reshapes were load-bearing (bridging CPU `[H,1]` pre-flatten alloc vs device `[H]` post-flatten slot, because W8A8 `process_weights_after_loading` flattens AFTER `__init__`); fixed at the allocation root, not by deleting blindly. 2 reshapes kept in the load path (legitimate shard flatten). Code has an explanatory comment — don't re-add reshapes.
- `init_device_experts` → `refresh_fp32_scales`; dropped `_byte_sizes_set` redundancy.
- `vllm/.../fused_moe/layer.py` hook: per-layer WARNING (43 dup lines) → `logger.info_once`, message `[0..count-1]`.
- Offload debug unified under one switch `expert_offload_config.moe_offload_debug` (renamed from `cache_debug_log_updates`); when on, UPDATE-W/PREFILL_LOAD/PREFETCH diagnostics surface at info level (no need for global `VLLM_LOGGING_LEVEL=DEBUG`). run.sh/CLAUDE.md updated to match.

**Deferred (the only clear remaining win):** remove the clone — let workers read the mmap view directly. Requires a drain hook placed *before* the safetensors mmap closes (it closes when `model.load_weights` returns in `get_model`; `_finalize_offload` is after). Would take weight-load 136s → ~40s. Bigger change, higher risk.

**Not worth it:** `process_weights` (NZ round-trip, ~45s) is dominated by ±25s run-to-run system variance on the shared 640-core box (the `stack+h2d` phase swung 21–50s across runs with identical code). Micro-opts like killing `torch.stack` (~10s) are inside the noise band.

**Env constraints:** model on dtfs `/mnt/share` (280 GB, 256 experts × 43 layers, W8A8 int8), 2 TB RAM, 640 cores, but local nvme `/mnt` has only 39 GB free — cannot copy the model local, so optimization must be in-process. See [[measure-before-optimize]] and [[commit-style]].
