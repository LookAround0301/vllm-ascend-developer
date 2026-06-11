# aisbench-evaluator.md — 精度数据集评测模块

## 概述

使用 aisbench 对 vLLM 推理服务进行精度数据集评测。aisbench 跑在**专用评测机器**上，向**推理机器**上的 vLLM 服务发送请求，评测模型在 GSM8K、GPQA 等数据集上的精度指标，并分析模型输出质量。

## 整体架构

```
┌─────────────────────┐      HTTP请求       ┌──────────────────────┐
│  评测机器 (aisbench) │ ──────────────────→ │  推理机器 (vLLM 服务) │
│  ais_bench 命令      │ ←────────────────── │  host_ip:host_port   │
│  修改配置文件指向     │    推理响应         │  模型: model_name    │
│  推理机器的 IP+端口   │                     │                      │
└───────┬─────────────┘                      └──────────────────────┘
        │
        ▼
┌──────────────────────────────────────────────────┐
│  评测输出文件                                      │
│  /home/outputs/default/{timestamp}/               │
│    ├── summary/summary_{timestamp}.txt   ← 精度得分  │
│    └── results/vllm-api-general-chat/    ← 模型输出  │
└──────────────────────────────────────────────────┘
```

## 关键约束

### 1. 服务必须在健康检查通过后执行
在执行 aisbench 评测之前，**必须**确保 vLLM 推理服务已完全就绪：
1. 服务日志中包含所有 `success_keywords`（`Application startup complete.` / `Started server process`）
2. 通过健康检查：`curl -s -o /dev/null -w "%{http_code}" http://{service.host_ip}:{service.host_port}/v1/models` 返回 `200`
3. 严禁在服务未就绪时发起 aisbench 评测

### 2. 评测机器远程操作
评测机器的所有命令通过 `scripts/ssh_utils.py` 的 `eval` 节点执行。首次调用自动建立持久连接，后续复用。

```bash
# 执行命令示例
python scripts/ssh_utils.py exec eval "docker exec {eval_machine.docker.name} ..."
```

## 前置条件

- [x] **vLLM 推理服务已成功启动并通过健康检查**（严格前提）
- 评测机器已安装 aisbench（`ais_bench` 命令可用）
- 数据集已准备就绪（无需额外配置）
- 已正确填写 `config/aisbench.yaml`

---

## 执行步骤

### 步骤 1：读取启动脚本中的服务配置

读取推理机器的服务启动脚本（如 `signel_vllm.sh` 或 `test.sh`），获取以下参数，用于填充 aisbench 配置文件：

- `--model` 或 `--model-path` → aisbench 配置中的 `path`
- `--served-model-name` → `model`
- `--port` → `host_port`

这些参数需要在启动服务时就已经确认，并填入 `config/aisbench.yaml`。


### 步骤 2：【前置检查】确认服务健康

在执行 aisbench 前，必须确认推理服务已完全就绪：

```bash
# === 检查服务是否健康（从本机或跳板机发起） ===
# 必须返回 HTTP 200，否则等待后重试
curl -s -o /dev/null -w "%{http_code}" http://{service.host_ip}:{service.host_port}/v1/models

# === 或者通过评测机器检查 ===
python scripts/ssh_utils.py exec eval "curl -s -o /dev/null -w '%{http_code}' http://{service.host_ip}:{service.host_port}/v1/models"
```

- 返回 `200` → 服务就绪，继续执行步骤 4
- 返回非 `200` → **严禁执行 aisbench**，返回 service.md 检查服务状态并等待

### 步骤 3：执行精度评测

评测耗时较长，使用后台执行 + wait 轮询模式，避免连接超时：

```bash
# 1. 后台启动评测，输出写入日志
python scripts/ssh_utils.py exec eval "docker exec {eval_machine.docker.name} bash -c 'cd {eval_machine.docker.work_dir} && nohup python3 aisbench_test.py --input_len {benchmark.input_len} --output_len {benchmark.output_len} --data_num {benchmark.data_num} --concurrency {benchmark.concurrency} --test_type {benchmark.test_type} --npu_num {benchmark.npu_num} > aisbench_output.log 2>&1 &' && echo started"

# 2. 等待评测完成
python scripts/ssh_utils.py wait eval "{eval_machine.docker.work_dir}/aisbench_output.log" "全量数据集测试完成" --timeout 7200

# 3. 查看结果
python scripts/ssh_utils.py exec eval "docker exec {eval_machine.docker.name} tail -n 80 {eval_machine.docker.work_dir}/aisbench_output.log"
```

如需评测特定数据集，直接调用 ais_bench：
```bash
python scripts/ssh_utils.py exec eval "docker exec {eval_machine.docker.name} bash -c 'cd {eval_machine.docker.work_dir} && ais_bench --models vllm_api_general_chat --datasets gsm8k_gen_0_shot_cot_chat_prompt --dump-eval-details --debug 2>&1 | tee aisbench_output.log'"
```

### 步骤 4：解析评测结果（提取 accuracy）

aisbench 的输出包含类似以下格式的精度结果：

```
05/06 03:15:26 - AISBench - INFO - Task [vllm-api-general-chat/GPQA_diamond]: {'accuracy': 83.83838383838383, 'type': 'GEN'}
05/06 03:15:27 - AISBench - INFO - write summary to /home/outputs/default/20260506_015425/summary/summary_20260506_015425.txt
```

```bash
# 提取 accuracy 值
python scripts/ssh_utils.py exec eval "docker exec {eval_machine.docker.name} bash -c \"grep -oP 'accuracy.*?GEN' aisbench_output.log | head -1\""
# 输出示例：'accuracy': 83.83838383838383, 'type': 'GEN'

# 提取 summary 文件路径（用于定位模型输出目录）
python scripts/ssh_utils.py exec eval "docker exec {eval_machine.docker.name} bash -c \"grep 'write summary to' aisbench_output.log | grep -oP '/home/outputs/default/[^ ]+'\""
# 输出示例：/home/outputs/default/20260506_015425/summary/summary_20260506_015425.txt
```

准确性判断：

| accuracy 表现 | 判断 |
|---------------|------|
| 达到预期值 | 精度基本正常 |
| 明显偏低 | 精度异常，需进入修复流程 |

### 步骤 5：分析模型输出文件

aisbench 会将每条测试样本的模型输出保存到：
`/home/outputs/default/{timestamp}/results/vllm-api-general-chat/`

该目录下包含每个测试样本的输出文件，需要分析是否存在**乱码**或**复读**问题。

```bash
# 查看输出目录结构
python scripts/ssh_utils.py exec eval "docker exec {eval_machine.docker.name} bash -c 'ls /home/outputs/default/*/results/vllm-api-general-chat/ 2>/dev/null | head -20'"

# 抽样查看前几个输出文件
python scripts/ssh_utils.py exec eval "docker exec {eval_machine.docker.name} bash -c 'head -100 /home/outputs/default/*/results/vllm-api-general-chat/*.json 2>/dev/null | head -200'"
```

#### 乱码检查

```bash
python scripts/ssh_utils.py exec eval "docker exec {eval_machine.docker.name} bash -c '
    OUTPUT_DIR=/home/outputs/default/*/results/vllm-api-general-chat/
    grep -l \"��\\|�\\|\\\\x[0-9a-f][0-9a-f]\\|\\\\u[0-9a-f][0-9a-f][0-9a-f][0-9a-f]\" \${OUTPUT_DIR}*.json 2>/dev/null || echo \"no gibberish found\"
  '"
```

#### 复读检查

```bash
python scripts/ssh_utils.py exec eval "docker exec {eval_machine.docker.name} bash -c '
    OUTPUT_DIR=/home/outputs/default/*/results/vllm-api-general-chat/
    for f in \${OUTPUT_DIR}*.json; do
        content=\$(python3 -c \"import json; d=json.load(open(\\\"\$f\\\")); print(d.get(\\\"pred\\\", d.get(\\\"output\\\", \\\"\\\")))\" 2>/dev/null)
        echo \"\$content\" | grep -oP \"(.{5,}).*\\\1.*\\\1.*\\\1\" && echo \"REPETITION FOUND in \$f\"
    done 2>/dev/null || echo \"no repetition check performed\"
  '"
```

> 提示：也可以通过人工抽样阅读几个典型输出来判断，效率更高。

### 步骤 7：综合判断与修复迭代

| 条件 | 结论 | 后续动作 |
|------|------|----------|
| accuracy 达标 + 输出无乱码/复读 | ✅ 精度评测通过 | 修复完成 |
| accuracy 达标 + 有乱码/复读 | ⚠️ 输出质量问题 | 进入 log-analyzer 定位，修复后重测 |
| accuracy 偏低 | ❌ 精度异常 | 进入修复循环 |

**修复迭代流程**（完整闭环）：

```
修复代码 → 重启服务 → 监控启动日志 → 健康检查通过 → 重新评测
                                                        ↓ 失败
                   ←──────────── 回到修复代码 ────────────
```

1. 记录本次评测结果到 `fix_N.md`（accuracy、数据集名、问题类型）
2. 调用 **log-analyzer.md** 分析服务/模型输出日志
3. 调用 **auto-fixer.md** 修复 vllm-ascend 代码
4. 调用 **service.md** 停止并重启服务
5. **等待服务就绪**：
   - 检查日志是否包含 `Application startup complete.` / `Started server process`
   - 执行健康检查：`curl http://{service.host_ip}:{service.host_port}/v1/models` 返回 `200`
   - **健康检查不通过 → 回到步骤 2 分析启动失败原因**
6. **回到步骤 3（前置健康检查）确认服务持续健康**
7. 确认通过后，回到步骤 4 重新执行评测

---

## 常用数据集清单

| 数据集名 | 说明 |
|----------|------|
| `gsm8k_gen_0_shot_cot_chat_prompt` | GSM8K 数学推理（0-shot CoT） |
| `gpqa_gen_0_shot_cot_chat_prompt` | GPQA 科学问答（0-shot CoT） |

---

## 注意事项

1. **两台机器分离**：aisbench 在评测机器上执行，向推理机器的 vLLM 服务发请求
2. **配置文件覆盖**：每次评测前修改 aisbench 配置文件，指向正确的推理服务
3. **数据集无需配置**：已预先准备
4. **评测耗时**：数据集评测可能需要较长时间，请耐心等待
5. **输出目录**：每次评测生成新的 timestamp 目录，注意区分不同轮次的结果
