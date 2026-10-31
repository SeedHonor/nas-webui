#!/usr/bin/env python3
"""NAS 文件管理 · 极简 WebUI（上传 / 下载 / 查看）

设计约束
  * 只依赖 Python 3.10+ 标准库，单文件即可运行，无第三方依赖
  * 只提供三种操作：浏览目录、下载/预览文件、上传文件
    —— 没有删除、重命名、移动、新建目录、分享、搜索
  * 内存占用恒定：上传、下载全部按 CHUNK 流式处理（软路由只有 4G 内存）

启动示例
    NAS_ROOT=/data NAS_PASSWORD='xxx' python server.py
    python server.py --root D:\\nas-test --port 8100 --no-tls
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import mimetypes
import os
import re
import secrets
import signal
import socket
import sys
import threading
import time
import traceback
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
PUBLIC_DIR = BASE_DIR / "public"
ASSETS_DIR = PUBLIC_DIR / "assets"

CHUNK = 1024 * 1024          # 流式读写块大小
SESSION_DAYS = 7             # 登录有效期
MAX_FAILS = 5                # 同一 IP 在窗口内允许的失败次数
FAIL_WINDOW = 300            # 失败计数窗口（秒）
COOKIE_NAME = "nassid"
NAME_MAX = 200               # 上传文件名最大长度
MAX_DEPTH = 32               # 上传目标目录最大层级
FREE_MARGIN = 1.2            # 剩余空间必须 > 文件大小 * 该系数

# 让 .mimetypes 认识常见类型（不同系统 /etc/mime.types 差异较大）
MYTYPES = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".svg": "image/svg+xml",
    ".ico": "image/x-icon",
    ".webp": "image/webp",
    ".avif": "image/avif",
    ".heic": "image/heic",
    ".mkv": "video/x-matroska",
    ".flac": "audio/flac",
    ".m4a": "audio/mp4",
    ".opus": "audio/ogg",
    ".md": "text/plain; charset=utf-8",
    ".log": "text/plain; charset=utf-8",
    ".conf": "text/plain; charset=utf-8",
    ".ini": "text/plain; charset=utf-8",
}
TEXT_EXT = {
    ".txt", ".md", ".markdown", ".log", ".csv", ".tsv", ".json", ".yaml", ".yml",
    ".toml", ".ini", ".conf", ".cfg", ".xml", ".html", ".htm", ".css", ".js",
    ".py", ".sh", ".bat", ".ps1", ".c", ".h", ".cpp", ".java", ".go", ".rs",
    ".sql", ".env", ".srt", ".ass", ".nfo",
}
# 可以在浏览器里直接预览的类型（其余一律强制下载）
INLINE_TYPES = {
    "image/jpeg", "image/png", "image/gif", "image/webp", "image/svg+xml",
    "image/bmp", "image/avif", "image/x-icon",
    "video/mp4", "video/webm", "video/x-matroska", "video/quicktime", "video/ogg",
    "audio/mpeg", "audio/flac", "audio/wav", "audio/ogg", "audio/mp4", "audio/x-wav",
    "application/pdf",
    "text/plain; charset=utf-8",
}
NO_CACHE = {"Cache-Control": "no-cache, must-revalidate"}


# --------------------------------------------------------------------------- 配置
class Settings:
    def __init__(self, root, host, port, tls_port, cert, key, password,
                 max_upload_mb, public_host, quiet):
        self.root = Path(root).resolve()
        self.host = host
        self.port = port
        self.tls_port = tls_port
        self.cert = cert
        self.key = key
        self.password = password
        self.max_upload_mb = max_upload_mb
        self.max_upload = max_upload_mb * 1024 * 1024 if max_upload_mb else 0
        self.public_host = public_host
        self.quiet = quiet
        # 密码只以哈希形式留在内存
        self.pw_salt = secrets.token_bytes(16)
        self.pw_hash = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), self.pw_salt, 200_000)


CFG: Settings = None  # type: ignore[assignment]
SECRET = secrets.token_bytes(32)   # 进程级会话密钥，重启即失效


# --------------------------------------------------------------------------- 工具
class HttpError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


def clean_rel(value):
    """把 URL 里的相对路径拆成安全的分段（拒绝 .. 与 NUL）。"""
    if value is None:
        value = ""
    if "\x00" in value:
        raise HttpError(403, "路径非法")
    seps = ("/",) if os.sep == "/" else ("/", "\\")
    for sep in seps:
        value = value.replace(sep, "/")
    parts = [p for p in value.split("/") if p not in ("", ".")]
    if any(p == ".." for p in parts):
        raise HttpError(403, "禁止访问")
    return parts


def safe_path(rel):
    """把相对路径解析为绝对路径，并保证不越出根目录（符号链接也挡）。"""
    parts = clean_rel(rel)
    target = CFG.root.joinpath(*parts) if parts else CFG.root
    try:
        real = target.resolve()
    except (OSError, RuntimeError):
        raise HttpError(404, "路径不存在")
    try:
        real.relative_to(CFG.root)
    except ValueError:
        raise HttpError(403, "禁止访问")
    return real


def url_path(rel_parts):
    return "/" + "/".join(rel_parts)


def clean_name(name):
    """清洗上传文件名：去掉路径分隔符与控制字符，拒绝危险名字。"""
    name = (name or "").strip()
    name = name.replace("/", "_").replace("\\", "_")
    name = "".join(ch for ch in name if ch >= " " and ch != "\x7f")
    name = name.rstrip(". ")
    if not name or name in (".", ".."):
        raise HttpError(400, "文件名非法")
    if len(name) > NAME_MAX:
        stem, dot, ext = name.rpartition(".")
        if dot and ext and len(ext) <= 16 and stem:
            name = stem[: NAME_MAX - len(ext) - 1] + "." + ext
        else:
            name = name[:NAME_MAX]
    return name


def unique_name(directory, name):
    """同名不覆盖：自动追加 (1)、(2)……"""
    if not (directory / name).exists():
        return name
    stem, dot, ext = name.rpartition(".")
    if not dot or not stem:
        stem, ext = name, ""
    else:
        ext = "." + ext
    for i in range(1, 10000):
        cand = "%s (%d)%s" % (stem, i, ext)
        if not (directory / cand).exists():
            return cand
    raise HttpError(409, "同名文件过多")


def content_type_for(path):
    suffix = path.suffix.lower()
    ctype = MYTYPES.get(suffix)
    if ctype:
        return ctype
    if suffix in TEXT_EXT:
        return "text/plain; charset=utf-8"
    guessed = mimetypes.guess_type(str(path))[0] or "application/octet-stream"
    if guessed.startswith("text/") and "charset" not in guessed:
        guessed += "; charset=utf-8"
    return guessed


def kind_for(path, is_dir):
    if is_dir:
        return "dir"
    suffix = path.suffix.lower()
    ctype = content_type_for(path)
    if ctype.startswith("image/"):
        return "image"
    if ctype.startswith("video/"):
        return "video"
    if ctype.startswith("audio/"):
        return "audio"
    if ctype.startswith("application/pdf"):
        return "pdf"
    if ctype.startswith("text/") or suffix in TEXT_EXT:
        return "text"
    return "other"


def human_size(size):
    unit = ("B", "KB", "MB", "GB", "TB")
    value = float(size)
    for name in unit:
        if value < 1024 or name == unit[-1]:
            return ("%d %s" % (value, name)) if name == "B" else ("%.1f %s" % (value, name))
        value /= 1024.0
    return "%d B" % size


def client_key(handler):
    """代理后面取真实来源，用于登录失败限流。"""
    for header in ("CF-Connecting-IP", "X-Forwarded-For"):
        value = handler.headers.get(header)
        if value:
            return value.split(",")[0].strip()
    return handler.client_address[0]


def b64e(raw):
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def b64d(text):
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def make_session():
    expires = int(time.time()) + SESSION_DAYS * 86400
    payload = str(expires).encode("ascii")
    sig = hmac.new(SECRET, payload, hashlib.sha256).hexdigest()
    return "%s.%s" % (b64e(payload), sig)


def read_session(token):
    if not token or "." not in token:
        return False
    payload_b64, _, sig = token.rpartition(".")
    try:
        payload = b64d(payload_b64)
        expires = int(payload.decode("ascii"))
    except Exception:  # noqa: BLE001
        return False
    expect = hmac.new(SECRET, payload, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expect, sig):
        return False
    return expires > int(time.time())


# --------------------------------------------------------------------------- 限流
class FailCounter:
    def __init__(self):
        self.lock = threading.Lock()
        self.data = {}

    def blocked(self, key):
        now = time.time()
        with self.lock:
            hits = [t for t in self.data.get(key, []) if now - t < FAIL_WINDOW]
            self.data[key] = hits
            return len(hits) >= MAX_FAILS

    def add(self, key):
        now = time.time()
        with self.lock:
            hits = [t for t in self.data.get(key, []) if now - t < FAIL_WINDOW]
            hits.append(now)
            self.data[key] = hits

    def okay(self, key):
        with self.lock:
            self.data.pop(key, None)


FAILS = FailCounter()


# --------------------------------------------------------------------------- 处理器
class Handler(BaseHTTPRequestHandler):
    server_version = "NASUI/1.0"
    protocol_version = "HTTP/1.1"
    timeout = 120  # 单次读的超时，慢速 WiFi 上传不会被误杀

    # ---------------------------------------------------------------- 日志
    def log_message(self, fmt, *args):
        if CFG.quiet:
            return
        sys.stdout.write("  %s  %s  %s\n" % (time.strftime("%H:%M:%S"), self.client_address[0], fmt % args))
        sys.stdout.flush()

    # ---------------------------------------------------------------- 入口
    def do_GET(self):
        self._run()

    def do_HEAD(self):
        self._run()

    def do_POST(self):
        self._run()

    def _run(self):
        try:
            self._dispatch()
        except HttpError as exc:
            self._json({"ok": False, "error": exc.message}, exc.status)
        except (BrokenPipeError, ConnectionResetError):
            return
        except Exception:  # noqa: BLE001
            traceback.print_exc()
            try:
                self._json({"ok": False, "error": "服务器内部错误"}, 500)
            except Exception:  # noqa: BLE001
                pass

    # ---------------------------------------------------------------- 路由
    def _dispatch(self):
        parsed = urllib.parse.urlsplit(self.path)
        path = urllib.parse.unquote(parsed.path)
        query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
        method = self.command

        authed = read_session(self._cookie(COOKIE_NAME))

        if path == "/api/ping":
            return self._json({"ok": True, "authenticated": authed})

        if path == "/api/session":
            return self._json({
                "ok": True,
                "authenticated": authed,
                "root_name": CFG.root.name or "/",
                "max_upload_mb": CFG.max_upload_mb,
            })

        if path == "/api/login":
            if method != "POST":
                raise HttpError(405, "方法不允许")
            return self._login()

        if path == "/api/logout":
            return self._logout()

        if path.startswith("/api/"):
            if not authed:
                raise HttpError(401, "未登录")
            if path == "/api/list":
                return self._list(query)
            if path == "/api/raw":
                return self._raw(query)
            if path == "/api/upload":
                if method != "POST":
                    raise HttpError(405, "方法不允许")
                return self._upload(query)
            raise HttpError(404, "接口不存在")

        # ---- 页面与静态资源
        if method not in ("GET", "HEAD"):
            raise HttpError(405, "方法不允许")
        if path == "/" or path == "/index.html":
            return self._serve_file(PUBLIC_DIR / "index.html", "text/html; charset=utf-8", NO_CACHE)
        if path.startswith("/assets/"):
            rel = clean_rel(path[len("/assets/"):])
            target = ASSETS_DIR.joinpath(*rel).resolve()
            try:
                target.relative_to(ASSETS_DIR)
            except ValueError:
                raise HttpError(403, "禁止访问")
            if not target.is_file():
                raise HttpError(404, "资源不存在")
            return self._serve_file(target, content_type_for(target), {"Cache-Control": "public, max-age=600"})
        raise HttpError(404, "页面不存在")

    # ---------------------------------------------------------------- 响应
    def _cookie(self, name):
        raw = self.headers.get("Cookie") or ""
        for item in raw.split(";"):
            key, _, value = item.strip().partition("=")
            if key == name:
                return value
        return ""

    def _send(self, status, body=b"", ctype="application/json; charset=utf-8", headers=None):
        head = {"Content-Type": ctype, "Content-Length": str(len(body))}
        head.update(headers or {})
        self.send_response(status)
        self.send_header("Server", self.server_version)
        self.send_header("X-Content-Type-Options", "nosniff")
        head.setdefault("Cache-Control", "no-store")
        for key, value in head.items():
            self.send_header(key, str(value))
        self.end_headers()
        if self.command != "HEAD" and body:
            self.wfile.write(body)

    def _json(self, payload, status=200):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self._send(status, body, "application/json; charset=utf-8")

    def _serve_file(self, target, ctype, headers):
        try:
            body = target.read_bytes()
        except OSError:
            raise HttpError(404, "文件不存在")
        self._send(200, body, ctype, headers)

    # ---------------------------------------------------------------- 登录
    def _read_json(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if length <= 0 or length > 64 * 1024:
            raise HttpError(400, "请求体非法")
        raw = self.rfile.read(length)
        try:
            data = json.loads(raw.decode("utf-8"))
        except Exception:  # noqa: BLE001
            raise HttpError(400, "JSON 解析失败")
        if not isinstance(data, dict):
            raise HttpError(400, "请求体非法")
        return data

    def _login(self):
        key = client_key(self)
        if FAILS.blocked(key):
            raise HttpError(429, "失败次数过多，请 5 分钟后再试")
        data = self._read_json()
        password = str(data.get("password") or "")
        digest = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), CFG.pw_salt, 200_000)
        if not hmac.compare_digest(digest, CFG.pw_hash):
            FAILS.add(key)
            raise HttpError(401, "密码错误")
        FAILS.okay(key)
        cookie = "%s=%s; Path=/; Max-Age=%d; HttpOnly; SameSite=Strict" % (
            COOKIE_NAME, make_session(), SESSION_DAYS * 86400)
        if (self.headers.get("X-Forwarded-Proto") or "").lower() == "https":
            cookie += "; Secure"
        self._send(200, json.dumps({"ok": True}, ensure_ascii=False).encode("utf-8"),
                   "application/json; charset=utf-8", {"Set-Cookie": cookie})

    def _logout(self):
        cookie = "%s=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict" % COOKIE_NAME
        self._send(200, json.dumps({"ok": True}).encode("utf-8"),
                   "application/json; charset=utf-8", {"Set-Cookie": cookie})

    # ---------------------------------------------------------------- 列表
    def _list(self, query):
        rel = (query.get("path") or [""])[0]
        target = safe_path(rel)
        if not target.is_dir():
            raise HttpError(404, "目录不存在")
        entries = []
        try:
            with os.scandir(target) as iterator:
                for entry in iterator:
                    try:
                        is_dir = entry.is_dir(follow_symlinks=True)
                        stat = entry.stat(follow_symlinks=False)
                    except OSError:
                        continue
                    entries.append({
                        "name": entry.name,
                        "is_dir": is_dir,
                        "is_link": entry.is_symlink(),
                        "size": 0 if is_dir else int(stat.st_size),
                        "mtime": int(stat.st_mtime),
                        "kind": kind_for(target / entry.name, is_dir),
                    })
        except PermissionError:
            raise HttpError(403, "没有权限读取该目录")
        except OSError as exc:
            raise HttpError(500, "读取目录失败：%s" % exc)
        entries.sort(key=lambda item: (not item["is_dir"], item["name"].casefold()))
        parts = clean_rel(rel)
        self._json({
            "ok": True,
            "path": url_path(parts),
            "parts": parts,
            "parent": url_path(parts[:-1]),
            "entries": entries,
        })

    # ---------------------------------------------------------------- 下载 / 预览
    def _raw(self, query):
        rel = (query.get("path") or [""])[0]
        download = (query.get("download") or ["0"])[0] in ("1", "true", "yes")
        target = safe_path(rel)
        if not target.is_file():
            raise HttpError(404, "文件不存在")
        try:
            size = target.stat().st_size
        except OSError:
            raise HttpError(404, "文件不存在")

        ctype = content_type_for(target)
        inline = ctype in INLINE_TYPES and not download
        if not inline:
            ctype = "application/octet-stream"

        headers = {"Content-Type": ctype, "Accept-Ranges": "bytes",
                   "Cache-Control": "private, max-age=30"}
        if inline:
            headers["Content-Disposition"] = "inline"
        else:
            ascii_name = re.sub(r"[^A-Za-z0-9._-]+", "_", target.name) or "download"
            headers["Content-Disposition"] = "attachment; filename=\"%s\"; filename*=UTF-8''%s" % (
                ascii_name, urllib.parse.quote(target.name, safe=""))

        start, end, partial = 0, size - 1, False
        range_header = self.headers.get("Range") or ""
        if range_header.startswith("bytes=") and size > 0:
            spec = range_header[6:].split(",")[0].strip()
            first, _, second = spec.partition("-")
            try:
                if first == "":
                    suffix = int(second)
                    if suffix <= 0:
                        raise ValueError
                    start = max(0, size - suffix)
                    end = size - 1
                else:
                    start = int(first)
                    end = int(second) if second else size - 1
                if start < 0 or start > end:
                    raise ValueError
                end = min(end, size - 1)
                partial = True
            except ValueError:
                self._send(416, b"", "text/plain; charset=utf-8",
                           {"Content-Range": "bytes */%d" % size})
                return

        length = end - start + 1 if size > 0 else 0
        status = 206 if partial else 200
        if partial:
            headers["Content-Range"] = "bytes %d-%d/%d" % (start, end, size)
        headers["Content-Length"] = str(length)

        self.send_response(status)
        self.send_header("Server", self.server_version)
        self.send_header("X-Content-Type-Options", "nosniff")
        for key, value in headers.items():
            self.send_header(key, str(value))
        self.end_headers()
        if self.command == "HEAD" or length <= 0:
            return
        try:
            with open(target, "rb") as handle:
                handle.seek(start)
                remaining = length
                while remaining > 0:
                    block = handle.read(min(CHUNK, remaining))
                    if not block:
                        break
                    self.wfile.write(block)
                    remaining -= len(block)
        except (BrokenPipeError, ConnectionResetError):
            return

    # ---------------------------------------------------------------- 上传
    def _upload(self, query):
        rel = (query.get("path") or [""])[0]
        parts = clean_rel(rel)
        if len(parts) > MAX_DEPTH:
            raise HttpError(400, "目录层级过深")
        directory = safe_path(rel)
        if not directory.is_dir():
            if directory.exists():
                raise HttpError(400, "目标路径是一个文件，不能作为上传目录")
            try:  # 文件夹上传：按需逐层建目录（safe_path 已确认落在根目录内）
                directory.mkdir(parents=True, exist_ok=True)
            except OSError as exc:
                raise HttpError(500, "创建目录失败：%s" % exc)
        name = clean_name((query.get("name") or [""])[0])

        try:
            length = int(self.headers.get("Content-Length") or -1)
        except ValueError:
            length = -1
        if length < 0:
            raise HttpError(411, "缺少 Content-Length")
        if CFG.max_upload and length > CFG.max_upload:
            raise HttpError(413, "超过单文件上限 %d MB" % CFG.max_upload_mb)

        try:
            stats = os.statvfs(str(directory))
            free = stats.f_bavail * stats.f_frsize
        except (AttributeError, OSError):
            free = None  # Windows 本地调试没有 statvfs
        if free is not None and length > 0 and free < length * FREE_MARGIN:
            raise HttpError(507, "磁盘剩余空间不足")

        final_name = unique_name(directory, name)
        final_path = directory / final_name
        temp = directory / (".upload-%s.part" % secrets.token_hex(8))
        written = 0
        try:
            with open(temp, "wb") as handle:
                remaining = length
                while remaining > 0:
                    block = self.rfile.read(min(CHUNK, remaining))
                    if not block:
                        raise HttpError(400, "上传中断")
                    handle.write(block)
                    remaining -= len(block)
                    written += len(block)
            if final_path.exists():  # 极小概率的并发同名，换一个
                final_name = unique_name(directory, name)
                final_path = directory / final_name
            os.replace(str(temp), str(final_path))
        except HttpError:
            self._cleanup(temp)
            raise
        except OSError as exc:
            self._cleanup(temp)
            raise HttpError(500, "写入失败：%s" % exc)

        self._json({"ok": True, "name": final_name, "size": written})

    @staticmethod
    def _cleanup(path):
        try:
            path.unlink()
        except OSError:
            pass


# --------------------------------------------------------------------------- 服务器
class NasServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def make_server(host, port, family, v6only):
    class Server(NasServer):
        address_family = family

        def server_bind(self):
            if v6only is not None:
                try:
                    self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, v6only)
                except OSError:
                    pass
            super().server_bind()

    return Server((host, port), Handler)


def wrap_tls(instance, certfile, keyfile):
    import ssl

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certfile, keyfile)
    instance.socket = context.wrap_socket(instance.socket, server_side=True)
    return instance


def build_servers(host, port, tls=None):
    servers = []
    if host in ("0.0.0.0", "::", "*"):
        try:
            servers.append(make_server("0.0.0.0", port, socket.AF_INET, None))
        except OSError as exc:
            print("  ! IPv4 端口 %d 监听失败：%s" % (port, exc))
        try:
            servers.append(make_server("::", port, socket.AF_INET6, 1))
        except OSError as exc:
            print("  ! IPv6 端口 %d 监听失败：%s" % (port, exc))
    else:
        family = socket.AF_INET6 if ":" in host else socket.AF_INET
        servers.append(make_server(host, port, family, None))
    if not servers:
        raise SystemExit("无法监听端口 %d，请检查端口是否被占用。" % port)
    if tls:
        for item in servers:
            wrap_tls(item, tls[0], tls[1])
    return servers


def local_ip():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect(("223.5.5.5", 80))
        return sock.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        sock.close()


def banner(host, lan, tls_started, tls_port):
    line = "─" * 62
    print("\n" + line)
    print("  NAS 文件管理 · 已启动（仅上传 / 下载 / 查看）")
    print(line)
    print("  本机访问 :  http://127.0.0.1:%d/" % CFG.port)
    print("  局域网   :  http://%s:%d/" % (lan, CFG.port))
    if tls_started:
        print("  HTTPS    :  https://%s:%d/  （Cloudflare Full(strict) 回源）" % (lan, tls_port))
    else:
        print("  HTTPS    :  未启用（证书缺失或 --no-tls）")
    print("  数据目录 :  %s" % CFG.root)
    if CFG.max_upload_mb:
        print("  单文件上限:  %d MB" % CFG.max_upload_mb)
    else:
        print("  单文件上限:  不限（受磁盘剩余空间约束）")
    print("  停止服务 :  Ctrl + C")
    print(line + "\n")


def parse_args():
    env = os.environ
    parser = argparse.ArgumentParser(description="NAS 文件管理 WebUI")
    parser.add_argument("--root", default=env.get("NAS_ROOT", "/data"), help="共享根目录")
    parser.add_argument("--host", default=env.get("NAS_HOST", "0.0.0.0"))
    parser.add_argument("--port", type=int, default=int(env.get("NAS_PORT", "8100")))
    parser.add_argument("--tls-port", type=int, default=int(env.get("NAS_TLS_PORT", "8453")))
    parser.add_argument("--cert", default=env.get("NAS_TLS_CERT", "certs/origin.crt"))
    parser.add_argument("--key", default=env.get("NAS_TLS_KEY", "certs/origin.key"))
    parser.add_argument("--password", default=env.get("NAS_PASSWORD", ""))
    parser.add_argument("--max-upload-mb", type=int, default=int(env.get("NAS_MAX_UPLOAD_MB", "0")))
    parser.add_argument("--public-host", default=env.get("NAS_PUBLIC_HOST", ""))
    parser.add_argument("--no-tls", action="store_true")
    parser.add_argument("--quiet", action="store_true")
    return parser.parse_args()


def main():
    global CFG
    args = parse_args()

    if not args.password:
        raise SystemExit(
            "缺少访问密码：请用环境变量 NAS_PASSWORD 提供（例如 NAS_PASSWORD='xxx' python server.py）")

    root = Path(args.root)
    if not root.is_dir():
        raise SystemExit("共享根目录不存在或不是目录：%s" % root)

    cert = Path(args.cert)
    key = Path(args.key)
    if not cert.is_absolute():
        cert = BASE_DIR / cert
    if not key.is_absolute():
        key = BASE_DIR / key

    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # noqa: BLE001
        pass

    CFG = Settings(root=root, host=args.host, port=args.port, tls_port=args.tls_port,
                   cert=str(cert), key=str(key), password=args.password,
                   max_upload_mb=args.max_upload_mb, public_host=args.public_host,
                   quiet=args.quiet)

    servers = build_servers(args.host, args.port)

    tls_started = False
    if not args.no_tls and cert.is_file() and key.is_file():
        try:
            servers += build_servers(args.host, args.tls_port, tls=(str(cert), str(key)))
            tls_started = True
        except Exception as exc:  # noqa: BLE001
            print("  ! HTTPS(%d) 监听失败：%s" % (args.tls_port, exc))
    elif not args.no_tls:
        print("  ! 未找到证书（%s / %s），本次只提供 HTTP" % (cert, key))

    lan = args.public_host or local_ip()
    banner(args.host, lan, tls_started, args.tls_port)

    stop_event = threading.Event()

    def _on_stop(signum, frame):  # noqa: ARG001
        stop_event.set()

    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            signal.signal(sig, _on_stop)
        except (ValueError, OSError, AttributeError):
            pass

    workers = []
    try:
        for item in servers:
            worker = threading.Thread(target=item.serve_forever, kwargs={"poll_interval": 0.4})
            worker.daemon = True
            worker.start()
            workers.append(worker)
        while not stop_event.is_set() and any(item.is_alive() for item in workers):
            stop_event.wait(0.5)
    except KeyboardInterrupt:
        pass
    finally:
        print("\n正在停止服务……")
        for item in servers:
            try:
                item.shutdown()
                item.server_close()
            except Exception:  # noqa: BLE001
                pass
        print("服务已停止。")


if __name__ == "__main__":
    main()
