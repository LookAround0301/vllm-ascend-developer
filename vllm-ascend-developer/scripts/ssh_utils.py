#!/usr/bin/env python3
"""
vllm-ascend-developer SSH 工具 — 基于 service.yaml 的远程执行模块。

特性：
- 从 config/service.yaml 读取节点连接信息，无需 ~/.ssh/config
- 持久连接 daemon：首次连接后复用，避免反复 SSH 握手
- 密码通过 Paramiko 内存传递，不暴露在命令行
- 支持 exec / upload / download / status / stop

用法：
    python scripts/ssh_utils.py exec standalone "hostname"
    python scripts/ssh_utils.py exec pd-separated.p[0] "npu-smi info"
    python scripts/ssh_utils.py status standalone
    python scripts/ssh_utils.py stop standalone
"""

import argparse
import json
import os
import signal
import socket
import struct
import sys
import time
import traceback
from hashlib import md5
from pathlib import Path
from threading import Thread

# 依赖检查：第三方包不在标准库中，首次使用需安装
try:
    import yaml
except ImportError:
    sys.exit(
        "ssh_utils.py 缺少依赖 pyyaml，请先安装:\n"
        "  pip install pyyaml paramiko -i https://pypi.tuna.tsinghua.edu.cn/simple"
    )
try:
    import paramiko
except ImportError:
    sys.exit(
        "ssh_utils.py 缺少依赖 paramiko，请先安装:\n"
        "  pip install pyyaml paramiko -i https://pypi.tuna.tsinghua.edu.cn/simple"
    )

# ---------------------------------------------------------------------------
# 路径常量
# ---------------------------------------------------------------------------
SKILL_ROOT = Path(__file__).resolve().parent.parent
CONFIG_DIR = SKILL_ROOT / "config"
SERVICE_YAML = CONFIG_DIR / "service.yaml"
AISBENCH_YAML = CONFIG_DIR / "aisbench.yaml"
DAEMON_DIR = Path("/tmp/vllm-ssh-daemon")
DAEMON_DIR.mkdir(parents=True, exist_ok=True)

# daemon 配置
IDLE_TIMEOUT = 3600       # 空闲超时 60 分钟
HEARTBEAT_INTERVAL = 60   # 心跳间隔 60 秒
MAX_RECONNECT = 3         # 最大重连次数


# ============================================================================
# 配置加载
# ============================================================================

def load_service_config():
    """加载 service.yaml，返回 dict。"""
    if not SERVICE_YAML.exists():
        die(f"找不到配置文件: {SERVICE_YAML}")
    with open(SERVICE_YAML) as f:
        return yaml.safe_load(f)


def load_aisbench_config():
    """加载 aisbench.yaml，返回 dict。"""
    if not AISBENCH_YAML.exists():
        die(f"找不到配置文件: {AISBENCH_YAML}")
    with open(AISBENCH_YAML) as f:
        return yaml.safe_load(f)


def resolve_node(node_ref):
    """解析节点引用，返回 {host, port, username, password, work_dir} 或报错退出。

    node_ref 格式：
      - "standalone"                     → service.yaml standalone 节点
      - "pd-separated.p[0]"              → p_nodes[0]
      - "pd-separated.d[1]"              → d_nodes[1]
      - "eval"                           → aisbench.yaml eval_machine
    """
    if node_ref == "eval":
        cfg = load_aisbench_config()
        section = cfg.get("eval_machine")
        if not section:
            die("aisbench.yaml 中没有 eval_machine 配置")
        return _extract_eval_node(section)

    cfg = load_service_config()

    if node_ref == "standalone":
        section = cfg.get("standalone")
        if not section:
            die("配置中没有 standalone 节点")
        return _extract_node(section)

    if node_ref.startswith("pd-separated."):
        rest = node_ref[len("pd-separated."):]
        if rest.startswith("p["):
            idx = _parse_index(rest, "p[")
            nodes = cfg.get("pd-separated", {}).get("p_nodes", [])
        elif rest.startswith("d["):
            idx = _parse_index(rest, "d[")
            nodes = cfg.get("pd-separated", {}).get("d_nodes", [])
        else:
            die(f"无效节点引用: {node_ref}")
        if idx >= len(nodes):
            die(f"节点索引超出范围: {node_ref} (共 {len(nodes)} 个)")
        return _extract_node(nodes[idx])

    die(f"无效节点引用: {node_ref}")


def _parse_index(s, prefix):
    """从 'p[0]' 或 'd[1]' 中提取索引数字。"""
    try:
        return int(s[len(prefix):].split("]")[0])
    except (ValueError, IndexError):
        die(f"无效节点引用格式")


def _extract_node(n):
    """从 service.yaml 节点配置中提取连接信息，验证必填字段。"""
    info = {
        "host": n.get("host", ""),
        "port": n.get("port", 22),
        "username": n.get("username", "root"),
        "password": n.get("password", ""),
        "work_dir": n.get("work_dir", ""),
    }
    if not info["host"] or info["host"].startswith("<"):
        die(f"节点 host 未配置或为占位符: {info['host']}")
    if not info["password"] or info["password"].startswith("<"):
        die(f"节点 password 未配置或为占位符")
    return info


def _extract_eval_node(n):
    """从 aisbench.yaml eval_machine 提取连接信息。"""
    info = {
        "host": n.get("host", ""),
        "port": n.get("port", 22),
        "username": n.get("username", "root"),
        "password": n.get("password", ""),
        "work_dir": n.get("docker", {}).get("work_dir", ""),
    }
    if not info["host"] or info["host"].startswith("<"):
        die(f"评测机器 host 未配置: {info['host']}")
    if not info["password"] or info["password"].startswith("<"):
        die(f"评测机器 password 未配置")
    return info


# ============================================================================
# Daemon 信息文件
# ============================================================================

def _daemon_key(node_ref):
    """安全的文件名 key（用 md5 避免特殊字符问题）。"""
    return md5(node_ref.encode()).hexdigest()


def _daemon_info_file(node_ref):
    return DAEMON_DIR / f"{_daemon_key(node_ref)}.json"


def read_daemon_info(node_ref):
    """读取 daemon 的 pid 和端口，不存在则返回 None。"""
    f = _daemon_info_file(node_ref)
    if not f.exists():
        return None
    try:
        with open(f) as fh:
            return json.load(fh)
    except (json.JSONDecodeError, IOError):
        return None


def write_daemon_info(node_ref, pid, port):
    with open(_daemon_info_file(node_ref), "w") as f:
        json.dump({"pid": pid, "port": port, "node_ref": node_ref}, f)


def remove_daemon_info(node_ref):
    f = _daemon_info_file(node_ref)
    if f.exists():
        f.unlink(missing_ok=True)


# ============================================================================
# Socket 通信协议（4 字节大端长度前缀 + JSON 负载）
# ============================================================================

def _recv_exactly(sock, n):
    data = b""
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise ConnectionError("连接断开")
        data += chunk
    return data


def _send_msg(sock, msg):
    payload = json.dumps(msg).encode("utf-8")
    sock.sendall(struct.pack(">I", len(payload)) + payload)


def _recv_msg(sock):
    header = _recv_exactly(sock, 4)
    length = struct.unpack(">I", header)[0]
    payload = _recv_exactly(sock, length)
    return json.loads(payload.decode("utf-8"))


# ============================================================================
# Daemon 子进程
# ============================================================================

def daemon_main(node_ref):
    """子进程入口：建立 Paramiko 长连接，监听本地端口，处理请求。"""
    node = resolve_node(node_ref)
    port = node["port"]

    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(
        hostname=node["host"],
        port=node["port"],
        username=node["username"],
        password=node["password"],
        timeout=30,
    )

    # 监听随机端口
    server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server_sock.bind(("127.0.0.1", 0))
    server_sock.listen(5)
    listen_port = server_sock.getsockname()[1]
    write_daemon_info(node_ref, os.getpid(), listen_port)

    last_activity = time.time()

    def heartbeat():
        nonlocal last_activity
        while True:
            time.sleep(HEARTBEAT_INTERVAL)
            try:
                transport = client.get_transport()
                if transport and transport.is_active():
                    transport.send_ignore()
                    if time.time() - last_activity > IDLE_TIMEOUT:
                        server_sock.close()
                        client.close()
                        remove_daemon_info(node_ref)
                        os._exit(0)
                else:
                    # 尝试重连
                    for attempt in range(MAX_RECONNECT):
                        try:
                            client.connect(
                                hostname=node["host"],
                                port=port,
                                username=node["username"],
                                password=node["password"],
                                timeout=30,
                            )
                            break
                        except Exception:
                            if attempt == MAX_RECONNECT - 1:
                                remove_daemon_info(node_ref)
                                os._exit(1)
                            time.sleep(5)
            except Exception:
                pass

    hb = Thread(target=heartbeat, daemon=True)
    hb.start()

    try:
        while True:
            server_sock.settimeout(IDLE_TIMEOUT)
            try:
                conn, _ = server_sock.accept()
            except socket.timeout:
                server_sock.close()
                client.close()
                remove_daemon_info(node_ref)
                os._exit(0)

            last_activity = time.time()
            try:
                msg = _recv_msg(conn)
            except Exception:
                conn.close()
                continue

            action = msg.get("action", "")
            resp = {"success": False, "stdout": "", "stderr": "", "exit_code": -1}

            if action == "execute":
                cmd = msg.get("command", "")
                try:
                    _, stdout, stderr = client.exec_command(cmd, timeout=msg.get("timeout", 120))
                    resp["stdout"] = stdout.read().decode("utf-8", errors="replace")
                    resp["stderr"] = stderr.read().decode("utf-8", errors="replace")
                    resp["exit_code"] = stdout.channel.recv_exit_status()
                    resp["success"] = True
                except Exception as e:
                    resp["stderr"] = str(e)

            elif action == "upload":
                try:
                    sftp = client.open_sftp()
                    sftp.put(msg["local_path"], msg["remote_path"])
                    sftp.close()
                    resp["success"] = True
                except Exception as e:
                    resp["stderr"] = str(e)

            elif action == "download":
                try:
                    sftp = client.open_sftp()
                    sftp.get(msg["remote_path"], msg["local_path"])
                    sftp.close()
                    resp["success"] = True
                except Exception as e:
                    resp["stderr"] = str(e)

            elif action == "shutdown":
                resp["success"] = True
                _send_msg(conn, resp)
                conn.close()
                server_sock.close()
                client.close()
                remove_daemon_info(node_ref)
                os._exit(0)

            else:
                resp["stderr"] = f"未知 action: {action}"

            try:
                _send_msg(conn, resp)
            except Exception:
                pass
            finally:
                conn.close()

    except KeyboardInterrupt:
        pass
    finally:
        try:
            server_sock.close()
        except Exception:
            pass
        try:
            client.close()
        except Exception:
            pass
        remove_daemon_info(node_ref)


# ============================================================================
# Daemon 管理
# ============================================================================

def start_daemon(node_ref):
    """启动 daemon 子进程并等待就绪。"""
    pid = os.fork()
    if pid == 0:
        # 子进程
        os.setsid()
        daemon_main(node_ref)
        os._exit(0)
    else:
        # 父进程等待 daemon 就绪
        for _ in range(30):
            info = read_daemon_info(node_ref)
            if info and info.get("pid"):
                time.sleep(0.2)
                return
            time.sleep(0.5)
        die("daemon 启动超时")


def ensure_daemon(node_ref):
    """确保 daemon 进程存活，否则启动。"""
    info = read_daemon_info(node_ref)
    if info:
        pid = info.get("pid", 0)
        try:
            os.kill(pid, 0)
            return  # 存活
        except OSError:
            remove_daemon_info(node_ref)
    start_daemon(node_ref)


def stop_daemon(node_ref):
    """发送 shutdown 信号关闭 daemon。"""
    info = read_daemon_info(node_ref)
    if not info:
        print_json({"success": True, "message": "daemon 未运行"})
        return
    try:
        sock = socket.create_connection(("127.0.0.1", info["port"]), timeout=5)
        _send_msg(sock, {"action": "shutdown"})
        resp = _recv_msg(sock)
        sock.close()
        print_json({"success": resp.get("success", False), "message": "daemon 已关闭"})
    except Exception as e:
        # 强制清理
        try:
            os.kill(info["pid"], signal.SIGTERM)
        except OSError:
            pass
        remove_daemon_info(node_ref)
        print_json({"success": True, "message": f"daemon 强制终止: {e}"})


def daemon_status(node_ref):
    info = read_daemon_info(node_ref)
    if not info:
        print_json({"running": False, "message": "daemon 未运行"})
        return
    pid = info.get("pid", 0)
    try:
        os.kill(pid, 0)
        print_json({"running": True, "pid": pid, "port": info.get("port")})
    except OSError:
        remove_daemon_info(node_ref)
        print_json({"running": False, "message": "daemon 已退出"})


# ============================================================================
# 远程操作接口
# ============================================================================

def exec_command(node_ref, command, timeout=600):
    """通过 daemon 执行远程命令。"""
    ensure_daemon(node_ref)
    info = read_daemon_info(node_ref)
    if not info:
        die("无法获取 daemon 信息")

    sock = socket.create_connection(("127.0.0.1", info["port"]), timeout=30)
    sock.settimeout(timeout + 300)  # 等待命令完成 + 额外缓冲
    try:
        _send_msg(sock, {"action": "execute", "command": command, "timeout": timeout})
        resp = _recv_msg(sock)
        return resp
    finally:
        sock.close()


def upload_file(node_ref, local_path, remote_path):
    """上传文件到远程节点。"""
    ensure_daemon(node_ref)
    info = read_daemon_info(node_ref)
    sock = socket.create_connection(("127.0.0.1", info["port"]), timeout=30)
    try:
        _send_msg(sock, {"action": "upload", "local_path": local_path, "remote_path": remote_path})
        return _recv_msg(sock)
    finally:
        sock.close()


def download_file(node_ref, remote_path, local_path):
    """从远程节点下载文件。"""
    ensure_daemon(node_ref)
    info = read_daemon_info(node_ref)
    sock = socket.create_connection(("127.0.0.1", info["port"]), timeout=30)
    try:
        _send_msg(sock, {"action": "download", "remote_path": remote_path, "local_path": local_path})
        return _recv_msg(sock)
    finally:
        sock.close()


def wait_for_keyword(node_ref, log_file, keyword, interval=30, timeout=3600):
    """轮询远程日志文件，等待关键词出现或超时。

    返回 {"matched": true/false, "line": "匹配行", "elapsed": 秒数}
    """
    started = time.time()
    while True:
        elapsed = time.time() - started
        if elapsed > timeout:
            return {"success": True, "matched": False, "line": "", "elapsed": elapsed}

        resp = exec_command(
            node_ref,
            f"grep -m 1 '{keyword}' {log_file} 2>/dev/null || echo __NOT_FOUND__",
            timeout=60,
        )
        if resp.get("success") and "__NOT_FOUND__" not in resp.get("stdout", ""):
            line = resp["stdout"].strip()
            if line:
                return {"success": True, "matched": True, "line": line, "elapsed": elapsed}

        time.sleep(interval)


# ============================================================================
# 输出辅助
# ============================================================================

def print_json(data):
    print(json.dumps(data, ensure_ascii=False))


def die(msg):
    print_json({"success": False, "stderr": msg})
    sys.exit(1)


# ============================================================================
# CLI
# ============================================================================

def main():
    parser = argparse.ArgumentParser(description="vllm-ascend-developer SSH 工具")
    sub = parser.add_subparsers(dest="action", required=True)

    # exec
    p_exec = sub.add_parser("exec", help="执行远程命令")
    p_exec.add_argument("node_ref", help="节点引用: standalone, pd-separated.p[0], pd-separated.d[0]")
    p_exec.add_argument("command", help="要执行的命令")
    p_exec.add_argument("--timeout", type=int, default=600, help="超时秒数，默认 600（10分钟）")

    # status
    p_status = sub.add_parser("status", help="查看 daemon 状态")
    p_status.add_argument("node_ref")

    # stop
    p_stop = sub.add_parser("stop", help="停止 daemon")
    p_stop.add_argument("node_ref")

    # upload
    p_up = sub.add_parser("upload", help="上传文件")
    p_up.add_argument("node_ref")
    p_up.add_argument("local_path")
    p_up.add_argument("remote_path")

    # download
    p_down = sub.add_parser("download", help="下载文件")
    p_down.add_argument("node_ref")
    p_down.add_argument("remote_path")
    p_down.add_argument("local_path")

    # wait
    p_wait = sub.add_parser("wait", help="轮询日志等关键词")
    p_wait.add_argument("node_ref")
    p_wait.add_argument("log_file", help="远程日志文件路径")
    p_wait.add_argument("keyword", help="完成关键词")
    p_wait.add_argument("--interval", type=int, default=30, help="轮询间隔秒数，默认 30")
    p_wait.add_argument("--timeout", type=int, default=3600, help="最大等待秒数，默认 3600")

    args = parser.parse_args()

    if args.action == "exec":
        print_json(exec_command(args.node_ref, args.command, args.timeout))
    elif args.action == "status":
        daemon_status(args.node_ref)
    elif args.action == "stop":
        stop_daemon(args.node_ref)
    elif args.action == "upload":
        print_json(upload_file(args.node_ref, args.local_path, args.remote_path))
    elif args.action == "download":
        print_json(download_file(args.node_ref, args.remote_path, args.local_path))
    elif args.action == "wait":
        print_json(wait_for_keyword(args.node_ref, args.log_file, args.keyword, args.interval, args.timeout))


if __name__ == "__main__":
    main()
