---
name: runtime-patches-override-upstream
description: In this workspace vllm-ascend monkeypatches/NPUModelRunner override upstream vllm at runtime — static reads of vllm/ mislead
metadata: 
  node_type: memory
  type: project
  originSessionId: 04e9b972-e620-4988-bbdb-20ea9f61cfe6
---

In `/home/l00889328/offload`, the **runtime** behavior of vLLM is heavily overridden by `vllm-ascend/`; static reads of upstream `vllm/vllm/...` will mislead. Confirmed overrides seen while tracing GLM5.2 KV cache init:

- `vllm_ascend/worker/model_runner_v1.py:289` `class NPUModelRunner(GPUModelRunner)` overrides `get_kv_cache_spec` / `initialize_kv_cache` / `_allocate_kv_cache_tensors` / `_reshape_kv_cache_tensors` (upstream originals in `vllm/v1/worker/gpu_model_runner.py`).
- `vllm_ascend/patch/worker/patch_deepseek_v2.py:283` REPLACES `DeepseekV2MLAAttention.__init__` — shared indexer layers get `self.indexer=None` (upstream constructs an Indexer on every layer). This is why GLM5.2 shared layers have `has_indexer=False` and only 2-tuple KV.
- `vllm_ascend/patch/platform/patch_kv_cache_utils.py` overrides KV cache grouping (`group_and_unify_kv_cache_specs`, `_get_kv_cache_config_*`, `resolve_kv_cache_block_sizes`).

**Why:** I concluded wrong twice this session by reading upstream `vllm/` (e.g. "every layer constructs Indexer → has_indexer=True") when the runtime patch made it False. The patch/override layer is the source of truth at runtime, not the upstream source on disk.
**How to apply:** Before claiming runtime behavior from `vllm/`, grep `vllm_ascend/patch/` and check for `NPUModelRunner`/worker overrides of the relevant method. Prefer empirical confirmation — add a `logger.info("AscendStore diag[...]")` and have the user run on the Ascend box; logs land in `online_1.log` / `offload*.log` at the workspace root. See `kv-init-report.md` (workspace root) for the full GLM5.2 KV-init walkthrough, but note it was written against HEAD `304ba9df0` and is partially stale after the branch was reset to `d5cfdb8f8` (§7.4 mis-addressing needs re-verification).
