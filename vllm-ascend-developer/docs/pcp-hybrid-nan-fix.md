# PCP Hybrid Model NaN Bug 调试经验

## 问题

Hybrid 模型（Qwen3.5-MoE）启用 PCP 时，prefill 阶段 full_attention 层产生 NaN。

## 根因

**`tensor[mask].fill_(0)` 不会写回原始 tensor。** PyTorch 基础语义问题，与硬件无关：

```python
# PyTorch 索引返回值规则:
t[a:b]              → view  (共享存储)
t[bool_mask]        → copy  (副本)
t[int_indices]      → copy  (副本)
```

`tensor[mask].fill_(0)` 过程：
1. `tensor[mask]` → `__getitem__`，返回**副本**
2. `.fill_(0)` → 填的是副本，原始 tensor 不受影响

而 `tensor[mask] = 0` 走 `__setitem__`，PyTorch 内部用 scatter 直接写回原始 tensor。

## Bug 代码

`vllm_ascend/attention/context_parallel/attention_cp.py` `_gather_and_restore_pcp_qkv`:

```python
# ✅ 填数据 — __setitem__
workspace[decode_offset:][pcp_unpad_mask] = actual_qkv[decode_offset:]

# ❌ 填零 — __getitem__ + fill_()，fill 到副本上了！
workspace[decode_offset:][~pcp_unpad_mask].fill_(0)
```

workspace 的 padding 位没有被清零，残留了未初始化内存。
DualChunkSwap 的 tail attention KV 索引覆盖了 padding 位 → NaN。

## 修复

```python
# 用切片 fill_（切片返回 view，fill_ 正确写回）
workspace[decode_offset:][pcp_unpad_mask] = actual_qkv[decode_offset:]
num_real_prefill = actual_qkv.shape[0] - decode_offset
workspace[decode_offset + num_real_prefill:].fill_(0)
```

## 调试方法

### 对比验证法

同时运行新旧两种写法，分配独立 workspace，计算 diff：

```python
workspace_new = empty(N)
workspace_new[:n] = data
workspace_new[n:].fill_(0)

workspace_old = empty(N)
workspace_old[:][mask] = data
workspace_old[:][~mask].fill_(0)

diff = (workspace_new - workspace_old).abs()
print(f"diff_indices = {diff.nonzero().tolist()}")
# → [2385, 2386, 2387]  仅 padding 位有差异 → 锁定 fill_ 问题
```

### 从 diff 位置反推

差异仅在 padding 位 → 数据赋值没问题，问题在 padding 填零 →
padding 填零仅一行 `workspace[~mask].fill_(0)` → 想起 PyTorch bool indexing 返回 copy → 确认根因。

### 最小 demo 验证

```python
t = torch.tensor([1.0, 2.0, 3.0, 4.0, 5.0])
mask = torch.tensor([True, True, True, False, False])
t[mask].fill_(0)   # t 没变！
t[mask] = 0        # t 变了！
```

## 经验规则

```python
# ✗ 错误: 索引 + in-place 方法
tensor[mask].fill_(0)
tensor[indices].copy_(other)

# ✓ 正确: 用赋值（__setitem__）
tensor[mask] = 0
tensor[indices] = other

# ✓ 正确: 用切片（返回 view）
tensor[a:b].fill_(0)
```

**只有切片返回 view，bool mask 和 int index 都返回 copy。**
