---
name: npu-graph-debug
description: "对比 NPU 图模式(cudagraph)与单算子模式(enforce-eager)精度。预分配 buffer + 异步 copy_ 记录中间 tensor，model runner 中统一写文件对比。"
---

# NPU Graph Debug

## 启动

```bash
# 图模式 (devices 0-7)
python vllm_launcher.py -m /path/to/model --dbg-dir ./debug

# 单算子模式 (devices 8-15)
python vllm_launcher.py -m /path/to/model --eager --dbg-dir ./debug \
    --visible-devices 8,9,10,11,12,13,14,15
```

输出到 `--dbg-dir/graph/r{rank}.log` 和 `--dbg-dir/eager/r{rank}.log`。

## 代码模板

以下三个部分即可完成打点，复制到需要调试的 Impl 文件和 model_runner 即可。

### 模块级（Impl 文件顶部）

```python
DEBUG_ENABLE = 1
DEBUG_LAYERS_NUM = 2
DEBUG_RANKS = (0, 1, 2, 3, 4, 5, 6)
_all_impls: list = []

def flush_all_dbg_buffers() -> None:
    if not _all_impls:
        return
    if torch.npu.is_current_stream_capturing():
        return
    torch.npu.synchronize()
    lines = []
    for impl in _all_impls:
        impl._flush(lines)
    if lines:
        with open(_dbg_filepath(), "a") as f:
            f.write("\n".join(lines) + "\n")
            f.flush()
```

### Impl 类

```python
class YourImpl:
    def __init__(self, ..., **kwargs):
        # ...原有 init...
        self.tp_rank = get_tp_group().rank_in_group
        self._dbg = DEBUG_ENABLE and self.tp_rank in DEBUG_RANKS
        if self._dbg:
            self._dbg_step, self._dbg_layer_idx = 0, -1
            dev = torch.device(f"npu:{self.tp_rank}")
            self._dbg_shape = {"IN": (4,8), "OUT": (4,8)}  # (max_rows, max_cols)
            self._dbg_buf = {t: torch.zeros(*s, dtype=torch.bfloat16, device=dev) for t,s in self._dbg_shape.items()}
            self._dbg_stat = {t: torch.zeros(4, dtype=torch.float32, device=dev) for t in self._dbg_shape}
            _all_impls.append(self)

    def _copy(self, tag, tensor):
        if not self._dbg: return
        buf = self._dbg_buf.get(tag)
        if buf is None or tensor.numel() == 0: return
        # >2D 截前8 heads、前2 cols 压平为 2D
        t = tensor[:,:8,:2].view(tensor.shape[0],-1) if tensor.ndim > 2 else tensor.view(tensor.shape[0],-1)[:,:8]
        t = t.to(buf.dtype).contiguous()
        n, d = min(t.shape[0],buf.shape[0]), min(t.shape[1],buf.shape[1])
        buf[:n,:d].copy_(t[:n,:d], non_blocking=True)
        # 完整 tensor 统计(device-side,入图安全)
        s = self._dbg_stat.get(tag)
        if s is not None:
            tf = tensor.float()
            s[0].copy_(tf.min(),non_blocking=True); s[1].copy_(tf.max(),non_blocking=True)
            s[2].copy_(tf.mean(),non_blocking=True); s[3].copy_(tf.var(),non_blocking=True)

    def _flush(self, lines):
        if not self._dbg or not (0 <= self._dbg_layer_idx < DEBUG_LAYERS_NUM): return
        for tag in self._dbg_shape:
            buf = self._dbg_buf.get(tag)
            if buf is None: continue
            cpu = buf.cpu().tolist()
            stat = self._dbg_stat[tag].cpu()
            lines.append(f"[S{self._dbg_step}][L{self._dbg_layer_idx}][T{self.tp_rank}] {tag} "
                         f"stat(min={stat[0]:+.4f},max={stat[1]:+.4f},mean={stat[2]:+.4f},var={stat[3]:+.4f})\n"
                         + "[[" + "],[".join([",".join(f"{v:+.4f}" for v in r) for r in cpu]) + "]]")
        self._dbg_step += 1

    def forward(self, layer_name, *args, **kwargs):
        if self._dbg and self._dbg_layer_idx < 0:          # 首次设置 layer_idx
            for i,p in enumerate(layer_name.split(".")):
                if p == "layers" and i+1 < len(layer_name.split(".")):
                    self._dbg_layer_idx = int(layer_name.split(".")[i+1]); break
        # ...正常计算... self._copy("IN", x); ... self._copy("OUT", y)
```

### Model Runner

```python
from your_impl import flush_all_dbg_buffers

def execute_model(self, ...):
    hidden_states = self._model_forward(...)
    flush_all_dbg_buffers()
    ...
```

## 对比流程

1. 运行两轮，得到 `graph/r{rank}.log` 和 `eager/r{rank}.log`
2. 按 `[SN][LN][TN]` 对齐同一步的同一 tag
3. **先比 stat** — min/max/mean/var 一致则 tensor 整体一致
4. stat 不一致时对比截取值定位差异位置；不够则增大 `_dbg_shape` 或增加不同切片的 tag
5. 定位差异操作 → 修复 → 重启 → 重新对比

## 注意点

| 注意点 | 说明 |
|--------|------|
| **impl 必须在 `__init__` 注册** | `_all_impls.append(self)` 在 init，不可在 forward（图 replay 不执行） |
| **buffer 预分配** | init 中 `torch.zeros`，不能在 forward 中惰性创建 |
| **copy 必须 non_blocking** | `buf[:n].copy_(t[:n], non_blocking=True)` 才可入图 |
| **flush 前 synchronize + 跳过 capture** | `is_current_stream_capturing()` + `torch.npu.synchronize()` |
| **不要用 device_print / logger** | 写文件最可靠 |
| **int32 tensor** | `tensor.float()` 后再统计，避免 mean/var 走 CPU kernel |
| **结束关闭** | `DEBUG_ENABLE = 0` 零性能影响 |
