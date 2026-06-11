# log-analyzer.md — 日志分析器模块

## 概述

分析服务日志和测试日志，提取关键错误和警告，分类定位到可疑代码区域。

## 使用方式

```
验证不通过后，调用此模块分析日志。
```

## 前置条件

- 服务日志文件（`service.yaml` 中配置的 `log_file`）
- 测试输出日志文件（`test.yaml` 中配置的 `output_log`）
- vllm-ascend 源码路径（`model.yaml` 中配置的 `vllm_ascend_source`）
- Ascend plog 日志路径（`/root/ascend/log/debug/plog/`）

---

## 分析步骤

### 步骤 1：读取服务日志中的异常

```bash
# 查看服务日志尾部
python scripts/ssh_utils.py exec standalone "docker exec {docker.name} tail -n 50 {docker.log_file}"

# 搜索错误关键词
python scripts/ssh_utils.py exec standalone "docker exec {docker.name} grep -n -i 'error\|warn\|fail\|traceback\|nan\|inf\|overflow' {docker.log_file}"
```

### 步骤 2：读取测试日志中的异常

```bash
# 查看测试输出
cat {output_log}
```

### 步骤 3：错误分类

根据日志内容将问题归类到以下已知模式：

| 错误类别 | 关键词 | 常见原因 | 可疑代码区域 |
|---------|--------|---------|-------------|
| 数据类型转换 | "cast", "dtype", "precision", "FP16", "BF16" | FP32↔FP16 转换精度丢失 | 自定义算子、数据预处理 |
| 量化精度 | "quantize", "dequantize", "scale", "zero_point" | 量化/反量化精度损失 | 量化算子实现 |
| Attention 溢出 | "softmax", "attention", "NaN", "inf" | Softmax 数值不稳定 | Attention 内核实现 |
| 内存错误 | "memory", "alignment", "out of bounds" | 内存越界、对齐问题 | 显存分配、算子入参 |
| 算子融合 | "fuse", "merged", "combined" | 算子融合导致的精度偏差 | 融合算子实现 |
| 数值溢出 | "overflow", "inf", "NaN" | 中间结果超出数值范围 | 任意计算步骤 |

### 步骤 4：分析 Ascend plog 日志

服务日志无明显报错、但推理结果异常时，也可以看 plog。Ascend NPU 的 plog 日志包含硬件/算子层的详细调试信息，有时能捕获到服务日志中未体现的数值异常。

```bash
# 查看 plog 目录
python scripts/ssh_utils.py exec standalone "docker exec {docker.name} ls /root/ascend/log/debug/plog/"

# 搜索 plog 关键错误
python scripts/ssh_utils.py exec standalone "docker exec {docker.name} grep -n -i 'error\|fail\|exception\|oom\|overflow' /root/ascend/log/debug/plog/*.log 2>/dev/null | head -30"

# 查看最新 plog 文件
python scripts/ssh_utils.py exec standalone "docker exec {docker.name} bash -c 'tail -n 100 /root/ascend/log/debug/plog/\$(ls -t /root/ascend/log/debug/plog/ | head -1)'" 2>/dev/null
```

注意：每次重启服务前应清空 plog（`rm -rf /root/ascend/log/debug/plog/*`），确保 plog 内容对应最新的运行过程。

### 步骤 5：定位可疑代码

```bash
# 在 vllm-ascend 源码中搜索错误涉及的函数/模块
grep -rn "suspected_function_name" {vllm_ascend_source} --include="*.py" | head -20

# 查看 vllm-ascend 源码结构
ls {vllm_ascend_source}/vllm/plugin/

# 查看 vllm-ascend 的算子实现目录
find {vllm_ascend_source} -type f -name "*.py" | head -20
```

### 步骤 6：分析 vllm 对应实现作为参考

```bash
# 在 vLLM 中查找对应功能的参考实现
grep -rn "suspected_function_name" {vllm_source} --include="*.py" | head -20
```

---

### 步骤 7：精度问题专项排查

> 完整案例见 `docs/dcp2tp4-precision-fix.md`。

对于**没有显式报错但输出结果不对**的精度问题，需要逐层对比 attention 输出。在关键路径加 `DEBUG-CMP-FINAL` 打印后：

```bash
# 抓取逐层 out_sum（两个配置分别跑，保存到不同 log）
python scripts/ssh_utils.py exec standalone "docker exec {docker.name} grep 'DEBUG-CMP-FINAL' {log}" > layer_output.log

# 对比第一处显著差异（>1% 即异常，远超 float32 精度 1e-6）
# 第一层就出差异 → KV cache 或 prefill 问题
# 差异逐层放大 → attention merge 精度不足
```

> **经验**：本次 DCP2TP4 bug 中，第一层 out_sum 差异 8%，最终根因是 `npu_attention_update` float32 精度不足，改为 float64 后修复。

---

## 分析输出

```
=== 日志分析结果 ===
错误类别: 数据类型转换
置信度: 高
关键错误: "RuntimeError: Expected tensor type Float but got Half"
可疑文件: /vllm-workspace/vllm-ascend-deepseekv4/vllm/plugin/custom_ops.py:245
相关函数: attention_forward
建议: 检查算子输入是否需要 FP32 精度，添加 cast 操作
=====================
```
