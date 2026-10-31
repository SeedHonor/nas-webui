# NAS WebUI

跑在 Docker 里的一个 NAS 文件页面，只做查看、下载、上传，适合软路由或小主机。后端是纯 Python 标准库，前端是三个静态文件，没有数据库，也没有第三方依赖，镜像 60MB 左右。

- 查看：目录列表，图片、视频、音频、PDF、文本在线预览
- 下载：支持断点续传，视频可以拖进度条
- 上传：文件或整个文件夹，拖拽或点按钮，服务器上会自动建出对应的子目录，带进度、可取消

页面只能看到你指定的那一个目录。外网访问是可选项，不配域名就只在局域网用，功能不受影响。

---

## 部署

### 用 docker compose

任何装了 Docker 的 Linux 都可以：

```sh
cp .env.example .env
# 编辑 .env，至少要改 NAS_PASSWORD 和 NAS_HOST_DIR
docker compose up -d --build
```

打开 `http://<主机IP>:8100/`，用 `.env` 里的密码登录。

### 在 OpenWrt / iStoreOS 上跑一键脚本

把项目目录拷到路由器（`scp -r` 或 SMB 都行），然后：

```sh
cd nasui
NAS_PASSWORD='你的密码' sh deploy/install-nas.sh              # 只局域网
NAS_PASSWORD='你的密码' sh deploy/install-nas.sh --allow-wan   # 顺手放行 WAN 上的 HTTPS 端口
```

脚本依次做这些事：检查 root 和 Docker，在 `/mnt` 下挑空间最大的盘建 `nas` 目录，找证书，检查端口占用，构建镜像（拉不到会自动换国内源重试），起容器，30 秒健康自检，最后按需放行防火墙。

以下变量可以加在命令前面覆盖，例如 `NAS_PORT=8200 sh deploy/install-nas.sh`：

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `NAS_SHARE_DIR` | `/mnt` 下空间最大的盘 | 这块盘下的 `nas` 子目录会被管理 |
| `NAS_PORT` | `8100` | 局域网 HTTP 端口 |
| `NAS_TLS_PORT` | `8453` | HTTPS 端口，给 Cloudflare 回源用 |
| `NAS_MAX_UPLOAD_MB` | `0` | 单文件上限，0 表示不限 |
| `NAS_PUBLIC_HOST` | 空 | 你的域名，只影响最后打印的地址 |

### 从 Windows 推到路由器

需要 Python 和 `paramiko`（`pip install paramiko`），以及路由器的 root 密码：

```powershell
cd <本项目目录>
$env:NAS_HOST = "192.168.1.1"
powershell -ExecutionPolicy Bypass -File .\deploy\deploy.ps1
```

脚本会通过 SFTP 上传代码，远程执行 `sh -n` 校验后调用 `install-nas.sh`，再用 curl 自检，最后把网站登录密码打印出来。可用环境变量：`NAS_SSH_PORT`、`NAS_REMOTE_DIR`（默认 `/root/nasui`）、`NAS_PORT`、`NAS_TLS_PORT`、`NAS_WEB_PASSWORD`、`NAS_PYTHON`。

---

## 外网访问（可选）

局域网够用的话，这一节可以跳过。想在外面也能下载和上传，最省事的是套一层 Cloudflare 免费版，证书、HTTPS 和隐藏真实 IP 都由它负责：

1. 准备一张覆盖你域名的证书（Cloudflare Origin CA 免费签发 15 年），把 `origin.crt` 和 `origin.key` 放进项目下的 `certs/` 目录，重跑部署脚本。没有证书时容器只开 HTTP。
2. 在 Cloudflare 给这个域名加一条记录指向家里的公网 IP，代理必须开启（橙色云朵）。
3. 在 Rules → Origin Rules 里加规则：`Hostname = 你的域名`，目标端口 `8453`。
4. SSL/TLS 模式设成 `Full (strict)`，打开 `Always Use HTTPS`。
5. 路由器上放行 WAN 入站 `8453`，`install-nas.sh --allow-wan` 会自动加这条防火墙规则。

这样 Cloudflare 到源站这一段也是加密的，cookie 会自动带上 `Secure`。

不想用 Cloudflare 也行，任何反向代理（Nginx、Caddy、frp、Tailscale）指向 `8100` 都可以。只是别把明文的 8100 直接暴露到公网。

---

## 配置

全部是环境变量：

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `NAS_ROOT` | `/data` | 被管理的根目录，页面只能看到它下面 |
| `NAS_PASSWORD` | 空，必填 | 登录密码，只存在内存里 |
| `NAS_PORT` | `8100` | HTTP 端口，容器内固定 8100，宿主机端口可变 |
| `NAS_TLS_PORT` | `8453` | HTTPS 端口，容器内固定 8453 |
| `NAS_TLS_CERT` | `certs/origin.crt` | 证书路径，文件不存在就不启用 HTTPS |
| `NAS_TLS_KEY` | `certs/origin.key` | 私钥路径 |
| `NAS_MAX_UPLOAD_MB` | `0` | 单文件上限（MB），0 表示不限，磁盘不够时返回 507 |
| `NAS_PUBLIC_HOST` | 空 | 只用于启动日志里显示的地址 |

改密码：改 `NAS_PASSWORD` 后 `docker restart nasui`，或者重跑 `install-nas.sh`，数据不动。

---

## 数据目录

默认管理宿主上的 `<数据盘>/nas`，容器内挂到 `/data`：

```yaml
volumes:
  - "/你的路径/nas:/data"
```

只有这个子目录在页面上可见。容器以 root 运行，上传的文件属主也是 root；如果改成非 root 运行，要把宿主目录的属主一起改掉。换目录改 `NAS_HOST_DIR`（compose）或 `NAS_SHARE_DIR`（install-nas.sh），容器重建后旧文件仍在原处。

---

## 运维和排错

```sh
docker logs -f nasui     # 每次上传、下载都会记一行来源 IP
docker restart nasui
docker rm -f nasui       # 数据目录不动
docker stats nasui
```

升级代码：把新代码同步到项目目录后重跑 `install-nas.sh`，镜像会重新构建。

| 现象 | 处理 |
| --- | --- |
| 页面打不开 | `docker ps` 看容器是否 Up，`docker logs nasui` 看是否提示 `NAS_PASSWORD 未设置` |
| 登录一直失败 | 确认密码一致；连续错 5 次会锁 5 分钟，等一会儿 |
| 上传 413 | 超过 `NAS_MAX_UPLOAD_MB`，设为 0 可关闭限制 |
| 上传 507 | 磁盘满了 |
| 上传文件夹报网络错误 | 浏览器不支持 `webkitGetAsEntry`，改用「上传文件夹」按钮 |
| 外网 502 或 521 | Cloudflare 源规则端口不对，或者 WAN 没放行 |
| 外网 525 或 526 | 证书与域名不匹配，证书要覆盖你实际访问的域名 |
| 视频不能拖动 | 需要走 HTTPS 或局域网直连 |

---

## 安全

- 登录后是签名 cookie，密钥每次启动随机生成，容器一重启所有人重新登录。cookie 带 `HttpOnly; SameSite=Strict`，HTTPS 下再加 `Secure`。
- 密码用 PBKDF2-HMAC-SHA256（20 万轮）比对，只在内存里，不落盘也不进日志。
- 同一 IP 5 分钟内连续失败 5 次会被锁 5 分钟，计数优先用 Cloudflare 传来的真实 IP。
- 路径先 `resolve()` 再校验是否还在 `NAS_ROOT` 内，`..`、绝对路径和符号链接逃逸一律 403。
- 上传的文件名会清洗掉 `/`、`\`、控制字符和首尾点，重名自动变成 `xxx (1).ext`，不会覆盖已有文件。文件名在页面上用 `textContent` 渲染，不会执行 HTML。

这些只是基础防护。密码请用足够长的随机串，并且尽量只在 Cloudflare 代理或 VPN 后面暴露。

---

## 已知限制

- 上传是单次 HTTP 请求，没有分片续传，网络断了要重传。
- 上传文件夹时，空目录不会被创建，只有含文件的目录才会出现。
- 一次拖入上千个文件时，右下角进度队列只显示前 300 行，其余照常上传，结束时汇总成功和失败的数量。
- 经过 Cloudflare 免费版代理时，单次请求体上限 100MB，上传超过 100 秒会返回 524。大文件请走局域网。
- 没有搜索、没有回收站，排序固定为目录在前、其余按名称。预览只支持浏览器原生能解的格式，文本最多读 512KB。

---

## 本地调试

```sh
NAS_ROOT=/tmp/nas-test NAS_PASSWORD=test123 python3 server.py
# Windows: $env:NAS_ROOT="D:\tmp\nas-test"; $env:NAS_PASSWORD="test123"; python server.py
```

浏览器打开 `http://127.0.0.1:8100/`。接口是普通的 JSON 加裸字节流，`curl` 就能测：

```sh
curl -c jar -X POST -d '{"password":"test123"}' http://127.0.0.1:8100/api/login
curl -b jar 'http://127.0.0.1:8100/api/list?path='
curl -b jar 'http://127.0.0.1:8100/api/raw?path=some/file.txt&download=1' -o file.txt
```

---

## 许可证

[MIT](LICENSE)
