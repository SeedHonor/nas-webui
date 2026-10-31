#!/bin/sh
# ===========================================================================
# NAS 文件管理 WebUI · 一键部署脚本（iStoreOS / OpenWrt x86_64 + Docker）
#
# 用法：
#   NAS_PASSWORD='你的密码' sh deploy/install-nas.sh
#   NAS_PASSWORD='你的密码' sh deploy/install-nas.sh --allow-wan   同时放行 WAN 入站 8453
#
# 可覆盖的变量：
#   NAS_SHARE_DIR   数据盘挂载点（不设则自动挑 /mnt 下剩余空间最大的那块，被管理目录是 $NAS_SHARE_DIR/nas）
#   NAS_PORT        HTTP 端口（默认 8100，仅局域网）
#   NAS_TLS_PORT    HTTPS 端口（默认 8453，给 Cloudflare 回源）
#   NAS_MAX_UPLOAD_MB  单文件上限（默认 0 = 不限）
#   NAS_PUBLIC_HOST 你的外网域名（可选，只用于最后打印访问地址）
#
# 特点：
#   * 只暴露 $NAS_SHARE_DIR/nas 这一个子目录，不开整盘
#   * 拉不到 Docker Hub 时自动换国内镜像源、并给 Alpine 换国内软件源重试
#   * 支持离线：把镜像 tar 放到 deploy/nasui-image.tar 即直接导入
#   * 可反复执行：升级代码只需重跑本脚本，数据目录不动
# ===========================================================================
set -e

ALLOW_WAN=0
for arg in "$@"; do
    case "$arg" in
        --allow-wan) ALLOW_WAN=1 ;;
        -h|--help)
            sed -n '2,20p' "$0"
            exit 0
            ;;
    esac
done

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONTAINER="nasui"
IMAGE="nasui:latest"

# 数据盘挂载点：优先用 NAS_SHARE_DIR，没设就自动挑 /mnt 下剩余空间最大的
detect_share_dir() {
    best=""
    best_kb=0
    for mount in /mnt/*; do
        [ -d "$mount" ] || continue
        avail="$(df -Pk "$mount" 2>/dev/null | awk 'NR==2 {print $4}')"
        case "$avail" in ''|*[!0-9]*) continue ;; esac
        if [ "$avail" -gt "$best_kb" ]; then
            best_kb="$avail"
            best="$mount"
        fi
    done
    [ -n "$best" ] || best="/mnt/data"
    printf '%s\n' "$best"
}

SHARE_DIR="${NAS_SHARE_DIR:-$(detect_share_dir)}"
DATA_DIR="$SHARE_DIR/nas"
HTTP_PORT="${NAS_PORT:-8100}"
TLS_PORT="${NAS_TLS_PORT:-8453}"
MAX_UPLOAD_MB="${NAS_MAX_UPLOAD_MB:-0}"
PUBLIC_HOST="${NAS_PUBLIC_HOST:-}"
CN_ALPINE_MIRROR="mirrors.aliyun.com"

say() { printf '%s\n' "$*"; }
warn() { printf '  [注意] %s\n' "$*" >&2; }
die() { printf '\n  错误：%s\n\n' "$*" >&2; exit 1; }

port_busy() {
    port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$port\$"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$port\$"
    else
        return 1
    fi
}

say ""
say "=============================================="
say " NAS 文件管理 WebUI 部署（iStoreOS）"
say " 项目目录：$PROJECT_DIR"
say " 管理目录：$DATA_DIR"
say "=============================================="
say ""

# ----------------------------------------------------------------- 1. 环境检查
[ "$(id -u)" = "0" ] || die "请用 root 运行（iStoreOS 默认就是 root）"

if [ -z "$NAS_PASSWORD" ]; then
    die "缺少访问密码。请这样运行：NAS_PASSWORD='你的密码' sh deploy/install-nas.sh"
fi
case "$NAS_PASSWORD" in
    change-me*|admin*|password*|123456*) warn "当前密码太弱，建议换成随机长口令" ;;
esac

if ! command -v docker >/dev/null 2>&1; then
    say " 未检测到 Docker，请先安装："
    say "   1) 打开 iStoreOS 的「iStore 应用商店」"
    say "   2) 搜索 Docker 并安装（装好后会自动启动）"
    say "   3) 重新运行本脚本"
    say ""
    exit 1
fi
docker info >/dev/null 2>&1 || die "Docker 已安装但没有运行，请先在 iStoreOS 中启动 Docker 插件后重试"
say "[1/7] Docker 检查通过"

# ----------------------------------------------------------------- 2. 管理目录
[ -d "$SHARE_DIR" ] || die "数据盘挂载点不存在：$SHARE_DIR（可用 NAS_SHARE_DIR=/mnt/sdb1 覆盖）"
mkdir -p "$DATA_DIR"
chmod 777 "$DATA_DIR"
say "[2/7] 管理目录就绪：$DATA_DIR"

# ----------------------------------------------------------------- 3. 证书
CERT_SRC=""
for candidate in "$PROJECT_DIR/certs" "$SHARE_DIR/miniblog/certs" "/opt/miniblog/certs"; do
    if [ -f "$candidate/origin.crt" ] && [ -f "$candidate/origin.key" ]; then
        CERT_SRC="$candidate"
        break
    fi
done
if [ -z "$CERT_SRC" ]; then
    for candidate in /mnt/*/miniblog/certs; do
        if [ -f "$candidate/origin.crt" ] && [ -f "$candidate/origin.key" ]; then
            CERT_SRC="$candidate"
            break
        fi
    done
fi

mkdir -p "$PROJECT_DIR/certs"
chmod 700 "$PROJECT_DIR/certs"
if [ -n "$CERT_SRC" ] && [ "$CERT_SRC" != "$PROJECT_DIR/certs" ]; then
    cp -f "$CERT_SRC/origin.crt" "$PROJECT_DIR/certs/origin.crt"
    cp -f "$CERT_SRC/origin.key" "$PROJECT_DIR/certs/origin.key"
fi
if [ -f "$PROJECT_DIR/certs/origin.crt" ] && [ -f "$PROJECT_DIR/certs/origin.key" ]; then
    chmod 600 "$PROJECT_DIR/certs/origin.key"
    say "[3/7] 已找到证书（$PROJECT_DIR/certs），将启用 HTTPS $TLS_PORT"
    TLS_ENABLED=1
else
    say "[3/7] 未找到证书，本次只提供 HTTP $HTTP_PORT"
    warn "如需 HTTPS 回源，把 origin.crt / origin.key 放到 $PROJECT_DIR/certs 后重跑本脚本"
    TLS_ENABLED=0
fi

# ----------------------------------------------------------------- 4. 端口检查
if port_busy "$HTTP_PORT"; then
    die "端口 $HTTP_PORT 已被占用。请用 NAS_PORT=8101 之类的值覆盖后重试"
fi
if [ "$TLS_ENABLED" = "1" ] && port_busy "$TLS_PORT"; then
    die "端口 $TLS_PORT 已被占用。请用 NAS_TLS_PORT=8454 之类的值覆盖后重试（并同步改 Cloudflare 源服务器规则）"
fi
PORT_DESC="HTTP $HTTP_PORT"
if [ "$TLS_ENABLED" = "1" ]; then
    PORT_DESC="$PORT_DESC，HTTPS $TLS_PORT"
fi
say "[4/7] 端口检查通过（$PORT_DESC）"

# ----------------------------------------------------------------- 5. 构建镜像
if [ -f "$PROJECT_DIR/deploy/nasui-image.tar" ]; then
    say "[5/7] 发现离线镜像包，直接导入 ..."
    docker load -i "$PROJECT_DIR/deploy/nasui-image.tar" >/dev/null
else
    OK=0
    for attempt in "python:3.12-alpine|" \
                   "docker.m.daocloud.io/library/python:3.12-alpine|" \
                   "docker.1panel.live/library/python:3.12-alpine|" \
                   "python:3.12-alpine|$CN_ALPINE_MIRROR" \
                   "docker.m.daocloud.io/library/python:3.12-alpine|$CN_ALPINE_MIRROR"; do
        base="${attempt%%|*}"
        mirror="${attempt#*|}"
        say "[5/7] 构建镜像中（基础镜像：$base${mirror:+，Alpine 源：$mirror}）..."
        if docker build -t "$IMAGE" \
                --build-arg BASE_IMAGE="$base" \
                --build-arg ALPINE_MIRROR="$mirror" \
                "$PROJECT_DIR" >/tmp/nasui-build.log 2>&1; then
            OK=1
            break
        fi
        warn "本次构建失败，自动换源重试"
    done
    if [ "$OK" != "1" ]; then
        say ""
        say " 最后一次构建输出（末尾 20 行）："
        tail -n 20 /tmp/nasui-build.log 2>/dev/null | sed 's/^/   /'
        die "镜像构建失败。多为拉不到基础镜像：可在 iStoreOS 的 Docker 设置里配置镜像加速后重试，或把镜像 tar 放到 deploy/ 再跑"
    fi
fi

# ----------------------------------------------------------------- 6. 启动容器
LAN_IP="$(uci -q get network.lan.ipaddr 2>/dev/null || true)"
if [ -z "$LAN_IP" ]; then
    LAN_IP="$(ip -4 addr show br-lan 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1 || true)"
fi
[ -n "$LAN_IP" ] || LAN_IP="127.0.0.1"

say "[6/7] 启动容器 ..."
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

if [ "$TLS_ENABLED" = "1" ]; then
    docker run -d --name "$CONTAINER" \
        --restart unless-stopped \
        --init \
        --memory 256m \
        --stop-timeout 10 \
        -p "$HTTP_PORT:8100" \
        -p "$TLS_PORT:8453" \
        -v "$DATA_DIR:/data" \
        -v "$PROJECT_DIR/certs:/app/certs:ro" \
        -e TZ=Asia/Shanghai \
        -e NAS_ROOT=/data \
        -e NAS_PASSWORD="$NAS_PASSWORD" \
        -e NAS_MAX_UPLOAD_MB="$MAX_UPLOAD_MB" \
        -e NAS_PUBLIC_HOST="$LAN_IP" \
        --log-opt max-size=10m \
        --log-opt max-file=3 \
        "$IMAGE" >/dev/null
else
    docker run -d --name "$CONTAINER" \
        --restart unless-stopped \
        --init \
        --memory 256m \
        --stop-timeout 10 \
        -p "$HTTP_PORT:8100" \
        -v "$DATA_DIR:/data" \
        -e TZ=Asia/Shanghai \
        -e NAS_ROOT=/data \
        -e NAS_PASSWORD="$NAS_PASSWORD" \
        -e NAS_MAX_UPLOAD_MB="$MAX_UPLOAD_MB" \
        -e NAS_PUBLIC_HOST="$LAN_IP" \
        --log-opt max-size=10m \
        --log-opt max-file=3 \
        "$IMAGE" >/dev/null
fi

# ----------------------------------------------------------------- 7. 自检
say "[7/7] 等待服务就绪 ..."
HEALTHY=0
i=0
while [ "$i" -lt 30 ]; do
    if docker exec "$CONTAINER" python -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8100/api/ping',timeout=4)" >/dev/null 2>&1; then
        HEALTHY=1
        break
    fi
    i=$((i + 1))
    sleep 1
done

if [ "$HEALTHY" != "1" ]; then
    say ""
    say " 容器日志（末尾 25 行）："
    docker logs --tail 25 "$CONTAINER" 2>&1 | sed 's/^/   /'
    die "服务未能在 30 秒内就绪，请把上面的日志发给我"
fi

TLS_STATE="未启用"
if [ "$TLS_ENABLED" = "1" ]; then
    if docker exec "$CONTAINER" python -c "import urllib.request,ssl;urllib.request.urlopen('https://127.0.0.1:8453/api/ping',context=ssl._create_unverified_context(),timeout=4)" >/dev/null 2>&1; then
        TLS_STATE="正常"
    else
        TLS_STATE="异常"
    fi
fi

# ----------------------------------------------------------------- 可选：WAN 放行
if [ "$ALLOW_WAN" = "1" ] && [ "$TLS_ENABLED" = "1" ]; then
    if command -v uci >/dev/null 2>&1; then
        uci -q delete firewall.nas_wan >/dev/null 2>&1 || true
        uci set firewall.nas_wan=rule
        uci set firewall.nas_wan.name='Allow-NAS-WAN'
        uci set firewall.nas_wan.src='wan'
        uci set firewall.nas_wan.proto='tcp'
        uci set firewall.nas_wan.dest_port="$TLS_PORT"
        uci set firewall.nas_wan.target='ACCEPT'
        uci commit firewall
        /etc/init.d/firewall reload >/dev/null 2>&1 || true
        say "      已放行 WAN 入站：TCP $TLS_PORT（规则名 Allow-NAS-WAN，HTTP $HTTP_PORT 仍只限局域网）"
    else
        warn "没有 uci 命令，请手动在 路由器 → 防火墙 → 通信规则 中放行 TCP $TLS_PORT"
    fi
elif [ "$ALLOW_WAN" = "1" ]; then
    warn "没启用 HTTPS，已跳过 WAN 放行（不要把明文 8100 暴露到公网）"
fi

# ----------------------------------------------------------------- 汇总
say ""
say "=============================================="
say " 部署完成"
say "=============================================="
say "  管理目录   : $DATA_DIR  （容器内 /data）"
say "  登录密码   : 见部署命令行里提供的 NAS_PASSWORD"
say "  局域网访问 : http://$LAN_IP:$HTTP_PORT/"
if [ "$TLS_ENABLED" = "1" ]; then
    say "  HTTPS 回源 : https://$LAN_IP:$TLS_PORT/  （证书状态：$TLS_STATE）"
    if [ -n "$PUBLIC_HOST" ]; then
        say "  外网访问   : https://$PUBLIC_HOST/  （需先在 Cloudflare 加 DNS + 源服务器规则）"
    else
        say "  外网访问   : 需要时再加（见下方 Cloudflare 三步）"
    fi
fi
say "  容器状态   : $(docker inspect -f '{{.State.Status}} / 重启策略 {{.HostConfig.RestartPolicy.Name}}' "$CONTAINER" 2>/dev/null)"
say ""
say "  常用命令："
say "    查看日志   docker logs -f $CONTAINER"
say "    重启       docker restart $CONTAINER"
say "    停止/删除  docker rm -f $CONTAINER"
say "    改密码     重跑本脚本并换 NAS_PASSWORD（数据不受影响）"
say "    升级代码   重新拷本项目后再跑一次本脚本"
say ""
if [ "$TLS_ENABLED" = "1" ]; then
    say "  想让外网也能用（可选，只需做一次）："
    say "    1) 在 Cloudflare 加一条 DNS 记录指向你的公网 IP（或已有隧道的域名），代理开启（橙色云朵）"
    say "    2) 源服务器规则：Hostname = 你的域名 → 目标端口 $TLS_PORT"
    say "    3) SSL/TLS 保持 Full (strict) + Always Use HTTPS"
    say "    证书要覆盖你用的域名；没有域名就直接用局域网地址，本页功能一样。"
else
    say "  现在只有局域网可用（HTTP $HTTP_PORT）。要外网访问时："
    say "    把证书放到 $PROJECT_DIR/certs（origin.crt / origin.key）后重跑本脚本，"
    say "    再按 Cloudflare 的三步配置，全程不需要改代码。"
fi
say ""
df -h "$DATA_DIR" 2>/dev/null | sed 's/^/  /'
say ""
