# auto-fixer.md — 自动修复引擎模块

## 概述

基于日志分析结果，自动定位 vllm-ascend 源代码中的问题区域，生成修复方案并应用修改。迭代修复并记录每次变更。

## 使用方式

```
日志分析完成后，调用此模块生成并应用修复。
```

## 前置条件

- log-analyzer 已完成分析，提供了错误类别和可疑代码位置
- `model.yaml` 中的 `vllm_ascend_source` 路径正确
- **重要**：只修改 `vllm-ascend` 代码，禁止修改 `vllm` 代码

---

> **经验文档**：DCP merge 精度修复案例见 `docs/dcp2tp4-precision-fix.md`。

## 修复流程

### 步骤 1：读取可疑代码

```bash
# 阅读定位到的可疑源代码
cat {vllm_ascend_source}/path/to/suspected/file.py

# 同时阅读 vLLM 中对应的参考实现
cat {vllm_source}/path/to/reference/file.py
```

对比两者实现，找出差异点。

### 步骤 2：错误原因分析与修复策略匹配

根据 log-analyzer 输出的错误类别，匹配修复策略：

| 错误类别 | 修复策略 | 示例 |
|---------|---------|------|
| 数据类型转换 | 在算子入口处添加 dtype 检查和转换 | `x = x.to(torch.float32)` 在计算前，计算完再转回 |
| DCP / CP 精度异常 | 用 PyTorch 参考实现对拍可疑 kernel，找到差异点后针对性修复 | 见 `docs/dcp2tp4-precision-fix.md`（NPU merge kernel float32→float64 案例） |
| NaN 推理输出 | 逐层定位第一次出现 NaN 的位置（`isnan` 检查），再排查该层的计算逻辑 | 常见原因：未初始化 padding、除零、`fill_()` 写到副本（见 `docs/pcp-hybrid-nan-fix.md`） |
| Attention 数值不稳定 | 为 Softmax 添加稳定化处理 | 添加 `x = x - x.max(dim=-1, keepdim=True)[0]` |
| 量化精度损失 | 提高中间计算精度 | 量化前使用 FP32 计算 scale/zero_point |
| 内存越界 | 检查张量 shape 对齐 | 添加 `assert x.size(-1) % 16 == 0` 确保对齐 |
| 算子融合精度 | 解耦融合算子分步计算 | 将融合算子拆分为多个独立算子逐步验证 |

### 步骤 3：应用修复

```bash
# 示例：修复数据类型转换问题
# 在可疑函数中添加类型转换
# 使用 sed 或 Python heredoc 修改文件

# 读取目标代码确认修改位置
cat -n {vllm_ascend_source}/path/to/file.py | head -50

# 对目标代码进行修改
# 例如：在 attention_forward 函数中添加 FP32 转换
```

注意：每次修改时，记录以下信息：
- 修改的文件路径
- 修改的行号范围
- 修改的内容
- 修改的原因

---

### 远程模式下的修复流程

代码运行在远程服务器上，通过 `scripts/ssh_utils.py` 读写文件：

```bash
# 步骤 1：读取远程源码
python scripts/ssh_utils.py exec standalone "cat {vllm_ascend_source}/path/to/file.py"

# 步骤 2：修改远程文件（sed 或 heredoc）
python scripts/ssh_utils.py exec standalone "sed -i 's/old_code/new_code/' {vllm_ascend_source}/path/to/file.py"

# 或上传本地修改好的文件
python scripts/ssh_utils.py upload standalone /local/path/file.py {vllm_ascend_source}/path/to/file.py

# 步骤 3：重启服务（按 service.md 流程）
```

PD分离模式下将 `standalone` 替换为对应节点引用（`pd-separated.p[0]` / `pd-separated.d[0]`）。

### 步骤 4：记录修复到 fix_N.md

```markdown
# fix_{N}.md

## 迭代 {N}
- **日期**: {current_date}
- **错误摘要**: {错误描述}

## 分析
{分析过程}

## 修改
- **文件**: {modified_file}
- **位置**: 第 {line_number} 行
- **改动**: {改动内容}

## 结果
{待验证}
```

其中 N 从 1 开始递增。如果已有 fix_1.md, fix_2.md，则新建 fix_3.md。

### 步骤 5：应用修复并重启验证

宿主机和容器内的 vllm/vllm-ascend 目录默认一致，本地改代码后直接重启容器内服务即可生效（无需 `docker cp` 或 `pip install`）：

```bash
# 1. 停服务
python scripts/ssh_utils.py exec standalone "fuser -k {service_port}/tcp 2>/dev/null"

# 2. 重启
python scripts/ssh_utils.py exec standalone "docker exec {docker.name} bash -c 'cd {docker.work_dir}; nohup bash {docker.startup_script} > {docker.log_file} 2>&1 &'"

# 3. 等待就绪 → 健康检查 → 跑测试验证
```

> **注意**：只修改 Python 代码（`vllm_ascend/` 下）无需重新编译。如果修改了 `csrc/` 下的算子源码，需要重新编译安装。


## 限制

- 只修改 `vllm-ascend` 目录下的代码
- 每次修改后必须重新启动服务验证
- 如果多次迭代后仍未修复，考虑不同的修复方向
