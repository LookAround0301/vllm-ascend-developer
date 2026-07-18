# test-runner.md — 测试执行器模块

## 概述

读取 `config/test.yaml` 中的测试用例列表，逐条发送推理请求，输出结果用于后续验证。

## 使用方式

```
在当前会话中，确认服务已启动后，执行测试。
```

## 前置条件

- vLLM 服务已成功启动并通过健康检查
- 已正确配置 `config/test.yaml`（测试用例列表）
- 远程操作通过 `scripts/ssh_utils.py` 执行

---

## 执行步骤

### 步骤 1：读取测试用例

从 `config/test.yaml` 读取 `tests[]` 列表，每条用例包含：

| 字段 | 说明 |
|------|------|
| `name` | 测试名称 |
| `endpoint` | 请求端点 URL |
| `params` | 请求参数（max_tokens, temperature, top_p, stream 等） |
| `prompts` | 测试 prompt 列表（每条 prompt 独立发起一次请求） |
| `expected_output` | 预期输出 |
| `comparison_mode` | 比较方式：exact / contains / regex |

### 步骤 2：生成 curl 脚本并执行

**2a. 从 test.yaml 生成 curl 脚本：**

```bash
python scripts/generate_curl.py
# → 生成 scripts/curl_test.sh（内容来自 config/test.yaml）
```

**2b. 执行测试：**

```bash
# 1) 从 test.yaml 生成 curl 脚本
python scripts/generate_curl.py

# 2) 写入容器 work_dir 并执行
python scripts/ssh_utils.py exec standalone "docker exec {docker.name} bash -c 'cat > {docker.work_dir}/curl_test.sh' < scripts/curl_test.sh"
python scripts/ssh_utils.py exec standalone "docker exec {docker.name} bash {docker.work_dir}/curl_test.sh"
```

> **设计原则**：`test.yaml` 是 prompt 的**唯一数据源**。`generate_curl.py` 从中生成 curl 脚本，消除手动拼写不一致的风险。每次修改 test.yaml 后重新生成即可。

### 步骤 3：检查响应

| 检查项 | 方法 | 通过条件 |
|--------|------|----------|
| HTTP 正常 | 响应以 `{` 开头 | 无连接错误 |
| 无异常关键词 | grep -i "error\|exception\|500\|502\|503" | 无匹配 |
| 无复读 | content 中无连续重复短句 | 无明显复读 |
| 无乱码 | content 中无异常字符 | 正常文本 |

如有异常，转入 log-analyzer 分析。

### 步骤 4：输出结果

将每条用例的响应内容保存到 `{output_log}`，供 verifier 模块对比验证。

---

## 配置一致性检查清单

- [ ] `test.yaml` 中的 `endpoint` 端口与 `service.yaml` 中对应模式的 `service_port` 一致
- [ ] 端点中的模型名称与 `aisbench.yaml` 中的 `model_name` 一致
- [ ] PD分离模式下确认请求发往正确的节点（P 或 D）
