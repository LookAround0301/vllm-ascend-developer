# vllm-ascend-developer

vLLM + vLLM-Ascend 框架下的通用开发与调试 Skill，覆盖推理精度诊断、服务管理、自动化测试与代码修复等场景。支持**单机**和**PD分离**两种部署模式。

## 目录结构

```
vllm-ascend-developer/
├── SKILL.md                     # Skill 主入口（Claude Code 加载入口）
├── CLAUDE.md                    # Claude Code 项目指南
├── README.md                    # 本文件
├── config/                      # 配置文件（使用前需根据实际环境修改）
│   ├── service.yaml             # 服务配置（部署模式、SSH、Docker、端口）
│   ├── test.yaml                # 测试用例（端点、参数、prompt、预期输出）
│   ├── model.yaml               # 模型路径与源码路径
│   ├── aisbench.yaml            # aisbench 精度/性能评测配置
│   └── proxy.yaml               # 网络代理配置（pip/git 公网访问）
├── modules/                     # 核心模块
│   ├── service.md               # 服务生命周期管理（启动/停止/健康检查）
│   ├── test-runner.md           # 测试执行器（发送推理请求）
│   ├── verifier.md              # 结果验证器（对比预期输出）
│   ├── aisbench-evaluator.md    # 精度数据集评测（aisbench）
│   ├── log-analyzer.md          # 日志分析器（错误分类与定位）
│   ├── auto-fixer.md            # 自动修复引擎（迭代修复 + fix_N.md 记录）
│   └── flashcomm-mtp-debug.md   # FlashComm + MTP 调试专项指南
├── workflows/                   # 工作流
│   └── precision-diagnosis.md   # 端到端精度诊断工作流
├── scripts/                     # 工具脚本
│   ├── ssh_utils.py             # SSH 远程执行（exec/wait/upload/download）
│   └── generate_curl.py         # 从 config/test.yaml 生成 curl 测试脚本
└── docs/                        # 调试经验文档
    ├── dcp2tp4-precision-fix.md # DCP 精度调试案例（逐层对比 + float64 LSE merge）
    └── pcp-hybrid-nan-fix.md    # PCP NaN 案例（bool mask fill_() 写回陷阱）
```

## 快速开始

### 第零步：安装依赖

```bash
pip install paramiko pyyaml -i https://pypi.tuna.tsinghua.edu.cn/simple
```

验证安装：

```bash
python -c "import paramiko, yaml; print('ok')"
# 输出 ok
```

### 第一步：配置环境

根据自己的实际环境，修改以下配置文件：

1. **`config/service.yaml`** — 设置部署模式（standalone/pd-separated）、服务器 SSH、Docker 参数
2. **`config/test.yaml`** — 设置测试用例（端点、参数、prompt、预期输出）
3. **`config/model.yaml`** — 设置模型路径和 vllm-ascend 源码路径
4. **`config/aisbench.yaml`** — 【可选】设置精度数据集评测参数
5. **`config/proxy.yaml`** — 【可选】设置网络代理

### 第二步：执行精度诊断工作流

按照 `workflows/precision-diagnosis.md` 中的步骤执行：

```
初始化配置 → 启动服务 → 健康检查 → 执行测试 → 验证结果
    ↓ 不通过
  分析日志 → 修复代码 → 重启服务 → 回到测试
```

每次修复迭代记录在 `fix_N.md`（N 从 1 递增）。

## 两种部署模式

| 模式 | 说明 | 适用场景 |
|------|------|----------|
| **standalone**（单机） | prefill 与 decode 在同一台机器上混合调度 | 单台 NPU 服务器，开发测试 |
| **pd-separated**（PD分离） | P 节点（prefill）与 D 节点（decode）分离部署，通过 proxy 协调 | 大规模分布式推理，独立扩缩容 |

## 精度 / 性能评测（aisbench）

对于数据集级别的精度验证和性能压测，推荐使用 [aisbench_auto_tools_prefix](https://github.com/rayn-zzz/aisbench_auto_tools_prefix)。

### 工具简介

`aisbench_auto_tools_prefix` 是一个基于 aisbench 的自动化评测工具，支持：

- **精度评测**：在 GSM8K、GPQA 等数据集上评估模型推理精度
- **性能压测**：可配置输入/输出 token 长度、并发数、请求速率等参数
- **Prefix Cache 测试**：支持前缀缓存场景下的性能与精度测试
- **流式 / 非流式**：支持 `stream` 和 `text` 两种推理模式
- **Thinking 模式**：支持 DeepSeek V3.1 等模型的 thinking 输出

### 在本 Skill 中的集成

评测机器通过 `config/aisbench.yaml` 配置，Skill 中的 `modules/aisbench-evaluator.md` 模块提供了完整的评测流程：

1. 修改 aisbench 配置文件指向推理服务
2. 确保 vLLM 推理服务健康检查通过（返回 200）
3. 执行 `ais_bench` 命令进行评测
4. 从日志中提取 **accuracy** 指标
5. 分析模型输出文件（检查乱码、复读）
6. 根据结果决定是否进入修复迭代

### 核心要求

> **重要**：aisbench 评测必须在 vLLM 服务完全启动并通过健康检查后才能执行，严禁在服务未就绪时发起评测。

## 环境要求

- 目标服务器已安装 Docker
- 已配置 Ascend NPU 设备（`npu-smi` 可用）
- vLLM 和 vLLM-Ascend 已在容器内预装
- Python 3.x + paramiko + pyyaml

## 注意事项

1. **只修改 vllm-ascend 代码** — 禁止修改 vLLM 上游源码
2. **每个 `ssh_utils exec` 命令独立执行** — 不同 exec 之间不可用 `&&` 链式连接
3. **禁止擅自重装** — vLLM 和 vLLM-Ascend 容器内已预装，未经同意禁止 `pip install`
4. **按端口杀进程** — 使用 `fuser -k {port}/tcp`，不误伤其他服务
5. **启动耗时** — vLLM 服务启动通常需要 10 分钟以上
6. **配置一致性** — 启动脚本和测试脚本中的端口、模型名称必须一致
7. **密码保护** — 配置文件中含敏感信息，建议将 `config/` 加入 `.gitignore`
