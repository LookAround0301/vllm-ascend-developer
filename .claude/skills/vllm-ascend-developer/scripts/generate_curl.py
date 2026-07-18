#!/usr/bin/env python3
"""
从 config/test.yaml 生成 curl 测试脚本。

用法：
    python scripts/generate_curl.py           # 生成 scripts/curl_test.sh
    python scripts/generate_curl.py --dry-run # 只打印，不写文件

生成的 curl_test.sh 可直接在容器内执行，用于发送推理请求。
"""

import argparse
import json
import sys
from pathlib import Path

import yaml

SKILL_ROOT = Path(__file__).resolve().parent.parent
TEST_YAML = SKILL_ROOT / "config" / "test.yaml"
OUTPUT = SKILL_ROOT / "scripts" / "curl_test.sh"


def main():
    parser = argparse.ArgumentParser(description="生成 curl 测试脚本")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--test-index", type=int, default=0)
    parser.add_argument("--prompt-index", type=int, default=0)
    args = parser.parse_args()

    with open(TEST_YAML) as f:
        cfg = yaml.safe_load(f)

    tests = cfg.get("tests", [])
    if args.test_index >= len(tests):
        sys.exit(f"测试索引 {args.test_index} 超出范围（共 {len(tests)} 条）")

    test = tests[args.test_index]
    endpoint = test["endpoint"]
    params = test.get("params", {})
    prompts = test.get("prompts", [])
    if args.prompt_index >= len(prompts):
        sys.exit(f"prompt 索引 {args.prompt_index} 超出范围（共 {len(prompts)} 条）")

    # model 名来源：test.yaml params.model > model.yaml
    model_name = params.get("model")
    if not model_name:
        model_yaml = SKILL_ROOT / "config" / "model.yaml"
        if model_yaml.exists():
            with open(model_yaml) as f:
                model_cfg = yaml.safe_load(f)
            model_name = model_cfg.get("served_model_name", "deepseek")
        else:
            model_name = "deepseek"

    payload = {
        "model": model_name,
        "prompt": prompts[args.prompt_index],
        "max_tokens": params.get("max_tokens", 10),
        "temperature": params.get("temperature", 0),
    }
    payload_json = json.dumps(payload, ensure_ascii=False)

    script = f"""#!/bin/bash
# 自动生成，来源: config/test.yaml
# 重新生成: python scripts/generate_curl.py

unset http_proxy
unset https_proxy

curl {endpoint} \\
    -H "Content-Type: application/json" \\
    -d '{payload_json}'
"""

    if args.dry_run:
        print(script)
    else:
        OUTPUT.write_text(script)
        OUTPUT.chmod(0o755)
        print(f"已生成: {OUTPUT}")


if __name__ == "__main__":
    main()
