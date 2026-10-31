<#
.SYNOPSIS
    在 Windows 上把本项目上传到 OpenWrt / iStoreOS 路由器并自动部署（paramiko + SSH 密码登录）。

.DESCRIPTION
    1. 用 SFTP 把 server.py / public / Dockerfile / deploy/install-nas.sh / certs 传到路由器上的项目目录
    2. 远程执行 deploy/install-nas.sh（自动构建镜像、起容器、配防火墙、自检）
    3. 从路由器本机 curl 校验 HTTP 与 HTTPS
    4. 顺手把本机公钥装回路由器（免得以后还要输密码）

.EXAMPLE
    $env:NAS_HOST = "192.168.1.1"
    cd <本项目目录>
    powershell -ExecutionPolicy Bypass -File .\deploy\deploy.ps1

.NOTES
    需要 Python + paramiko（pip install paramiko），脚本会自动找 python.exe。
    可覆盖的环境变量：
      NAS_HOST（默认 192.168.1.1）、NAS_SSH_PORT（默认 22）、
      NAS_REMOTE_DIR（默认 /root/nasui）、NAS_PYTHON（指定 python.exe 路径）、
      NAS_PORT / NAS_TLS_PORT（默认 8100 / 8453）、NAS_PUBLIC_HOST（你的域名，可选）、
      NAS_ROOT_PASSWORD（路由器 root 密码）、NAS_WEB_PASSWORD（网站登录密码）
    如果密码里含单引号，脚本会拒绝执行（避免 shell 注入）。
#>

$ErrorActionPreference = "Stop"

# 让 Python 的中文输出不乱码（Windows PowerShell 5.1 默认 GBK 控制台）
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$env:PYTHONIOENCODING = "utf-8"
$env:PYTHONUTF8 = "1"

$HostName   = if ($env:NAS_HOST) { $env:NAS_HOST } else { "192.168.1.1" }
$SshPort    = if ($env:NAS_SSH_PORT) { [int]$env:NAS_SSH_PORT } else { 22 }
$RemoteDir  = if ($env:NAS_REMOTE_DIR) { $env:NAS_REMOTE_DIR } else { "/root/nasui" }
$HttpPort   = if ($env:NAS_PORT) { $env:NAS_PORT } else { "8100" }
$TlsPort    = if ($env:NAS_TLS_PORT) { $env:NAS_TLS_PORT } else { "8453" }
$PublicHost = if ($env:NAS_PUBLIC_HOST) { $env:NAS_PUBLIC_HOST } else { "" }
$ProjectDir = Split-Path -Parent $PSScriptRoot

$Python = $env:NAS_PYTHON
if (-not $Python) {
    foreach ($cand in @("python", "python3", "py")) {
        $c = Get-Command $cand -ErrorAction SilentlyContinue
        if ($c) {
            $out = & $c.Source -c "import paramiko,sys;sys.stdout.write(sys.executable)" 2>$null
            if ($LASTEXITCODE -eq 0 -and $out) { $Python = "$out".Trim(); break }
        }
    }
}
if (-not $Python) { $Python = "python" }

function Fail($msg) {
    Write-Host ""
    Write-Host "  失败：$msg" -ForegroundColor Red
    Write-Host ""
    exit 1
}

# ---------------------------------------------------------------- 准备凭据
$RootPw = $env:NAS_ROOT_PASSWORD
if (-not $RootPw) {
    $sec = Read-Host -AsSecureString "路由器 root 密码"
    $RootPw = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
}
if (-not $RootPw) { Fail "缺少路由器 root 密码（设为 `$env:NAS_ROOT_PASSWORD）" }
if ($RootPw.Contains("'")) { Fail "root 密码里不能有单引号，请先改个密码" }

$WebPw = $env:NAS_WEB_PASSWORD
if (-not $WebPw) {
    $chars = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789".ToCharArray()
    $WebPw = -join (1..24 | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
    Write-Host "  已生成网站登录密码：$WebPw" -ForegroundColor Yellow
    Write-Host "  （想自定义就设 `$env:NAS_WEB_PASSWORD 后重跑；改密码重跑脚本即可，数据不受影响）"
}

$PyExe = if (Test-Path $Python) { $Python } else { (Get-Command $Python -ErrorAction SilentlyContinue).Source }
if (-not $PyExe) { Fail "找不到 Python。请安装 Python 3 并执行 pip install paramiko，或用 `$env:NAS_PYTHON 指定 python.exe 路径" }
& $PyExe -c "import paramiko" 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "这个 Python 里没有 paramiko，请先执行：$PyExe -m pip install paramiko" }

# ---------------------------------------------------------------- 收集待传文件
$files = @()
foreach ($rel in @(
    "server.py",
    "Dockerfile",
    "docker-compose.yml",
    ".dockerignore",
    "README.md",
    "public/index.html",
    "public/assets/style.css",
    "public/assets/app.js",
    "deploy/install-nas.sh"
)) {
    $full = Join-Path $ProjectDir $rel
    if (Test-Path $full) { $files += [pscustomobject]@{ Local = $full; Remote = $rel } }
    else { Write-Host "  [跳过] 本地不存在：$rel" -ForegroundColor DarkYellow }
}
foreach ($rel in @("certs/origin.crt", "certs/origin.key")) {
    $full = Join-Path $ProjectDir $rel
    if (Test-Path $full) { $files += [pscustomobject]@{ Local = $full; Remote = $rel } }
}

# ---------------------------------------------------------------- 调 Python 做 SSH
$pyScript = @'
import os, sys
import paramiko

host, port, user, password, remote_dir = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
uploads = [line.split("|", 1) for line in sys.argv[6].splitlines() if line.strip()]
web_pw = sys.argv[7]
allow_wan = sys.argv[8] == "1"
pubkey = sys.argv[9] if len(sys.argv) > 9 else ""
http_port = os.environ.get("NAS_PORT", "8100")
tls_port = os.environ.get("NAS_TLS_PORT", "8453")


def log(msg=""):
    print(msg, flush=True)


def run(client, cmd, timeout=900, echo=True):
    log(f"  $ {cmd}")
    chan = client.get_transport().open_session()
    chan.settimeout(timeout)
    chan.exec_command(cmd)
    out = []
    while True:
        try:
            chunk = chan.recv(65536)
        except Exception:
            break
        if not chunk:
            break
        text = chunk.decode("utf-8", "replace")
        out.append(text)
        if echo:
            sys.stdout.write(text)
            sys.stdout.flush()
    code = chan.recv_exit_status()
    return code


def capture(client, cmd, timeout=120):
    chan = client.get_transport().open_session()
    chan.settimeout(timeout)
    chan.exec_command(cmd)
    out = []
    while True:
        try:
            chunk = chan.recv(65536)
        except Exception:
            break
        if not chunk:
            break
        out.append(chunk.decode("utf-8", "replace"))
    chan.recv_exit_status()
    return "".join(out).strip()


client = paramiko.SSHClient()
client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
log(f"  连接 {user}@{host}:{port} ...")
try:
    client.connect(host, port=port, username=user, password=password,
                   timeout=20, banner_timeout=25, auth_timeout=25,
                   look_for_keys=False, allow_agent=False)
except paramiko.AuthenticationException:
    log("  错误：root 密码不对，或路由器禁用了密码登录")
    sys.exit(3)
except Exception as exc:
    log(f"  错误：连不上 {host}:{port} -> {exc}")
    sys.exit(4)
log("  已连接")

try:
    run(client, f"mkdir -p {remote_dir}/public/assets {remote_dir}/deploy {remote_dir}/certs")

    sftp = client.open_sftp()
    total = len(uploads)
    for idx, (local, remote) in enumerate(uploads, 1):
        target = f"{remote_dir}/{remote}"
        log(f"    [{idx}/{total}] {remote}  ({os.path.getsize(local)} 字节)")
        sftp.put(local, target + ".new")
        sftp.posix_rename(target + ".new", target)

    # 公钥回装（失败不影响部署）
    if pubkey and os.path.exists(pubkey):
        with open(pubkey, "r", encoding="utf-8") as fh:
            key = fh.read().strip()
        if key:
            log("  安装本机公钥到路由器 /etc/dropbear/authorized_keys")
            sftp.put(pubkey, remote_dir + "/.pubkey.tmp")
            run(client, f"mkdir -p /etc/dropbear /root/.ssh && "
                        f"grep -qxF \"$(cat {remote_dir}/.pubkey.tmp)\" /etc/dropbear/authorized_keys 2>/dev/null || "
                        f"cat {remote_dir}/.pubkey.tmp >> /etc/dropbear/authorized_keys; "
                        f"chmod 600 /etc/dropbear/authorized_keys; "
                        f"cat {remote_dir}/.pubkey.tmp >> /root/.ssh/authorized_keys; "
                        f"chmod 600 /root/.ssh/authorized_keys; "
                        f"rm -f {remote_dir}/.pubkey.tmp", echo=False)
    sftp.close()

    log("  检查远程脚本语法（sh -n）...")
    if run(client, f"cd {remote_dir} && sh -n deploy/install-nas.sh && echo '  shell 语法 OK'", echo=False) != 0:
        log("  错误：install-nas.sh 语法检查未通过")
        sys.exit(6)

    cmd = (f"cd {remote_dir} && NAS_PASSWORD='{web_pw}' sh deploy/install-nas.sh"
           + (" --allow-wan" if allow_wan else ""))
    code = run(client, cmd, timeout=1200)
    if code != 0:
        log(f"  错误：远程部署脚本退出码 {code}")
        run(client, f"docker logs --tail 40 nasui 2>&1 || true")
        sys.exit(5)

    log("")
    log("  服务自检：")
    log("    " + capture(client, f"curl -s -o /dev/null -w 'HTTP %{{http_code}}' http://127.0.0.1:{http_port}/api/ping"))
    log("    " + capture(client, f"curl -sk -o /dev/null -w 'HTTPS %{{http_code}}' https://127.0.0.1:{tls_port}/api/ping"))
    log("    " + capture(client, "docker inspect -f 'state={{.State.Status}} restarts={{.RestartCount}}' nasui"))
    log("    " + capture(client, "du -sh \"$(docker inspect -f '{{range .Mounts}}{{if eq .Destination \"/data\"}}{{.Source}}{{end}}{{end}}' nasui)\" 2>/dev/null || true"))
finally:
    client.close()
'@

$tmpPy = Join-Path $env:TEMP "nasui_deploy.py"
[IO.File]::WriteAllText($tmpPy, $pyScript, (New-Object System.Text.UTF8Encoding($false)))

$uploadLines = ($files | ForEach-Object { "$($_.Local)|$($_.Remote)" }) -join "`n"
$pubkey = ""
foreach ($name in @("id_ed25519_openwrt.pub", "id_ed25519.pub", "id_rsa.pub")) {
    $cand = Join-Path $env:USERPROFILE ".ssh\$name"
    if (Test-Path $cand) { $pubkey = $cand; break }
}

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host " 部署 NAS WebUI -> $HostName ($RemoteDir)" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

& $PyExe $tmpPy $HostName $SshPort "root" $RootPw $RemoteDir $uploadLines $WebPw "1" $pubkey
$code = $LASTEXITCODE
Remove-Item $tmpPy -ErrorAction SilentlyContinue

Write-Host ""
if ($code -ne 0) { Fail "部署过程出错（退出码 $code），请看上面的输出" }

Write-Host "==============================================" -ForegroundColor Green
Write-Host " 部署完成" -ForegroundColor Green
Write-Host "==============================================" -ForegroundColor Green
Write-Host " 局域网 : http://$($HostName):$HttpPort/"
if ($PublicHost) {
    Write-Host " 外网   : https://$PublicHost/   (需先在 Cloudflare 加 DNS 与源服务器规则)"
} else {
    Write-Host " 外网   : 未配置域名（局域网的地址一样好用；要外网访问见 README 第 2 节）"
}
Write-Host " 登录密码: $WebPw" -ForegroundColor Yellow
Write-Host ""
