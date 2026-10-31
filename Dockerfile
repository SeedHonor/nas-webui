# NAS 文件管理 WebUI · Docker 镜像
# 基础镜像与 Alpine 软件源都可用 build-arg 替换（国内网络拉不动时用加速地址）
ARG BASE_IMAGE=python:3.12-alpine
FROM ${BASE_IMAGE}

ARG ALPINE_MIRROR=""

# 只为容器内日志时间正确装 tzdata；失败也不影响运行
RUN if [ -n "$ALPINE_MIRROR" ]; then \
        sed -i "s|dl-cdn.alpinelinux.org|$ALPINE_MIRROR|g" /etc/apk/repositories; \
    fi \
 && (apk add --no-cache tzdata || echo "warn: tzdata 安装失败，时间将按 UTC") \
 && (cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime 2>/dev/null || true) \
 && (echo "Asia/Shanghai" > /etc/timezone || true)

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONIOENCODING=utf-8 \
    TZ=Asia/Shanghai

WORKDIR /app

COPY server.py ./
COPY public/ ./public/

# 证书与数据都由挂载卷提供（见 docker-compose.yml / deploy/install-nas.sh）
RUN mkdir -p /app/certs /data

EXPOSE 8100 8453

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request,sys;sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8100/api/ping',timeout=4).status==200 else 1)"

# 容器以 root 运行，避免挂载盘（ext4 / 外置盘）权限不一致导致上传失败。
# 想改成非 root：compose 里加 `user: "10001:10001"`，并把宿主上的数据目录属主改成 10001。
CMD ["python", "server.py"]
