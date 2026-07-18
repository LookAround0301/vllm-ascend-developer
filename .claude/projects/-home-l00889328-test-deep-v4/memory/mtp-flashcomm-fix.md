---
name: mtp-flashcomm-fix
description: GLM-5 MTP3+flashcomm acceptance rate fix - root cause analysis and partial fixes applied
metadata: 
  node_type: memory
  type: project
  originSessionId: 8dacf6c4-ccce-48d7-883b-58b947a2cffd
---

GLM-5 MTP3+flashcomm (VLLM_ASCEND_ENABLE_FLASHCOMM1=1) acceptance rate is low (Mean 1.3-1.8 vs target 2.5). MTP1 works fine, flashcomm OFF works fine.

**Root cause** (3 issues identified):

1. `torch.ops.vllm.maybe_pad_and_reduce` does all_reduce+scatter, causing 4x norm inflation. FIXED by replacing with `split_inputs_tp_to_sp` in `llm_base_proposer.py:maybe_pad_and_reduce`.

2. Stale buffer positions `[batch_size:input_batch_size]` contain target_hidden_states from main model, corrupting GLM-5 MTP eh_proj. FIXED by zeroing those positions before loop model forward.

3. After `maybe_all_gather_and_unpad`, all TP ranks have identical data. `token_indices_to_sample` selects the same global index on every rank. `[:batch_size]` compact write concentrates all decode data on rank 0 after DSA-CP partition. NOT FIXED — requires rank-specific data distribution without per-element sync.

**Key reference**: DSv4 DSA-CP works because it has `build_for_drafting` (commit 2370040f) with proper per-rank token partitioning via `_build_local_token_metadata`. SFA `build_for_drafting` implemented but only differs in use_cache=False — doesn't solve the core data-flow issue.

**Backend routing**: GLM-5 uses SFA `(True, True, False)`, DSv4 uses DSA `(True, False, True)`. SFA activates DSA-CP via `enable_dsa_cp() = is_ds_v32 and enable_sp()`. The SFA builder has `build_for_drafting` now but needs per-rank partition logic like DSA-CP has.

**Key files**: `llm_base_proposer.py` (proposer), `sfa_v1.py` (SFA backend), `ascend_forward_context.py` (flashcomm control), `patch_deepseek_mtp.py` (GLM-5 MTP patch), `deepseek_v4.py` (DSv4 reference for _mtp_hidden_buffer pattern).

**Current baseline**: Mean acceptance length 1.4-1.8 with two fixes applied. Target 2.5 not reached.
