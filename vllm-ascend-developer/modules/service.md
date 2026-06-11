# service.md — 服务生命周期管理模块

## 概述

管理 vLLM 推理服务的启动、监控、健康检查和停止。支持单机（standalone）和 PD分离（pd-separated）两种模式，所有远程操作统一通过 `scripts/ssh_utils.py` 执行。

## 使用方式

该模块由工作流自动调用，或者可独立使用：
```
在当前会话中，遵循以下步骤启动服务。
```

## 前置条件

- 已正确配置 `config/service.yaml`
- 目标服务器已安装 Docker
- 如需下载依赖或 clone 代码，配置 `config/proxy.yaml`

---

## 单机模式流程（standalone）

所有命令通过 `python scripts/ssh_utils.py exec standalone "..."` 在目标机器上执行。

### 步骤 1：停止已有进程并清空 plog

**1a. 按端口杀 vLLM 进程及 proxy**：

```bash
# 杀服务端口（vllm）
python scripts/ssh_utils.py exec standalone "fuser -k {standalone.service_port}/tcp 2>/dev/null; sleep 2; fuser {standalone.service_port}/tcp || echo service_port_clean"

# 如果配置了 proxy_port，也杀掉
python scripts/ssh_utils.py exec standalone "fuser -k {docker.proxy_port}/tcp 2>/dev/null; sleep 1; fuser {docker.proxy_port}/tcp || echo proxy_port_clean_or_not_set"
```

> **说明**：`proxy_port` 为空时 `fuser` 报错但被 `2>/dev/null` 吞掉，不影响流程。proxy 和 vllm 共享端口时只需配 `service_port`。

**1b. 清空 plog**（防止旧日志干扰本次定位）：

```bash
python scripts/ssh_utils.py exec standalone "docker exec {docker.name} rm -rf /root/ascend/log/debug/plog/*; echo plog_cleared"
```

注意：每个命令单独执行，不可用 && 链式连接。

### 步骤 2：启动服务

```bash
python scripts/ssh_utils.py exec standalone "docker exec {docker.name} bash -c 'cd {docker.work_dir}; nohup bash {docker.startup_script} > {docker.log_file} 2>&1 &'; echo service_started"
```

### 步骤 3：监控日志等待启动

启动过程通常需要 10 分钟以上。在容器内轮询日志，直到出现成功关键词：

```bash
# 等待启动完成（每 30s 检查一次，最多等 15 分钟）
python scripts/ssh_utils.py wait standalone "{docker.log_file}" "Application startup complete" --timeout 900 --interval 30
```

> **注意**：`wait` 依赖宿主机能直接读到 `{docker.log_file}`。如果宿主机容器路径不一致，改用：
> ```bash
> python scripts/ssh_utils.py exec standalone "docker exec {docker.name} grep 'Application startup complete' {docker.log_file} || echo not_ready"
> ```
> 手工轮询直到匹配为止。

也可手动查看进度：

```bash
python scripts/ssh_utils.py exec standalone "docker exec {docker.name} tail -n 50 {docker.log_file}"
```

### 步骤 4：检查启动成功

日志中是否包含所有 `success_keywords`：
- `Application startup complete.`
- `Started server process`

```bash
python scripts/ssh_utils.py exec standalone "docker exec {docker.name} grep -E 'Application startup complete|Started server process' {docker.log_file}"
```

### 步骤 5：健康检查

服务启动后使用实际 IP 做健康检查（注意：`--host` 绑定的 IP 不是 `localhost`）：

```bash
# 用服务实际绑定的 IP（service.yaml 中的 standalone.host）
python scripts/ssh_utils.py exec standalone "docker exec {docker.name} bash -c 'unset http_proxy; unset https_proxy; curl -s -o /dev/null -w \"%{http_code}\" --max-time 30 http://{standalone.host}:{standalone.service_port}/v1/models'"
# 必须返回 200
```

> **重要**：curl 前必须 `unset http_proxy; unset https_proxy`，否则代理可能导致 504。

---

## PD分离模式流程（pd-separated）

PD分离模式下 P 节点（prefill）和 D 节点（decode）分别在不同机器上。节点通过 `pd-separated.p[N]` / `pd-separated.d[N]` 引用。

### 步骤 1：停止已有进程并清空 plog

对每个 P 节点和 D 节点，按端口杀：

```bash
# P 节点
python scripts/ssh_utils.py exec pd-separated.p[0] "fuser -k {pd-separated.service_port}/tcp 2>/dev/null; sleep 2; echo p_killed"
# D 节点
python scripts/ssh_utils.py exec pd-separated.d[0] "fuser -k {pd-separated.service_port}/tcp 2>/dev/null; sleep 2; echo d_killed"

# 清空 plog
python scripts/ssh_utils.py exec pd-separated.p[0] "docker exec {docker.name} rm -rf /root/ascend/log/debug/plog/*; echo plog_cleared"
python scripts/ssh_utils.py exec pd-separated.d[0] "docker exec {docker.name} rm -rf /root/ascend/log/debug/plog/*; echo plog_cleared"
```

### 步骤 2：启动服务

P 节点和 D 节点分别启动各自的 proxy + vLLM 服务：

```bash
# P 节点启动
python scripts/ssh_utils.py exec pd-separated.p[0] "docker exec {docker.name} bash -c 'cd {docker.work_dir}; nohup bash {docker.proxy_script} > {docker.log_file} 2>&1 &'; echo p_proxy_started"
python scripts/ssh_utils.py exec pd-separated.p[0] "docker exec {docker.name} bash -c 'cd {docker.work_dir}; nohup bash {docker.startup_script} > {docker.log_file} 2>&1 &'; echo p_service_started"

# D 节点同理
python scripts/ssh_utils.py exec pd-separated.d[0] "docker exec {docker.name} bash -c 'cd {docker.work_dir}; nohup bash {docker.proxy_script} > {docker.log_file} 2>&1 &'; echo d_proxy_started"
python scripts/ssh_utils.py exec pd-separated.d[0] "docker exec {docker.name} bash -c 'cd {docker.work_dir}; nohup bash {docker.startup_script} > {docker.log_file} 2>&1 &'; echo d_service_started"
```

### 步骤 3-5：监控、检查、健康检查

与单机模式相同，分别对 P 和 D 节点执行。健康检查端口使用 `{pd-separated.service_port}`。

```bash
python scripts/ssh_utils.py exec pd-separated.p[0] "docker exec {docker.name} tail -n 50 {docker.log_file}"
python scripts/ssh_utils.py exec pd-separated.d[0] "docker exec {docker.name} tail -n 50 {docker.log_file}"
```

---

## 停止服务

**按端口杀**（`fuser -k` 精准不误伤）：

```bash
# 单机模式 — 杀服务端口 + proxy端口（如配置）
python scripts/ssh_utils.py exec standalone "fuser -k {standalone.service_port}/tcp 2>/dev/null; sleep 2; echo service_killed"
python scripts/ssh_utils.py exec standalone "fuser -k {docker.proxy_port}/tcp 2>/dev/null; sleep 1; echo proxy_checked"

# PD分离模式 — 分别停各节点
python scripts/ssh_utils.py exec pd-separated.p[0] "fuser -k {pd-separated.service_port}/tcp 2>/dev/null; sleep 2; echo p_done"
python scripts/ssh_utils.py exec pd-separated.d[0] "fuser -k {pd-separated.service_port}/tcp 2>/dev/null; sleep 2; echo d_done"
```

> **说明**：`fuser -k {port}/tcp` 只杀占用指定端口的进程，不影响其他服务。proxy 和 vllm 共用端口则一条命令搞定；proxy 独立端口则额外 `fuser -k proxy_port/tcp`。`proxy_port` 为空时命令无害（被 `2>/dev/null` 吞掉）。

---

## 常见问题

1. **启动超时** — 检查 `startup_timeout` 是否足够，查看日志是否有明显错误
2. **端口冲突** — 检查端口是否已被占用，修改对应模式下的 `service_port`
3. **模型路径错误** — 检查 `model.yaml` 中的 `model_path` 是否正确
4. **Ascend 设备初始化失败** — 检查是否正确挂载了 `/dev/davinci*` 设备
5. **OOM 错误** — 模型过大或 batch size 过高，检查显存：`npu-smi info`
6. **ssh_utils.py 连接失败** — 检查 `service.yaml` 中节点的 `host/port/username/password` 是否正确
7. **daemon 异常** — `python scripts/ssh_utils.py stop <node-ref>` 停止后重试
