# NAS WebUI

在软路由 / 小主机（OpenWrt、iStoreOS、任何有 Docker 的 Linux）上用 Docker 跑的一个**极简** NAS 文件页面，只做三件事：

- **查看** 目录列表、图片 / 视频 / 音频 / PDF / 文本在线预览
- **下载** 任意文件（支持断点续传、视频拖动进度条）
- **上传** 文件或**整个文件夹**（拖拽或按钮选择，自动重建子目录结构，显示进度，可取消）

没有账号体系、没有增删改、没有重命名、没有删除、没有分享链接、没有缩略图生成、没有后台任务、没有数据库、没有 npm 构建、没有第三方 Python 依赖 —— 一个 `server.py` 加三份静态文件就是全部，整个镜像 60MB 左右。

> 只暴露你指定的那一个目录，手机相册、路由器上别的数据都不会出现在页面上。
> 外网访问是**可选项**：不配域名就只在局域网用，功能完全一样。

---

## 1. 目录结构

```
.
├─ server.py                 # 全部后端逻辑（纯 Python 标准库）
├─ public/
│  ├─ index.html
│  └─ assets/
│     ├─ style.css
│     └─ app.js
├─ Dockerfile
├─ docker-compose.yml        # 手动部署用
├─ .env.example              # 复制成 .env 再改
├─ deploy/
│  ├─ install-nas.sh         # 路由器上一键部署（构建 + 启动 + 防火墙 + 自检）
│  └─ deploy.ps1             # 从 Windows 上传并远程执行上面的脚本
├─ certs/                    # 放 origin.crt / origin.key（可选，已 gitignore）
├─ .dockerignore
└─ LICENSE
```

---

## 2. 部署

### 方式 A：docker compose（任何 Linux 都行）

```sh
cp .env.example .env
# 编辑 .env：至少改 NAS_PASSWORD 和 NAS_HOST_DIR（要被管理的那块盘/目录）
docker compose up -d --build
```

打开 `http://<主机IP>:8100/`，输入 `.env` 里的密码即可。

### 方式 B：路由器上一键脚本（OpenWrt / iStoreOS）

把整个项目目录拷到路由器（`scp -r` 或 SMB 都行），然后：

```sh
cd nasui
NAS_PASSWORD='你的密码' sh deploy/install-nas.sh              # 只局域网
NAS_PASSWORD='你的密码' sh deploy/install-nas.sh --allow-wan   # 顺手放行 WAN 上的 HTTPS 端口
```

脚本会：检查 root / Docker → 自动挑 `/mnt` 下空间最大的盘建 `nas` 目录 → 找证书 → 查端口占用 → 拉镜像（拉不到自动换国内源重试）→ 起容器 → 30 秒健康自检 → 放行防火墙。

常用覆盖变量（都可以 `VAR=值 sh deploy/install-nas.sh`）：

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `NAS_SHARE_DIR` | 自动挑 `/mnt` 下最大的盘 | 该盘下的 `nas` 子目录会被管理 |
| `NAS_PORT` | `8100` | 局域网 HTTP 端口 |
| `NAS_TLS_PORT` | `8453` | HTTPS 端口（给 Cloudflare 回源用） |
| `NAS_MAX_UPLOAD_MB` | `0` | 单文件上限，0 = 不限 |
| `NAS_PUBLIC_HOST` | 空 | 你的域名，只影响最后打印的地址 |

### 方式 C：从 Windows 一键推到路由器

需要 Python + `paramiko`（`pip install paramiko`）和路由器 root 密码：

```powershell
cd <本项目目录>
$env:NAS_HOST = "192.168.1.1"          # 路由器地址
powershell -ExecutionPolicy Bypass -File .\deploy\deploy.ps1
```

脚本会 SFTP 上传代码 → 远程 `sh -n` 校验 → 执行 `install-nas.sh` → curl 自检 → 生成并告诉你网站登录密码。
可用环境变量：`NAS_SSH_PORT`、`NAS_REMOTE_DIR`（默认 `/root/nasui`）、`NAS_PORT`、`NAS_TLS_PORT`、`NAS_WEB_PASSWORD`、`NAS_PYTHON`。

---

## 3. 外网访问（可选）

局域网用着就够了的话，**这一节可以整段跳过**。

想在外面也能下载/上传，推荐套 Cloudflare（免费版够用），因为证书、HTTPS、隐藏真实 IP 都由它负责：

1. **证书**：弄一张覆盖你域名的证书（Cloudflare Origin CA 免费签发 15 年），把 `origin.crt` / `origin.key` 放进项目下的 `certs/` 目录，重跑部署脚本。没有证书时容器只开 HTTP。
2. **DNS**：在 Cloudflare 给这个域名加一条记录指向家里公网 IP，**代理必须开启**（橙色云朵）。
3. **Rules → Origin Rules**：`Hostname = 你的域名` → 目标端口 `8453`。
4. **SSL/TLS** 设 `Full (strict)`，打开 `Always Use HTTPS`。
5. 路由器上放行 WAN 入站 `8453`（`install-nas.sh --allow-wan` 会自动加防火墙规则）。

这样 Cloudflare 到源站这一段也是加密的，cookie 会自动带 `Secure`，页面启动时也会提示当前是 HTTPS。

> 不想用 Cloudflare 也可以：任何反向代理（Nginx / Caddy / frp / Tailscale）指向 `8100` 都行，只是**别把明文 8100 直接暴露到公网**。

---

## 4. 配置项（全部是环境变量）

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `NAS_ROOT` | `/data` | 被管理的根目录，页面只能看到它下面 |
| `NAS_PASSWORD` | 空（必填） | 登录密码，只存在内存里 |
| `NAS_PORT` | `8100` | HTTP 端口（容器内固定 8100，宿主机端口可变） |
| `NAS_TLS_PORT` | `8453` | HTTPS 端口（容器内固定 8453） |
| `NAS_TLS_CERT` | `certs/origin.crt` | 证书路径，文件不存在就不启用 HTTPS |
| `NAS_TLS_KEY` | `certs/origin.key` | 私钥路径 |
| `NAS_MAX_UPLOAD_MB` | `0` | 单文件上限（MB），`0` = 不限；磁盘不够返回 507 |
| `NAS_PUBLIC_HOST` | 空 | 只用于启动日志里显示的地址 |

想改密码：改 `NAS_PASSWORD` 后 `docker restart nasui`（或重跑 `install-nas.sh`），数据目录不受影响。

---

## 5. 数据目录

默认管理宿主上的 `<数据盘>/nas`，容器内挂到 `/data`：

```yaml
volumes:
  - "/你的路径/nas:/data"      # 只有这个子目录可见
```

- 容器以 root 运行，上传文件属主是 root。若改成非 root 运行，需要把宿主目录属主改成对应 uid。
- 容量就是那块盘的剩余空间，页面上会显示剩余空间，写满时返回 507。
- 想换目录：改 `NAS_HOST_DIR`（compose）或 `NAS_SHARE_DIR`（install-nas.sh），容器重建即可，旧文件还在原处。

---

## 6. 常用运维命令

```sh
docker logs -f nasui          # 看日志（每次上传/下载都会记一行来源 IP）
docker restart nasui          # 重启
docker rm -f nasui            # 删除容器（数据目录不动）
docker stats nasui            # 资源占用
```

升级代码：把新代码同步到项目目录后重跑 `install-nas.sh`，镜像会重新构建，数据不动。

---

## 7. 安全设计（为什么敢开外网）

- 登录后拿到签名 cookie：`HMAC-SHA256(密钥, 过期时间)`，密钥每次启动随机生成 → **重启即全员重新登录**；cookie 是 `HttpOnly; SameSite=Strict`，HTTPS 下再加 `Secure`。
- 密码用 PBKDF2-HMAC-SHA256（20 万轮）比对，密码本身只在内存里，不落盘、不进日志。
- 登录失败 5 次 / 5 分钟就锁该 IP 5 分钟（优先按 Cloudflare 传来的真实 IP 计数）。
- 所有路径先 `resolve()` 再校验是否仍在 `NAS_ROOT` 内，`..`、绝对路径、符号链接逃逸一律 403。
- 上传文件名会被清洗（去掉 `/` `\`、控制字符、首尾点），同名自动变成 `xxx (1).ext`，**永不覆盖**已有文件。
- 文件名在页面上一律用 `textContent` 渲染，不会执行 HTML/JS。
- 公网只放行有证书的那条端口，明文 HTTP 仍只限局域网。

> 仍然建议：① 用足够长的随机密码；② 只在 Cloudflare 代理或 VPN 后面暴露，不要直接把 HTTPS 端口裸奔到公网。

---

## 8. 已知限制（这是设计取舍，不是 bug）

- 上传是**单次 HTTP 请求**，没有分片续传：网络断了就得重传。
- 上传文件夹时，**空文件夹不会被创建**（只有含文件的目录才会在服务器上出现）。
- 一次拖入上千个文件时，右下角进度队列只显示前 300 行，其余照常上传，结束时汇总成功/失败数量。
- 文件夹拖拽依赖浏览器的 `webkitGetAsEntry`（Chrome / Edge / Firefox 均支持）；Safari 请用「上传文件夹」按钮。
- 经过 Cloudflare 代理时：免费版**单次请求体上限 100MB**、上传超过 **100 秒**会被回 524。大文件请走局域网。
- 列表不带虚拟滚动，一个目录里超过约 2000 个文件时页面会变慢（但不崩）。
- 预览只支持浏览器原生能解的格式；文本预览最多读 512KB。
- 没有搜索、没有自定义排序（固定目录在前、名称排序）、没有回收站。

---

## 9. 本地调试（不上服务器）

```sh
NAS_ROOT=/tmp/nas-test NAS_PASSWORD=test123 NAS_PORT=8100 python3 server.py
# Windows:
# $env:NAS_ROOT="D:\tmp\nas-test"; $env:NAS_PASSWORD="test123"; python server.py
```

浏览器打开 `http://127.0.0.1:8100/` 即可。接口是普通的 JSON + 裸字节流，`curl` 就能测：

```sh
curl -c jar -X POST -d '{"password":"test123"}' http://127.0.0.1:8100/api/login
curl -b jar 'http://127.0.0.1:8100/api/list?path='
curl -b jar 'http://127.0.0.1:8100/api/raw?path=some/file.txt&download=1' -o file.txt
```

---

## 10. 出问题怎么查

| 现象 | 处理 |
| --- | --- |
| 页面打不开 | `docker ps` 看容器是否 Up；`docker logs nasui` 看是否提示 `NAS_PASSWORD 未设置` |
| 登录一直失败 | 确认 `NAS_PASSWORD` 和输入一致；连续错 5 次会锁 5 分钟，等一会儿 |
| 上传 413 | 超过 `NAS_MAX_UPLOAD_MB`；设为 0 可关闭限制 |
| 上传 507 | 磁盘满了 |
| 上传文件夹报网络错误 | 浏览器太旧不支持 `webkitGetAsEntry`，改用「上传文件夹」按钮 |
| 外网 502 / 521 | Cloudflare 源规则端口不是 HTTPS 端口，或 WAN 没放行 |
| 外网 526 / 525 | 证书与域名不匹配（证书要覆盖你实际访问的域名） |
| 视频不能拖动 | 需走 HTTPS 或局域网直连；Cloudflare 会缓存 Range 但首段要回源 |

---

## 许可证

[MIT](LICENSE)
