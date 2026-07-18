---
name: graph-mode-prefetch-investigation
description: "Graph-mode hash-layer expert prefetch — 5 failed approaches, the fundamental D2H-in-host-fn wall, and why Pattern A (acl_graph replay hook) is the only viable path."
metadata: 
  node_type: memory
  type: project
  originSessionId: dab01221-9e76-4ee5-ac7f-73d7a9e4765d
---

Investigation of making expert prefetch work in **ACL graph mode** (`FULL_DECODE_ONLY`). As of 2026/06/15.

## Background

DeepSeek V4's first `num_hash_layers=3` MoE layers are **hash-MoE**: expert selection is
`tid2eid[input_ids]` (token-id determined, not hidden-state dependent). The **prediction fix**
(`predict_next_layer_experts` hash branch using tid2eid instead of gate-softmax) is done and
**verified in eager mode** (layers 1/2 prefetch exactly, 100% hit). But making the prefetch
**land in graph mode** failed across 5 approaches.

## The fundamental wall

ACL graph host-fns (launched via `_launch_host_func`) run on the graph runtime's callback thread
and are **serialized with the stream's task queue**. This means:

1. **No D2H/sync in host-fns** — `tensor.cpu()`, `event.synchronize()`, etc. block the callback
   thread, which blocks the stream, which prevents the NPU from processing the op → **deadlock**.
2. **No forward context** — `get_forward_context()` returns None on the callback thread (the
   vllm `_forward_context` global is set by the main thread, and isn't reliably visible/valid
   on the callback thread during replay).
3. **No daemon-thread wait** — a host-fn that blocks on a daemon thread's async H2D deadlocks
   (the daemon can't submit its ops while the callback thread holds the runtime).

But `_do_prefetch` **inherently needs D2H**: it reads `next_layer.log2phy.cpu()` to determine
current residency, decide misses, and choose victims. This D2H can't run in a host-fn → the
prefetch logic can't be a host-fn.

## The 5 failed approaches

1. **Eager wait as host-fn** (`_wait_prefetch` with `npu_event.synchronize()`) → deadlock
   (host-fn blocks graph runtime thread on daemon's async H2D).
2. **ExternalEvent wait host-fn** (`ev.wait(stream); ev.reset(stream)`) → hung (the issue
   host-fn that records the event never ran, because it wasn't registered during capture —
   the registration condition checked `_hash_prefetch_event` which was empty at capture time).
3. **Fixed: unconditional registration** + **KeyError guard** + **try/except diagnostic** →
   no hang, but `[PREFETCH-ISSUE] predict raised: AssertionError('Forward context is not set')`
   — `get_forward_context()` is None on the ACL callback thread.
4. **Fixed: stash `_decode_input_ids`** (model_runner sets it before `_model_forward`) →
   AssertionError gone, but issue host-fn still hangs after `enter` log — at `input_ids.cpu()`
   (D2H) inside `predict_next_layer_experts`. **D2H in host-fn deadlocks.**
5. **Fixed: stash `input_ids.cpu()`** (do D2H on main thread) → input_ids D2H solved, but
   `_do_prefetch` itself does `next_layer.log2phy.cpu()` (another D2H) → **same deadlock**.
   This is the fundamental wall: `_do_prefetch` needs D2H, host-fns can't do D2H.

## Current code state (uncommitted, in `expert_offload_manager.py` + `model_runner_v1.py`)

- **Eager predict fix**: `predict_next_layer_experts` hash branch (tid2eid lookup) — WORKS.
- **Graph-mode host-fn path** (`_prefetch_issue_host`, `_prefetch_wait_host`,
  `_hash_prefetch_event`, trigger graph path, update_weights graph wait) — DOESN'T WORK (D2H
  deadlock). Should be **reverted**.
- **model_runner stash** (`_decode_input_ids = input_ids.cpu()`) — added for the host-fn path,
  should be reverted with the rest.
- **tid2eid storage** (`_gate_tid2eid_cpu`, `num_hash_layers`, `register_gate_weights` capture)
  — KEEP (needed for the predict fix).

## Approach 6 (IMPLEMENTED + VERIFIED WORKING on NPU, 2026/06/15): CPU mirror + stream-sync wait

Re-examined the failures and found the **only real deadlock point was a single
D2H**: `_do_prefetch`'s `next_layer.log2phy.cpu()` (the `input_ids.cpu()` in
predict was already a no-op — `_decode_input_ids` is stashed as a CPU tensor).
The ExternalEvent mechanism was never cleanly tested because every run hit a
D2H first. Two changes kill the wall without Pattern A:

1. **CPU residency mirror** `self._log2phy_cpu_mirror` (int32 numpy, one per
   layer). Synced from device once in `_finalize_offload` (main thread, D2H
   safe). Maintained thereafter by `_update_weights` (writes after its copy
   loop) and `_do_prefetch` (writes before device write-back). `_do_prefetch`
   reads it instead of `next_layer.log2phy.cpu()` → **zero D2H in the host-fn**.

2. **Wait host-fn = `_prefetch_stream.synchronize()`** (dropped the unproven
   ExternalEvent wait/reset). This is the SAME proven pattern as
   `_update_weights.load_stream.synchronize()`: the H2D is **self-issued** on
   `_prefetch_stream` by the issue host-fn (not daemon-thread-issued, which was
   approach 1's deadlock), so `_prefetch_stream` drains independently of the
   compute stream's task queue and syncing it from a host-fn does not deadlock.

Also: `_do_prefetch(host_fn=True)` skips the `time.sleep` (would hold the
compute task queue) and skips the unused completion-event creation. Wait
condition guarded to `0 < layer_idx < num_hash_layers` (layer 0 has no
prefetcher). `trigger` graph path + `update_weights` graph wait branch +
model_runner `_decode_input_ids` stash all retained.

**Key insight**: the rule is "in a host-fn, sync a stream only if all its
pending ops were self-issued within host-fns." `_update_weights` already proved
this (self-issued load_stream + sync). The prefetch now does the same on
`_prefetch_stream`.

**VERIFIED 2026/06/15**: graph mode (`Replaying aclgraph`) shows `[PREFETCH-ISSUE]`→
`[PREFETCH-WAIT] done` (no deadlock), and `[UPDATE-W] l=1`/`l=2` = `expert_miss=[]`
`hit_rate=1.00` with predicted ids exactly matching hit ids. Sustained across
multiple decode steps. The self-issued `_prefetch_stream.synchronize()` theory
is CONFIRMED — same safe pattern as `load_stream.synchronize()`. l=0 stays
cold (no prefetcher) and gate layers l=3+ ride the LRC cache (unchanged).

**Remaining (optional)**: l=0 cold-start each step (could pre-replay-prefetch
via an acl_graph/model_runner hook); measure decode-latency benefit (debug off);
confirm output sanity.

## Pattern A (acl_graph replay hook) — fallback if approach 6's sync hangs

Mirror the attention path (`vllm_ascend/attention/attention_v1.py:764-825` capture,
`update_graph_params` replay; `compilation/acl_graph.py:295-327` GraphParams):
- Drive the prefetch from a **replay hook in `acl_graph.py`** (runs on the **main thread**
  between replays, where D2H/H2D is safe).
- Capture `ExternalEvent.wait/reset` **once** at capture time (in trigger).
- Record the event from the replay hook each step (after the prefetch H2D on `_prefetch_stream`).
- The captured wait gates the compute stream (non-blocking, no deadlock).

This is a significant restructure (new replay hook, capture/replay split), not an incremental fix.

## Key files

- `vllm_ascend/expert_offload/expert_offload_manager.py` — all prefetch logic.
- `vllm_ascend/worker/model_runner_v1.py:~2243` — input_ids stash (before `_model_forward`).
- `vllm_ascend/compilation/acl_graph.py` — where Pattern A's replay hook would go.
- `vllm_ascend/attention/attention_v1.py:764-825,401-543` — Pattern A reference.

## Gate-layer graph prefetch (approach 7, IMPLEMENTED + VERIFIED 2026/06/15)

Extended graph-mode prefetch from hash layers to **gate layers** (l=3..42).
Gate routing depends on `hidden_states` (device, the just-run GMM's input), so
unlike hash (input_ids, CPU stash) the prediction needs hs → can't `.cpu()` in
a host-fn (deadlock).

**PERF REFINEMENT (2026/06/15, important):** the first version did the gate
matmul on CPU inside the issue host-fn (full hs D2H + single-threaded
`F.linear`), which blocked the compute stream ~ms/gate-layer × ~39 layers and
**badly regressed graph-mode latency** (hit rate 0.78 but perf worse than
reactive). Fixed by running the gate matmul **ON DEVICE** on _prefetch_stream
using the **model's own `wrapper.gate.weight`** (zero extra memory), D2H-ing
only the tiny topk_ids `[n,topk]`. Per-layer compute-stream stall dropped from
~ms to ~µs; the expert H2D (issued after by `_do_prefetch`) still overlaps the
next attention. Removed the now-unneeded `_gate_predict_hs_dev/_pinned` hs
buffers; added `_gate_weights_dev` (device gate refs) + tiny
`_gate_topk_ids_pinned`. PENDING re-test of latency.

Mechanism (`_predict_gate_from_hs`, called from the issue host-fn):
1. **trigger** (plain host code, but its stream op is captured → replays): after
   GMM L, `stream.record_event(hs_event)` on compute. MUST use an event, NOT
   `wait_stream(compute)` from the host-fn — wait_stream would wait for the
   host-fn itself to return → circular deadlock.
2. **issue host-fn**: `_prefetch_stream.wait_event(hs_event)` (fired at GMM L,
   non-circular) → `with stream(_prefetch_stream): F.linear(hs, gate_w_dev)` +
   softmax + topk (device) → `pin_buf.copy_(topk_ids, non_blocking=True)` (tiny
   D2H) → `_prefetch_stream.synchronize()` (waits for fast device ops) → paging.
3. `_do_prefetch(host_fn=True)` (H2D async + mirror) → wait host-fn syncs.
hidden_states passed as the host-fn arg (tensor-reuse under graph replay).

**VERIFIED (hit rate)**: gate layers l=3..42 jumped **0.55 → 0.78** (eager
0.85). hash l=1/l=2 stayed 1.00. tensor-reuse + plain-Event cross-stream dep
both held up. Also fixed: LRC cache now gets `router_scores` in graph mode
(`update_weights` topk_weights async D2H, was skipped under capture) — closes
part of the gap to eager. Remaining gap to eager (~0.07) is now likely sampling
+ bf16-vs-fp32 gate-matmul prediction differences, not a fixable bug.

## Recommendation (as of 2026/06/15)

hash + gate graph-mode prefetch implemented. gate prediction is device-side
(fast). Next: re-measure graph-mode decode latency (the perf regression should
be gone); confirm gate hit rate holds (~0.78) and output sanity; then commit.
See [[weight-load-optimization]] and [[measure-before-optimize]].
