# precision-diagnosis.md — 端到端精度诊断工作流

## 概述

组合所有模块形成完整的精度诊断迭代循环：启动服务 → 执行测试 → 验证结果 → 分析日志 → 修复代码 → 重启验证。

## 适用场景

- vLLM + vLLM-Ascend 推理精度异常
- 输出与预期结果不一致
- 推理过程中出现 NaN/Inf 等数值异常

## 工作模式约束

### 约束 1：SSH 远程操作

所有远程操作通过 `scripts/ssh_utils.py` 执行。首次调用自动建立持久连接（daemon），后续命令复用同一连接。

```bash
# 单机模式
python scripts/ssh_utils.py exec standalone "<command>"

# PD分离模式 — P节点
python scripts/ssh_utils.py exec pd-separated.p[0] "<command>"

# PD分离模式 — D节点
python scripts/ssh_utils.py exec pd-separated.d[0] "<command>"

# 评测机器
python scripts/ssh_utils.py exec eval "<command>"

# 操作完成后释放连接（可选，空闲 60 分钟自动退出）
python scripts/ssh_utils.py stop standalone
```

### 约束 2：aisbench 必须在服务就绪后执行
aisbench 精度评测必须在 vLLM 服务**完全启动并通过健康检查**后才能执行。执行前必须验证：
1. 日志中包含 `Application startup complete.` 或 `Started server process`
2. `curl http://{host}:{port}/v1/models` 返回 200

## 前置条件

- 以下配置文件已正确填写：
  - `config/service.yaml`（服务配置，含单机/PD分离模式）
  - `config/test.yaml`（测试配置）
  - `config/model.yaml`（模型和源码配置）
- vLLM-Ascend 源码在可修改的路径下

---

## 工作流

### 第 1 步：初始化

读取所有配置文件，确认配置正确。

```bash
# 检查 vllm-ascend 安装
pip show {model.pip_package}

# 确认源码位置
pip show {model.pip_package} | grep Location

# 确认模型文件存在
ls {model.model_path}
```

### 第 2 步：启动服务（含启动失败子循环）

调用 **service.md** 模块，根据 `service.yaml` 中的 `mode` 选择单机或 PD分离模式启动服务。

- 单机模式（standalone）：prefill 与 decode 混合调度，在一台机器上启动
- PD分离模式（pd-separated）：P 节点（prefill）和 D 节点（decode）分别启动，通过 proxy 协调

#### 2a. 启动并监控

启动后使用 `wait` 轮询日志等待完成（约 10 分钟以上）：

```bash
# 单机模式
python scripts/ssh_utils.py wait standalone "{docker.log_file}" "Application startup complete" --timeout 3600

# PD分离模式 — 分别等 P 和 D 节点
python scripts/ssh_utils.py wait pd-separated.p[0] "{docker.log_file}" "Application startup complete" --timeout 3600
python scripts/ssh_utils.py wait pd-separated.d[0] "{docker.log_file}" "Application startup complete" --timeout 3600
```

#### 2b. 检查启动结果

| 日志现象 | 结论 | 后续动作 |
|----------|------|----------|
| 包含所有 `success_keywords` | ✅ 启动成功 | 执行健康检查（2c） |
| 包含 `Error` / `Traceback` / `Exception` | ❌ 启动失败 | **不要继续**，进入第 2d 步 |
| 长时间无新输出（超时） | ⚠️ 疑似卡住 | 检查是否有 OOM 等问题 |

#### 2c. 健康检查

```bash
# 单机模式（用实际 IP，unset proxy）
python scripts/ssh_utils.py exec standalone "docker exec {docker.name} bash -c 'unset http_proxy; unset https_proxy; curl -s -o /dev/null -w \"%{http_code}\" --max-time 30 http://{standalone.host}:{standalone.service_port}/v1/models'"

# PD分离模式
python scripts/ssh_utils.py exec pd-separated.p[0] "docker exec {docker.name} bash -c 'unset http_proxy; unset https_proxy; curl -s -o /dev/null -w \"%{http_code}\" --max-time 30 http://{pd-separated.host}:{pd-separated.service_port}/v1/models'"
```

- 返回 `200` → **服务就绪**，进入第 3 步
- 返回非 `200` → 回到 2a 继续等待或进入 2d

#### 2d. 启动失败处理子循环

**当服务启动失败（日志报错/超时/健康检查不通过）时：**

1. 调用 **log-analyzer.md** 分析启动日志中的错误
2. 调用 **auto-fixer.md** 修复 vllm-ascend 代码
3. 调用 **service.md** 停止当前服务（`fuser -k {port}/tcp`）
4. **回到 2a** 重新启动并再次验证

> **核心规则**：服务健康检查通过是后续所有步骤（测试、aisbench 评测）的**严格前置条件**。在健康检查通过之前，严禁执行任何推理请求或精度评测。

### 第 3 步：执行测试

调用 **test-runner.md** 模块，执行测试脚本。

发送推理请求，捕获输出到日志文件。

### 第 4 步：验证结果

调用 **verifier.md** 模块，将测试输出与预期结果对比。

- ✅ **验证通过** → 精度诊断完成
  - 如有修复记录，更新 fix_N.md 标记为成功
  - 输出最终结果
  - 工作流结束

- ❌ **验证不通过** → 进入第 5 步

### 第 4b 步：【可选】精度数据集评测

调用 **aisbench-evaluator.md** 模块，使用 aisbench 在 GSM8K/GPQA 等数据集上进行更全面的精度评测：

1. 修改评测机器上的 aisbench 配置文件，指向当前推理服务
2. 执行 `ais_bench` 命令进行评测
3. 从日志中提取 **accuracy** 指标
4. 分析模型输出文件（`/home/outputs/default/*/results/vllm-api-general-chat/`）：
   - 检查是否有**乱码**（异常 Unicode 字符）
   - 检查是否有**复读**（连续重复短句）
5. 综合判断：
   - ✅ accuracy 达标 + 无乱码/复读 → **精度修复完成**
   - ❌ accuracy 偏低 → 精度异常，进入第 5 步
   - ⚠️ accuracy 达标但有乱码/复读 → 输出质量问题，进入第 5 步

### 第 5 步：分析日志

调用 **log-analyzer.md** 模块：
1. 读取服务日志（`service.yaml` 中的 `log_file`）
2. 读取测试日志（`test.yaml` 中的 `output_log`）
3. 扫描错误关键词，归类问题类型
4. 在 vllm-ascend 源码中定位可疑代码

### 第 6 步：修复代码

调用 **auto-fixer.md** 模块：
1. 读取定位到的可疑代码
2. 匹配修复策略
3. 应用代码修改
4. 记录修复到 `fix_N.md`
5. 准备重新测试

### 第 7 步：停止服务并重新开始迭代

停止当前服务，回到第 2 步。

> **关键**：回到第 2 步后，必须经过完整的 **启动 → 监控 → 健康检查** 流程，确认服务就绪后才能继续测试或评测。

### 完整迭代流程

```
                 ┌──────────────────────────────────────────────────┐
                 │                                                  │
                 ▼                                                  │
     ┌─────────────────────┐                                       │
     │  第 2 步：启动服务     │  ←── 启动失败时在此子循环内迭代 ──→    │
     │  ├─ 2a. 启动并监控   │                                       │
     │  ├─ 2b. 检查启动结果  │                                       │
     │  ├─ 2c. 健康检查      │── 成功 ─→ 继续                       │
     │  └─ 2d. 失败处理子循环 │← 失败 ─ 修代码 → 重启 ─→ 回到 2a   │
     └─────────┬───────────┘                                       │
               │ 服务就绪                                           │
               ▼                                                   │
     ┌─────────────────────┐                                       │
     │  第 3 步：执行测试    │                                       │
     └─────────┬───────────┘                                       │
               ▼                                                   │
     ┌─────────────────────┐                                       │
     │  第 4 步：验证结果    │── ✅ 通过 ─→ 完成                     │
     └─────────┬───────────┘                                       │
               │ ❌ 不通过                                          │
               ▼                                                   │
     ┌─────────────────────┐    ┌─────────────────────┐            │
     │  第 4b 步：【可选】   │──→ │ accuracy 偏低/       │            │
     │  aisbench 评测       │    │ 有乱码/复读         │            │
     └─────────────────────┘    └─────────┬───────────┘            │
                                          │ ❌                     │
                                          ▼                        │
     ┌─────────────────────┐    ┌─────────────────────┐            │
     │  第 5 步：分析日志    │──→ │  第 6 步：修复代码   │            │
     └─────────────────────┘    └─────────┬───────────┘            │
                                          │                        │
                                          ▼                        │
     ┌─────────────────────┐                                       │
     │  第 7 步：停止服务    │────────────────────────────────────────┘
     └─────────────────────┘
```

---

## 迭代记录

每次完整循环（第 2 步到第 7 步）为一个迭代。

- 每次循环对应一个 `fix_N.md` 记录文件
- 当前循环的修改不会影响上次的修改——所有修改累积叠加
- 如果三次迭代未解决，建议：
  1. 重新评估问题定位是否准确
  2. 考虑不同的修复方向
  3. 检查是否多个问题叠加

---

## 单机 vs PD分离 工作流差异

| 步骤 | 单机模式（standalone） | PD分离模式（pd-separated） |
|------|----------------------|---------------------------|
| 服务启动 | `ssh_utils.py exec standalone` 启动容器 | 分别对 p_nodes / d_nodes 启动 |
| 日志查看 | `ssh_utils.py exec standalone "tail ..."` | 分别查 P 和 D 节点日志 |
| 测试执行 | 根据 test.yaml 发 curl 请求 | 同上，端点指向 P 或 D 节点 |
| 代码修复 | 直接修改或通过 ssh_utils.py upload 上传 | 分别修改对应节点 |
| 服务重启 | stop → start | 分别 stop → start P 和 D |
| proxy | standalone 可选（DP 场景必配） | pd-separated 必配 |

---

> **经验文档**：完整调试案例见 `docs/dcp2tp4-precision-fix.md`，包含逐层对比、参考实现对拍、二分定位等方法论。

## A/B 对比排查流程

当需要对比两个配置（如 interleave=1 vs interleave=1024、DCP1 vs DCP2）的精度差异时，使用以下流程：

### 1. 配置 A（基准）跑测试

```bash
# 1) 启动服务时指定独立的日志文件（避免覆盖）
python scripts/ssh_utils.py exec standalone "docker exec {docker.name} bash -c 'cd {docker.work_dir}; nohup bash {docker.startup_script} > {docker.work_dir}/service_A.log 2>&1 &'"

# 2) 等待启动 + 健康检查
python scripts/ssh_utils.py wait standalone "{docker.work_dir}/service_A.log" "Application startup complete" --timeout 900

# 3) 执行测试
python scripts/generate_curl.py
python scripts/ssh_utils.py exec standalone "docker exec {docker.name} bash -c '$(cat scripts/curl_test.sh)'"
```

### 2. 配置 B（待测）跑测试

```bash
# 1) 按端口杀服务（fuser -k）
# 2) 修改启动脚本 → 配置 B
# 3) 启动服务，日志写入 service_B.log
python scripts/ssh_utils.py exec standalone "docker exec {docker.name} bash -c 'cd {docker.work_dir}; nohup bash {docker.startup_script} > {docker.work_dir}/service_B.log 2>&1 &'"
# 4) 等待启动 + 健康检查 + 执行测试（同上）
```

### 3. 对比日志

```bash
# 分别从容器内两个日志文件中提取关键 debug 输出
python scripts/ssh_utils.py exec standalone "docker exec {docker.name} grep 'DEBUG-CMP-FINAL' {docker.work_dir}/service_A.log"
python scripts/ssh_utils.py exec standalone "docker exec {docker.name} grep 'DEBUG-CMP-FINAL' {docker.work_dir}/service_B.log"

# 对比 out_sum 值，找第一处显著差异（>1% 即异常）
```

# 逐行对比 out_sum 值，找第一处显著差异（>1% 即异常）
diff <(cat a.log | grep -oP 'out_sum=[-\d.]+') <(cat b.log | grep -oP 'out_sum=[-\d.]+')
```

### 4. 定位根因

- 第一层就出现差异 → 问题在 **KV cache 存储/读取** 或 **prefill 计算**
- 第一处差异在中间层 → 误差随层累积，问题在 **attention merge 精度**
- 差异波动大、有时对有时错 → **数值非确定性**，查 merge kernel 精度

> **经验**：本次 DCP2TP4 问题中，第一层全注意力层 out_sum 差异已达 8%，远超 float32 精度范围，最终定位到 `npu_attention_update` 的 float32 精度不足。改用 float64 log-sum-exp 后修复。

---

## 完成条件

- 验证结果通过（实际输出与预期输出一致）
- 所有修复记录已更新
- 最终修复方案的总结文档已生成
