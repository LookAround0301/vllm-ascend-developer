---
name: dev-machine-network
description: 这台开发机(worker-152)是华为公司网，公网需走 MITM 代理 + 国内镜像；electron/二进制下载的特殊处理
metadata: 
  node_type: memory
  type: project
  originSessionId: 49fb564c-5c01-4577-914b-8a401820de34
---

worker-152（root，aarch64，Ubuntu 24.04 容器，跑在 Ascend NPU 宿主机 oe2203sp4 上）在华为公司网内：**直连公网(GitHub 等)超时，必须走公司 MITM 代理**。

- **代理**：`http://p_atlas:proxy%40123@<IP>:8080`（IP 会变，当前值看 `~/.bashrc` 的 `http_proxy` 或 HyperScript 顶部 `DEFAULT_PROXY_IP`；2026-06 用过 141.1.51.6 / 141.3.169.143 / 141.3.169.14）。代理是 MITM（自签证书）→ curl 要 `-k`、npm 要 `strict-ssl=false`、node 靠 `NODE_TLS_REJECT_UNAUTHORIZED=0`（已在 bashrc）。
- **镜像**：npm=`registry.npmmirror.com`，pip=`pypi.tuna.tsinghua.edu.cn`，**apt 已换 TUNA** `mirrors.tuna.tsinghua.edu.cn/ubuntu-ports`（ports.ubuntu.com 被代理篡改，`fonts-dejavu-core` 出现 Hash Sum mismatch）。
- **electron 二进制**：`@electron/get`(electron 的 postinstall) **不读 proxy 环境变量、也不读 npm proxy 配置**，直连 GitHub 必超时。解法：用 `curl -kfL` 从 `registry.npmmirror.com/-/binary/electron/<ver>/` 下二进制（校验 sha256），本地 `python3 -m http.server` 起服务，再 `ELECTRON_MIRROR=http://127.0.0.1:<port>/ npm install`；成功后 `~/.cache/electron` 会缓存，重装可复用。
- **git clone GitHub**：也走代理（curl/git 都尊重 http_proxy）。

**Why**: 这台机器装任何东西(包/二进制/源码)都会撞这套网络限制，不掌握会反复踩坑。
**How to apply**: 装包用上面镜像 + `-k`；遇到 electron/electron-builder 等不认代理的二进制下载，走「curl 下载 + 本地 HTTP 镜像 + ELECTRON_MIRROR」套路。相关：[[clawd-term-pet]]
