# verifier.md — 结果验证器模块

## 概述

将测试输出与预期结果进行对比，判断精度是否达标。支持三种比较模式。

## 使用方式

```
在当前会话中，获取测试输出后运行验证。
```

## 前置条件

- 测试已执行完成，有可读的输出日志
- 测试已执行，`config/test.yaml` 中每条用例已配置 `expected_output` 和 `comparison_mode`

---

## 验证步骤

### 步骤 1：获取实际输出

```bash
# 运行测试并提取 text 字段
python scripts/ssh_utils.py exec standalone "docker exec {docker.name} bash /path/to/curl_test.sh" | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['text'])"
```

### 步骤 2：和预期输出对比

从 `config/test.yaml` 读取 `expected_output` 和 `comparison_mode`，与步骤 1 的输出对比。

```python
# 示例：在 Python 中读取 test.yaml 并对比
import yaml
cfg = yaml.safe_load(open('config/test.yaml'))
test = cfg['tests'][0]
expected = test['expected_output']
mode = test['comparison_mode']

actual = " porch of Tara, your father%27s"  # 步骤 1 的输出

if mode == 'exact':
    ok = (actual == expected)
elif mode == 'contains':
    ok = (expected in actual)
else:  # regex
    import re
    ok = bool(re.search(expected, actual))
```

### 步骤 3：输出验证结果

- ✅ **验证通过** → 精度正常，工作流结束
- ❌ **验证不通过** → 记录差异，进入 `log-analyzer.md` 分析原因

---

## 验证结果格式

```
=== 验证结果 ===
状态: FAIL
比较模式: exact
预期输出: "B"
实际输出: "A"
差异: 首字符不同（预期 B，实际 A）
================
```

---

## 常见问题

1. **输出为空** — 服务可能未正确响应，检查服务状态
2. **输出包含额外字符** — 考虑换用 `contains` 模式
3. **随机性输出** — 如果模型输出有随机性，考虑多轮测试取统计结果
