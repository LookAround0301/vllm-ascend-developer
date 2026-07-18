# Plan: AscendStore prefill offload — support the separated SFA indexer (transformer-layer-bundled layout)

## Context

pr-11647 (merged) split the SFA indexer into its own `AscendSFAIndexerCacheSpec` — a separate `kv_caches` dict entry (`model.layers.N.self_attn.indexer.k_cache`) instead of packed into the MLA `AscendMLAAttentionSpec` via `sparse_head_dim`. Because MLA and indexer are both `FullAttentionSpec`-based with the same `block_size`, vLLM merges them into ONE `UniformTypeKVCacheSpecs` group (page_size_bytes = SUM), so `kv_caches` now has **2N entries** (N MLA tuples + N indexer tuples) and `unify` does NOT run.

The AscendStore `KVPoolWorker` / `kv_transfer.py` assume a **flat N-layers × 1-cache-each** model. The 2N split silently breaks it (wrong `num_layers`, `caches_per_layer`, GVA stride, save/load, buffer-merge inflation). A non-C8 `page_bytes_per_token` pad I added earlier also crashes the indexer reshape (no `unify` here, so the pad is meaningless).

**Goal (user):** make the AscendStore path properly support the separated indexer **with indexer buffer reuse** (packing it back is NOT acceptable). "一步改到位".

**Key insight (verified):** `kv_transfer.py:LayerBatchBuilder._build_transfer_arrays` already slices per transformer layer by `caches_per_layer` (lines 117-120) — it is **already multi-leg-capable** and needs no change. The whole rework is: feed it a transformer-layer-ordered flat array with `num_layers = N`, so one save/load of transformer layer L covers the MLA leg(s) **and** the indexer leg. The indexer has no attention forward (no save hook) — it is saved/loaded as a side-effect of its transformer-layer page. This is **Option A: transformer-layer-bundled layout**.

## Changes

### 1. Revert the harmful non-C8 indexer page pad (do first)
- `core/kv_cache_interface.py`: delete `offload_indexer_aligned_bytes_per_token` (the helper added for the pad).
- `worker/model_runner_v1.py` `get_kv_cache_spec` indexer branch: drop the `indexer_page_bytes_per_token = offload_indexer_aligned_bytes_per_token(...)` computation, pass `page_bytes_per_token=None` for the non-C8 indexer (truthful `real_page_size_bytes`). Remove the import. (C8 / `compute_offload_sparse_c8_layout` / `make_offload_*` paths are untouched.)
- Tests: drop the two alignment UTs added in `tests/ut/core/test_kv_cache_interface.py`.
- Why: `unify` does not run in this path, so the pad (288 vs true 256) just crashes the indexer reshape (`model_runner_v1.py:4999-5003`).

### 2. Remove the group-skip in `initialize_attn_backend`
- `worker/model_runner_v1.py:5414-5419`: delete `if 'indexer' in kv_cache_group_spec.layer_names[0]: continue`. The per-layer dispatch at `get_attn_backends_for_group` (5362-5390) already routes indexer layers to `AscendSFAIndexerBackend`; the skip is redundant and ordering-dependent (drops the whole mixed group → empty `kv_caches` → crash when an indexer name is first).

### 3. Rework `register_kv_caches` → transformer-layer-ordered multi-leg layout (core)
`distributed/kv_transfer/kv_pool/ascend_store/pool_worker.py:register_kv_caches` (580-708):
- **Stop overwriting `num_layers`** from `sum(group_num_layers.values())` (681-692). Keep `self.num_layers = N` (transformer layers, already set in `_init_key_head_config`). The `updated num_layers N->2N` log disappearing is a verification signal.
- **Replace** the flat `_infer_cache_group_metadata(0, list(kv_caches.keys()))` (676) with a transformer-layer-ordered builder (new helper, e.g. `_infer_transformer_layer_group_metadata(group_id, kv_caches, group_spec)`):
  - Parse transformer-layer id `L` from each key (`model.layers.{L}.self_attn.attn` / `.indexer.k_cache`).
  - Classify MLA-leg vs indexer-leg (by spec type / name).
  - Emit, for `L` in 0..N-1: all caches of the MLA tuple (in order), then all caches of the indexer tuple → flat `[MLA_k0, MLA_v0, idx_k0, MLA_k1, …]` (length 3N non-C8). Assert `len(flat) == N * caches_per_layer` and every layer has the expected leg set (raise NotImplementedError for shared-indexer models where a layer lacks `.indexer.k_cache`).
  - Populate `group_kv_caches_base_addr[0]`, `group_block_len[0]`, `group_block_stride[0]`, `group_num_layers[0] = N`, `caches_per_layer = len(flat)//N`.
- `self.page_size_bytes = sum(group_block_len[0][:caches_per_layer])` (one transformer layer's legs) → equals the scheduler's uniform-group SUM `page_size_bytes` (bug 3 scheduler-vs-worker consistency).
- `LayerBatchBuilder` (kv_transfer.py) and `ChunkedTokenDatabase.prepare_value_layer` (config_data.py) then work unchanged (both slice per-layer by `caches_per_layer`).

### 4. Fix the buffer merge for 2N tensors (layerwise reuse, no OOM)
`worker/model_runner_v1.py`:
- `_merge_kv_cache_tensors_for_layer_reuse` (4106-4192): replace the bail `if len(layer_names) != total_layers: return` (4132-4138). Accept 2N names; classify via the existing `_layout_class` (MLA vs indexer); run the independent/reused round-robin **per layout class** with `num_layers = N`; concatenate per-class `storage_indices`. Propagate `_layerwise_reuse_mate_map` keyed by **transformer-layer id 0..N-1** (MLA(L) and indexer(L) load together as layer L).
- `get_layerwise_num_tensors` (4071-4104): fix the count to be class-aware — `sum_over_classes(len(independent_layers) + num_shared_buffers)` (= `num_classes*(independent+nsb)` when every transformer layer has every class). Add a hard assert in the merge that `len(new_tensors) == get_layerwise_num_tensors(extra_config)` so the `worker.py:617-626` inflation factor is exact (removes the ~20× OOM).

### 5. Verify (no change) + assert
- `kv_transfer.py:_build_transfer_arrays` (106-135): already correct for multi-leg per layer; add a `__init__` assert `self._block_len_np.shape[0] == num_layers * self._caches_per_layer`.
- `ascend_store_connector.py:106` scheduler `page_size_bytes` (group SUM) now matches the worker stride; add a debug-log/assert.

## Data flow after the change
- **Save:** MLA forward for transformer layer L → `maybe_save_kv_layer_to_connector` (sfa_v1.py, after o_proj) → `save_kv_layer(current_layer=L)` → sending thread `batch_copy` HBM→GVA for **all legs of L** (MLA k/v + indexer k). Indexer saved as a side-effect — no indexer save hook needed. Step-end drain fires at L=N-1.
- **Load (prefix hit):** `wait_for_layer_load(L)` (gated on transformer-layer reuse-mate) → recv thread `batch_copy` GVA→HBM for all legs of L → indexer K restored before the MLA forward reads it inline.

## Verification
- **Unit tests** (`tests/ut/distributed/ascend_store/`): feed `register_kv_caches` a 2N dict (N MLA 2-tuples + N indexer 1-tuples), assert `num_layers==N`, `group_num_layers[0]==N`, `caches_per_layer==3`, flat order `[MLA_k_L, MLA_v_L, idx_k_L, …]`, `page_size_bytes == MLA_page+indexer_page`. Add a `LayerBatchBuilder` test that transfer arrays for layer L cover exactly its 3 legs at the right `rank_layer_offset`. Add a merge test: 2N → `num_classes*(independent+nsb)` tensors, MLA/indexer never in the same `shared_by`, reuse-mate map keyed 0..N-1. Add a reshape regression UT that an `AscendSFAIndexerCacheSpec(page_bytes_per_token=None)` no longer assert-fails.
- Run: `pytest tests/ut/distributed/ascend_store/ tests/ut/worker/a2/test_model_runner_v1.py tests/ut/core/test_kv_cache_interface.py`.
- **On-NPU** (`prefill_kv_offload_lxs.sh`, GLM-5.2, non-C8): (1) the `KVPoolWorker: updated num_layers N->2N` log is GONE; (2) diag log shows `kv_caches=2N` but `group_num_layers[0]=N`; (3) step-end save drain fires (no timeout warnings); (4) identical prompt sent twice → 2nd prefill hits pool, reloads MLA+indexer, token-identical to a no-offload baseline; (5) no OOM with `layerwise_num_shared_buffers=2`.

## Critical files
- `vllm_ascend/distributed/kv_transfer/kv_pool/ascend_store/pool_worker.py` (register_kv_caches rework — core)
- `vllm_ascend/worker/model_runner_v1.py` (revert pad; remove group-skip; fix merge + get_layerwise_num_tensors)
- `vllm_ascend/core/kv_cache_interface.py` (delete the pad helper)
- `vllm_ascend/distributed/kv_transfer/kv_pool/ascend_store/kv_transfer.py` (assert only)
- Secondary: `ascend_store_connector.py`, `config_data.py`, `worker/worker.py`

## Risk
- `get_layerwise_num_tensors` must exactly equal the merged buffer count or OOM/under-use — hard-assert it.
- Flat-layout ordering must be uniform across transformer layers — assert `len(flat)==N*caches_per_layer`; guard shared-indexer models.
- Reuse-mate map must be keyed 0..N-1 (transformer layer), not 2N — assert max key.
