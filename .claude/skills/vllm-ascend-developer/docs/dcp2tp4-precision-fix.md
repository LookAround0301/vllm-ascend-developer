# DCP2TP4 精度 Bug 调试经验

## 问题

Qwen3.5-35B-A3B（MoE hybrid 模型），DCP2TP4 推理输出 `<think>` token 泄漏，
DCP1TP4（纯 TP）正常。temperature=0 下可稳定复现。

```
DCP1TP4:  " porch of Tara, your father%27s"        ✅
DCP2TP4:  " porch of Tara,\n\n<think>\n\nThinking Process:"  ❌
```

## 调试方法论（通用可复用）

### 1. 先排除明显错误

- [ ] **KV cache 存储** — 打印 `slot_mapping` 和 block_table 实际写入的 KV 值，两边对比确认存储位置正确
- [ ] **NaN/Inf** — 每层输出查 `isnan/isinf`，排除数值爆炸
- [ ] **Prompt 一致性** — 用 `generate_curl.py` 确保两个配置用的 prompt 完全相同

### 2. 逐层 comparison 定位

在关键路径（每层 attention 输出）加 hash/sum 打印：

```python
_out_sum = attn_out[0].float().sum().item()
print(f"[DEBUG-CMP-FINAL] dcp={self.dcp_rank} layer={layer} out_sum={_out_sum:.6f}")
```

两个配置（interleave=1 vs 1024）分别跑测试，保存日志到 `service_A.log` / `service_B.log`，
逐层对比 `out_sum`：

| 差异模式 | 指向 |
|---------|------|
| 第一层就 >1% | KV cache 或 prefill 问题 |
| 差异随层递增 | attention merge 精度不足 |
| 有时对有时错 | 数值非确定性（精度/race） |

### 3. 参考实现对拍

怀疑某个 kernel 精度时，用纯 PyTorch 等价实现替代，快速验证假设：

```python
# 示例：替代 npu_attention_update
ref_out = (out_stacked * weights.unsqueeze(-1)).sum(dim=0) / weight_sum.unsqueeze(-1)
diff = (npu_out - ref_out).abs()
```

### 4. 二分缩小范围

- 先确认 slot_mapping/KV 存储无问题 → 再检查 attention → 再检查 merge
- 每次只改一个变量，对比前后差异

## 根因

`torch_npu.npu_attention_update` NPU kernel 的 float32 精度不足以处理
DCP attention merge 中的 log-sum-exp 运算。

flash attention 的 tiling 优化导致不同 KV 分区产生不同精度的 LSE 近似值，
NPU kernel 无法正确合并这些近似值，误差逐 attention 层放大。

## 修复

`vllm_ascend/attention/context_parallel/common_cp.py` 的 `_npu_attention_update`：

```python
# NPU kernel → PyTorch float64 stable log-sum-exp
out_flat = out_flat.flatten(1, 2).to(torch.float64)
lse_flat = lse_flat.flatten(1, -1).to(torch.float64)
# ... lse_max in float64, exp in float32, weighted average
```

核心：LSE 升到 float64 存储，避免大值差下的精度丢失。

## 踩坑记录

| 坑 | 解决 |
|---|------|
| curl 手动拼命令 prompt 不一致 | 用 `generate_curl.py` 从 test.yaml 生成 |
| curl 返回 504 | `unset http_proxy; unset https_proxy` |
| health check 用 localhost 连不上 | 服务 `--host` 绑定了外部 IP，curl 用实际 IP |
| 杀进程 awk 转义失败 | `fuser -k {port}/tcp` 按端口杀 |
| 两个配置日志互相覆盖 | 启动时分别指定 `service_A.log` / `service_B.log` |
