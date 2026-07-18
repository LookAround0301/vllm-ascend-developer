# FlashComm + MTP 调试指南

## 问题背景

GLM-5 (GLM4-MoE-MTP) 在开启 flashcomm (`VLLM_ASCEND_ENABLE_FLASHCOMM1=1`) 时，MTP3 采信率异常低（Mean ~1.3-1.8，目标 >= 2.5）。MTP1 正常（~56%），flashcomm OFF 时 MTP3 正常。

## 涉及的架构组件

| 组件 | 路径 | 角色 |
|------|------|------|
| MTP Proposer | `vllm_ascend/spec_decode/llm_base_proposer.py` | MTP draft token生成主逻辑 |
| SFA Backend | `vllm_ascend/attention/sfa_v1.py` | GLM-5 attention后端（`ASCEND_SFA`） |
| DSA-CP Backend | `vllm_ascend/attention/context_parallel/dsa_cp.py` | DSv4 CP后端（参考实现） |
| MTP Patch | `vllm_ascend/patch/worker/patch_deepseek_mtp.py` | GLM-5 MTP层patch |
| Forward Context | `vllm_ascend/ascend_forward_context.py` | flashcomm参数控制 |
| Backend Map | `vllm_ascend/platform.py:616` | `(use_mla=True, sparse=True, compress=False) -> SFA` |

## GLM-5 MTP + FlashComm 数据流

```
Step 1 (first merged draft):
  主模型输出 → all_gather → target_hidden_states
  → set_inputs_first_pass: self.hidden_states[:num_tokens] = target_hidden_states
  → maybe_pad_and_reduce: scatter by TP rank
  → 模型前向 (flashcomm reduce_scatter + DSA-CP attention)
  → maybe_all_gather_and_unpad: all_gather → full [num_input_tokens, hidden_dim]

Step 1 → Loop 过渡 (问题所在):
  hidden_states[token_indices_to_sample]  ← 所有rank选相同index
  → 所有rank拿到rank-1的输出
  → self.hidden_states[:batch_size] = rank1的输出 (写到position 0)

Step 2 (loop):
  model_hidden_states = self.hidden_states[:input_batch_size]
  → [rank1_hs, stale, stale, stale]
  → maybe_pad_and_reduce scatter → rank0得到rank1_hs
  → 模型前向 → 基于rank1数据 → 退化输出
```

## 已识别并修复的问题

### 问题1: maybe_pad_and_reduce all_reduce放大 (已修复)
`torch.ops.vllm.maybe_pad_and_reduce` 在scatter前做all_reduce求和，TP=4时norm放大4倍。
**修复**: 替换为 `split_inputs_tp_to_sp`（纯切片，无all_reduce）。
**位置**: `llm_base_proposer.py:maybe_pad_and_reduce`

### 问题2: Stale buffer位置污染eh_proj (已修复)
Loop中 `[batch_size:input_batch_size]` 包含过期target_hidden_states。
**修复**: 在loop buffer写入前清零这些位置。
**位置**: `llm_base_proposer.py:_run_merged_draft`

### 问题3: Gather后rank数据身份丢失 (未修复)
`maybe_all_gather_and_unpad` 后所有TP rank拥有相同数据，
`token_indices_to_sample` 在所有rank上选取相同全局索引，
`[:batch_size]` 压缩写入导致所有decode数据集中到rank 0。

**根因**: `attn_update_stack_num_spec_norm` 将 `query_start_loc` 压缩为 `[0,1,...,batch_size]`，
DSA-CP partition将所有token分配给rank 0。

## 关键参考Commit

- **fac8784c**: DSA context parallel for DSv4 — 引入 DSACPMetadataBuilder
- **2370040f**: MTP support for DSA_CP — 为DSA-CP添加 `build_for_drafting`（test结果 Mean 2.89-2.92）

## DSA-CP vs SFA 的build_for_drafting对比

| 维度 | DSv4 (DSA-CP) | GLM-5 (SFA) |
|------|---------------|-------------|
| `build_for_drafting` | ✅ 已实现 | ✅ 已实现（本session） |
| 行为差异 | 有 `spec_slot_mapping` 预分配 + `_build_local_token_metadata` | 仅 `use_cache=False` |
| 路由 | `self.use_compress=True` | `self.method=="mtp" and _EXTRA_CTX.flash_comm_v1_enabled` |

## 尝试过但失败的方案

| 方案 | 失败原因 |
|------|----------|
| 禁用MTP loop中的maybe_pad_and_reduce | eh_proj的torch.cat形状不匹配 |
| pre-gather scattered hidden_states替换 | 形状不匹配（prefill token数≠batch_size） |
| indexed buffer写入 (_orig_dpos) | .item()循环导致性能崩溃 |
| scatter_写入 | 采信率不变 |
| 完整gathered hs填充所有位置 | 覆盖bonus位置，更差 |
| 禁用DSA-CP for SpecDecoding | 编译挂起 |
| 禁用flashcomm for MoE draft | 推理500错误 |

## 当前修复状态

**文件**: `llm_base_proposer.py`
- Line ~1892: `split_inputs_tp_to_sp` 替换 `maybe_pad_and_reduce` (已应用)
- Line ~1034: 清零stale位置 (已应用)
- Line ~1500: `build_for_drafting` 路由 for MTP+flashcomm (已应用，safe)

**文件**: `sfa_v1.py`
- `build_for_drafting()` 方法 (已实现，use_cache=False，已被路由调用)

**采信率基线**: Mean ~1.4-1.8 (目标 2.5 未达成)
