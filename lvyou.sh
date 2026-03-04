#!/usr/bin/env bash
set -euo pipefail

RED='\u001B[0;31m'
GREEN='\u001B[0;32m'
YELLOW='\u001B[1;33m'
BLUE='\u001B[0;34m'
PURPLE='\u001B[0;35m'
CYAN='\u001B[0;36m'
NC='\u001B[0m'

log_info(){ echo -e "${GREEN}[✓]${NC} $*"; }
log_warn(){ echo -e "${YELLOW}[!]${NC} $*"; }
log_err(){ echo -e "${RED}[✗]${NC} $*"; }
log_step(){ echo -e "${BLUE}[→]${NC} $*"; }
title(){ echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
${CYAN}$*${NC}
${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

APPDIR="/opt/board-manager"
APIPORT=8000
SCANUSER="admin"
SCANPASS="admin"
UIPASS=""
CIDR=""

SERVICEAPI4="/etc/systemd/system/board-manager-v4.service"
SERVICEAPI6="/etc/systemd/system/board-manager-v6.service"
CONFIG_FILE="/etc/board-manager.conf"
BACKUP_DIR="/var/backups/board-manager"

need_root(){
  if [[ $EUID -ne 0 ]]; then
    log_err "需要root权限，请使用 sudo 运行"
    exit 1
  fi
}

# 安全删除函数（保持不变）
safe_delete(){
  local target="$1"
  local safe_dirs=("/" "/bin" "/sbin" "/usr" "/etc" "/lib" "/lib64" "/var" "/home" "/root" "/boot" "/dev" "/proc" "/sys" "/tmp")
  
  for dir in "${safe_dirs[@]}"; do
    if [[ "${target}" == "$dir" || "${target}" == "$dir/"* ]]; then
      log_err "安全拒绝：拒绝删除系统目录 '$target'"
      return 1
    fi
  done
  
  if [[ -z "${target}" || "${target}" == "/" ]]; then
    log_err "目录为空或格式错误: '$target'"
    return 1
  fi
  
  read -p "确认删除目录 '$target' 及其所有内容？(y/N 或输入 DELETE): " confirm
  if [[ ! "${confirm:-}" =~ ^([Yy]|DELETE)$ ]]; then
    log_info "取消删除"
    return 0
  fi
  
  if [[ -d "$target" ]]; then
    log_step "删除目录: $target"
    rm -rf "$target"
    return 0
  fi
  return 0
}

# 检测操作系统（保持不变）
detect_os(){
  if [[ -z "${OS_FAMILY:-}" ]]; then
    if [[ -f /etc/os-release ]]; then
      . /etc/os-release
      case "${ID:-}" in
        ubuntu|debian) OS_FAMILY="debian"; PKG="apt-get" ;;
        centos|rhel|fedora|rocky|almalinux) OS_FAMILY="redhat"; PKG="$(command -v dnf || command -v yum || true)" ;;
        *) OS_FAMILY="debian"; PKG="apt-get" ;;
      esac
    else
      OS_FAMILY="debian"; PKG="apt-get"
    fi
  fi
}

cleanup_temp(){
  rm -f /tmp/board_mgr_task.log 2>/dev/null || true
  rm -f /tmp/pip_up.log /tmp/pip_ins.log 2>/dev/null || true
  rm -f /tmp/board_mgr_*.log 2>/dev/null || true
}

run_task(){
  local desc="$1"; shift
  local start_ts end_ts
  start_ts=$(date +%s)

  echo -ne "${BLUE}[⌛]${NC} ${desc} "
  set +e
  cleanup_temp
  ("$@") >/tmp/board_mgr_task.log 2>&1 &
  local pid=$!
  local spin='-|/'
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i+1) % 4 ))
    echo -ne "\b${spin:$i:1}"
    sleep 0.12
  done
  wait "$pid"
  local rc=$?
  set -e

  end_ts=$(date +%s)
  local cost=$((end_ts - start_ts))
  if [[ $rc -eq 0 ]]; then
    echo -e "\b ${GREEN}完成${NC} (${cost}s)"
  else
    echo -e "\b ${RED}失败${NC} (${cost}s)"
    tail -n 120 /tmp/board_mgr_task.log >&2 || true
    return $rc
  fi
}

help(){
  cat <<EOF
============================================================
Board LAN Hub - v3.2.2 (完整修复版 + SIM卡增强)
============================================================
用法: $0 <命令> [选项]

命令:
  install              安装系统（UI+API 同端口）
  scan                 触发扫描并添加设备
  status               查看后端服务状态
  restart              重启后端服务
  logs                 查看服务日志
  uninstall            卸载系统（安全模式）
  uninstall --force    强制卸载（跳过确认）
  backup               备份数据
  restore              恢复数据
  set-ui-pass          修改 UI 登录密码
  set-port             修改服务端口
  patch-sim-display    应用SIM卡显示增强补丁
  help                 显示此帮助

选项:
  --dir <路径>         安装目录 (默认: /opt/board-manager)
  --api-port <端口>    后端端口 (默认: 8000)
  --user <用户名>      设备登录用户名 (默认: admin)
  --pass <密码>        设备登录密码 (默认: admin)
  --cidr <网段>        指定扫描网段 (例如: 192.168.1.0/24)

特性:
  ✓ 完整的运营商显示（移动(46001)）
  ✓ 两行紧凑SIM卡显示（运营商+号码）
  ✓ 优先使用SIM_STA字段获取完整运营商信息
  ✓ 新版前端UI界面
============================================================
EOF
  exit 0
}

get_local_ip(){
  local ip
  ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' 2>/dev/null || true)
  if [[ -z "$ip" ]]; then
    ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  fi
  echo "$ip"
}

get_ipv6_address(){
  local ipv6
  ipv6=$(ip -6 addr show scope global 2>/dev/null | grep inet6 | awk '{print $2}' | cut -d'/' -f1 | head -1 || true)
  echo "$ipv6"
}

auto_detect_cidr(){
  local local_ip subnet suggested_cidr confirm custom_cidr
  local_ip=$(get_local_ip)
  if [[ -z "$local_ip" ]]; then
    log_warn "无法自动检测内网IP，使用默认值 192.168.1.0/24"
    echo "192.168.1.0/24"
    return
  fi
  subnet=$(echo "$local_ip" | cut -d. -f1-3)
  suggested_cidr="${subnet}.0/24"
  log_info "检测到本机IP: ${GREEN}${local_ip}${NC}"
  log_info "建议的内网段: ${GREEN}${suggested_cidr}${NC}"
  echo ""
  read -p "是否使用此内网段进行扫描？(Y/n): " confirm
  if [[ "$confirm" =~ ^[Nn]$ ]]; then
    read -p "请输入自定义内网段 (例如: 192.168.1.0/24): " custom_cidr
    if [[ -n "$custom_cidr" ]]; then echo "$custom_cidr"; else echo "$suggested_cidr"; fi
  else
    echo "$suggested_cidr"
  fi
}

check_port(){
  local port="$1"
  log_step "检查端口 ${port} ..."
  
  # 检查IPv4
  if ss -ltn 2>/dev/null | grep -q ":${port} "; then
    log_warn "端口 ${port} 已被占用，正在检查是否是本服务..."
    local pid=$(ss -ltnp 2>/dev/null | grep ":${port} " | awk '{print $NF}' | cut -d'=' -f2 | cut -d',' -f1 | head -1)
    if [[ -n "$pid" ]] && ps -p "$pid" >/dev/null 2>&1; then
      local cmd=$(ps -p "$pid" -o cmd= 2>/dev/null || true)
      if [[ "$cmd" == *"board-manager"* ]] || [[ "$cmd" == *"uvicorn"* ]]; then
        log_info "端口 ${port} 被本服务占用，将继续使用"
        return 0
      fi
    fi
    log_err "端口 ${port} 被其他进程占用！"
    ss -ltnp 2>/dev/null | grep ":${port} " || true
    return 1
  fi
  
  # 检查IPv6
  if ss -ltn 2>/dev/null | grep -q "\\[[0-9a-f:]*\\]:${port} "; then
    log_warn "端口 ${port} (IPv6) 已被占用，正在检查..."
    local pid=$(ss -ltnp 2>/dev/null | grep "\\[[0-9a-f:]*\\]:${port} " | awk '{print $NF}' | cut -d'=' -f2 | cut -d',' -f1 | head -1)
    if [[ -n "$pid" ]] && ps -p "$pid" >/dev/null 2>&1; then
      local cmd=$(ps -p "$pid" -o cmd= 2>/dev/null || true)
      if [[ "$cmd" == *"board-manager"* ]] || [[ "$cmd" == *"uvicorn"* ]]; then
        log_info "端口 ${port} (IPv6) 被本服务占用，将继续使用"
        return 0
      fi
    fi
    log_err "端口 ${port} (IPv6) 被其他进程占用！"
    ss -ltnp 2>/dev/null | grep "\\[[0-9a-f:]*\\]:${port} " || true
    return 1
  fi
  
  return 0
}

install_deps(){
  title "安装/检查系统依赖"
  detect_os
  
  if ! command -v curl >/dev/null 2>&1; then
    run_task "安装 curl" bash -lc "apt-get install -y curl 2>/dev/null || yum install -y curl 2>/dev/null || true"
  fi
  
  if [[ "$OS_FAMILY" == "debian" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    run_task "apt-get update" bash -lc "apt-get update -y -qq" || true
    run_task "安装系统依赖" bash -lc "apt-get install -y -qq git ca-certificates python3 python3-pip python3-venv sqlite3 iproute2 net-tools" || {
      log_err "依赖安装失败，请检查网络连接"
      return 1
    }
  else
    run_task "安装系统依赖" bash -lc "$PKG install -y -q git ca-certificates python3 python3-pip sqlite iproute net-tools" || {
      log_err "依赖安装失败，请检查网络连接"
      return 1
    }
  fi
  
  # 检查关键命令
  for cmd in python3 sqlite3; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      log_err "必需命令 $cmd 未安装"
      return 1
    fi
  done
  
  log_info "系统依赖 OK"
}

install_node(){
  title "安装/检查 Node.js"
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    local node_ver npm_ver
    node_ver=$(node -v 2>/dev/null || echo "未知")
    npm_ver=$(npm -v 2>/dev/null || echo "未知")
    log_info "已存在 node=${node_ver} npm=${npm_ver}"
    return 0
  fi
  
  detect_os
  if [[ "$OS_FAMILY" == "debian" ]]; then
    run_task "安装 Node.js 20.x 源" bash -lc "curl -fsSL https://deb.nodesource.com/setup_20.x | bash -"
    run_task "安装 nodejs" bash -lc "apt-get install -y -qq nodejs" || {
      log_err "Node.js 安装失败"
      return 1
    }
  else
    run_task "安装 Node.js 20.x 源" bash -lc "curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -"
    run_task "安装 nodejs" bash -lc "$PKG install -y -q nodejs" || {
      log_err "Node.js 安装失败"
      return 1
    }
  fi
  
  if ! command -v node >/dev/null 2>&1; then
    log_err "Node.js 安装后未找到"
    return 1
  fi
  
  log_info "Node OK：node=$(node -v) npm=$(npm -v)"
}

ensure_dirs(){
  title "准备目录"
  mkdir -p "${APPDIR}/app" "${APPDIR}/frontend/src" "${APPDIR}/data" "${APPDIR}/static" "${APPDIR}/bak"
  mkdir -p "$(dirname "$CONFIG_FILE")"
  mkdir -p "$BACKUP_DIR"
  log_info "目录 OK：${APPDIR}"
}

pip_install_with_mirrors(){
  local pip="$1"; shift
  local -a mirrors=(
    "https://mirrors.aliyun.com/pypi/simple"
    "https://pypi.tuna.tsinghua.edu.cn/simple"
    "https://pypi.doubanio.com/simple"
    "https://pypi.org/simple"
  )
  local rc=1
  for m in "${mirrors[@]}"; do
    local host
    host=$(echo "$m" | sed 's|https://||' | cut -d/ -f1)
    echo "[→] pip 源：$host"
    set +e
    "$pip" -q install "$@" -i "$m" --trusted-host "$host" >/tmp/pip_ins.log 2>&1
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
      return 0
    fi
  done

  echo "[→] 尝试默认pip源..."
  "$pip" -q install "$@" >/tmp/pip_ins.log 2>&1 && return 0

  tail -n 120 /tmp/pip_ins.log >&2 || true
  return 1
}

write_backend(){
  title "部署后端（FastAPI + SQLite + Static UI）端口: ${APIPORT}"
  local venv="${APPDIR}/venv"

  if [[ ! -d "$venv" ]]; then
    run_task "创建 venv" bash -lc "python3 -m venv '$venv'"
  fi

  if [[ ! -f "$venv/bin/python" ]]; then
    log_err "Python虚拟环境创建失败"
    return 1
  fi

  run_task "pip 安装依赖" bash -lc " \
    $(declare -f pip_install_with_mirrors); \
    pip_install_with_mirrors '$venv/bin/pip' fastapi 'uvicorn[standard]' httpx sqlalchemy aiosqlite requests \
  "

  # 创建配置文件
  cat > "$CONFIG_FILE" <<EOF
# Board Manager 配置文件
APPDIR="${APPDIR}"
APIPORT="${APIPORT}"
SCANUSER="${SCANUSER}"
SCANPASS="${SCANPASS}"
UIPASS="${UIPASS}"
INSTALL_DATE="$(date +%Y-%m-%d)"
EOF

  # 设置配置文件权限
  chmod 600 "$CONFIG_FILE"
  chown root:root "$CONFIG_FILE"

  # 后端代码 - 集成补丁：完整的运营商显示
  cat > "${APPDIR}/app/main.py" <<'PY'
import asyncio
import threading
import json
import os
import re
import sqlite3
import subprocess
from ipaddress import ip_address, ip_network, IPv4Network
from typing import Any, Dict, List, Optional, Tuple
from itertools import islice
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI, HTTPException, Request, Depends
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
import base64
from sqlalchemy import create_engine, Column, Integer, String, Text, BigInteger
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker, Session

# 导入requests用于同步扫描
import requests
import concurrent.futures

DBPATH = os.environ.get("BMDB", "/opt/board-manager/data/data.db")
STATICDIR = os.environ.get("BMSTATIC", "/opt/board-manager/static")
DEFAULTUSER = os.environ.get("BMDEVUSER", "admin")
DEFAULTPASS = os.environ.get("BMDEVPASS", "admin")

TIMEOUT = float(os.environ.get("BMHTTPTIMEOUT", "2.5"))
CONCURRENCY = int(os.environ.get("BMSCANCONCURRENCY", "96"))
CIDRFALLBACKLIMIT = int(os.environ.get("BMCIDRFALLBACKLIMIT", "1024"))

# SQLAlchemy 配置
Base = declarative_base()
engine = create_engine(f'sqlite:///{DBPATH}', pool_pre_ping=True, pool_recycle=3600)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

# 设备模型
class Device(Base):
    __tablename__ = "devices"
    
    id = Column(Integer, primary_key=True, index=True)
    devId = Column(String(128), unique=True, nullable=True)
    grp = Column(String(64), default='auto')
    ip = Column(String(45), unique=True, index=True, nullable=False)
    mac = Column(String(32), unique=True, nullable=True, default='')
    user = Column(String(64), default='')
    passwd = Column(String(64), default='')
    status = Column(String(32), default='unknown')
    lastSeen = Column(BigInteger, default=0)
    sim1number = Column(String(32), default='')
    sim1operator = Column(String(64), default='')
    sim2number = Column(String(32), default='')
    sim2operator = Column(String(64), default='')
    token = Column(Text, default='')
    alias = Column(String(128), default='')
    created = Column(String(32), default='')

# 创建表
Base.metadata.create_all(bind=engine)

# migration: add devices.token
try:
    cols = [r[1] for r in engine.execute("PRAGMA table_info(devices)").fetchall()]
    if "token" not in cols:
        engine.execute("ALTER TABLE devices ADD COLUMN token TEXT DEFAULT ''")
except Exception:
    pass

# 数据库依赖
def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

@asynccontextmanager
async def lifespan(app: FastAPI):
    # 启动时创建 HTTP 客户端
    app.state.http_client = httpx.AsyncClient(
        timeout=TIMEOUT,
        limits=httpx.Limits(max_connections=CONCURRENCY, max_keepalive_connections=20),
        follow_redirects=False
    )
    yield
    # 关闭时清理
    await app.state.http_client.aclose()

app = FastAPI(title="Board LAN Hub", version="3.2.2", lifespan=lifespan)

UIUSER = os.environ.get("BMUIUSER", "admin")
UIPASS = os.environ.get("BMUIPASS", "admin")

def _unauthorized() -> Response:
    return Response(status_code=401)

def _check_basic(auth: str) -> bool:
    try:
        if not auth or not auth.startswith("Basic "):
            return False
        raw = base64.b64decode(auth.split(" ", 1)[1]).decode("utf-8")
        user, pw = raw.split(":", 1)
        return (user == UIUSER) and (pw == UIPASS)
    except Exception:
        return False

@app.middleware("http")
async def basic_auth_mw(request: Request, call_next):
    if request.url.path.startswith('/static/'):
        return await call_next(request)
    if request.url.path == '/api/health':
        return await call_next(request)
    if request.url.path == '/' or request.url.path.startswith('/api/'):
        auth = request.headers.get('Authorization','')
        if not _check_basic(auth):
            if request.url.path == '/':
                return await call_next(request)
            return _unauthorized()
    return await call_next(request)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

os.makedirs(STATICDIR, exist_ok=True)
app.mount("/static", StaticFiles(directory=STATICDIR), name="static")

@app.get("/")
def uiindex():
  indexpath = os.path.join(STATICDIR, "index.html")
  if not os.path.exists(indexpath):
      raise HTTPException(status_code=404, detail="UI not built (missing static/index.html)")
  return FileResponse(indexpath)

def nowts() -> int:
    import time
    return int(time.time())

def sh(cmd: List[str]) -> str:
    return subprocess.check_output(cmd, stderr=subprocess.DEVNULL, text=True).strip()

def guessipv4cidr() -> str:
    try:
        r = sh(["bash", "-lc", "ip -4 route show default 2>/dev/null | head -n1"])
        m = re.search(r"dev\s+(\S+)", r)
        if m:
            iface = m.group(1)
            a = sh(["bash", "-lc", f"ip -4 addr show dev {iface} | awk '/inet /{{print $2; exit}}'"])
            if a:
                net = ip_network(a, strict=False)
                if isinstance(net, IPv4Network):
                    return str(net.network_address) + f"/{net.prefixlen}"
    except Exception:
        pass

    try:
        txt = sh(["bash", "-lc", "ip -o -4 addr show | awk '{print $2,$4}'"])
        for line in txt.splitlines():
            parts = line.strip().split()
            if len(parts) != 2:
                continue
            iface, cidr = parts[0], parts[1]
            if iface == "lo":
                continue
            net = ip_network(cidr, strict=False)
            if isinstance(net, IPv4Network):
                return str(net.network_address) + f"/{net.prefixlen}"
    except Exception:
        pass

    return "192.168.1.0/24"

def getarptable() -> Dict[str, str]:
    out: Dict[str, str] = {}
    try:
        with open("/proc/net/arp", "r") as f:
            lines = f.readlines()
        for line in lines[1:]:
            parts = line.split()
            if len(parts) >= 4:
                ip = parts[0].strip()
                mac = parts[3].strip().upper()
                if mac and mac != "00:00:00:00:00:00" and ":" in mac:
                    out[ip] = mac
    except Exception:
        pass

    try:
        txt = subprocess.check_output(["ip", "neigh", "show"], text=True, stderr=subprocess.DEVNULL)
        for line in txt.splitlines():
            parts = line.split()
            if len(parts) >= 5 and "lladdr" in parts:
                ip = parts[0].strip()
                mac = parts[parts.index("lladdr") + 1].strip().upper()
                if mac and mac != "00:00:00:00:00:00" and ":" in mac:
                    out[ip] = mac
    except Exception:
        pass

    return out

# ==================== SIM卡增强：完整的运营商显示 ====================
def _bm_op_from_sta(sta: str) -> str:
    """从 SIM*_STA 取运营商显示，保留完整 '移动(46001)' 形式"""
    return (sta or "").strip()

def istargetdevice(ip: str, user: str, pw: str) -> Tuple[bool, Optional[str]]:
    """同步版本：检测设备是否为目标设备（使用requests）"""
    url = f"http://{ip}/mgr"
    try:
        r = requests.get(url, timeout=TIMEOUT, allow_redirects=False)
        if r.status_code != 401:
            return False, None
        h = r.headers.get("WWW-Authenticate", "")
        if "Digest" not in h:
            return False, None
        m = re.search(r'realm="([^"]+)"', h)
        realm = m.group(1) if m else None
        if realm != "asyncesp":
            return False, realm
        r2 = requests.get(url, timeout=TIMEOUT, auth=requests.auth.HTTPDigestAuth(user, pw))
        return (r2.status_code == 200), realm
    except Exception:
        return False, None

def getdevicedata(ip: str, user: str, pw: str) -> Optional[Dict[str, Any]]:
    """同步版本：获取设备数据（包含SIM*_STA字段）"""
    url = f"http://{ip}/mgr?a=getHtmlData_index"
    # 包含SIM*_STA字段以获取完整运营商信息
    keys = ["DEV_ID","DEV_VER","SIM1_PHNUM","SIM2_PHNUM","SIM1_OP","SIM2_OP","SIM1_STA","SIM2_STA"]
    payload = {"keys": keys}
    try:
        r = requests.post(
            url,
            timeout=TIMEOUT,
            auth=requests.auth.HTTPDigestAuth(user, pw),
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            data={"keys": json.dumps(payload, ensure_ascii=False)},
        )
        if r.status_code != 200:
            return None
        j = r.json()
        if isinstance(j, dict) and j.get("success") and isinstance(j.get("data"), dict):
            return j["data"]
        return None
    except Exception:
        return None

def upsertdevice(db: Session, ip: str, mac: str, user: str, pw: str, grp: Optional[str] = None) -> Dict[str, Any]:
    """同步版本：插入或更新设备（集成SIM卡增强）"""
    data = getdevicedata(ip, user, pw) or {}
    devid = (data.get("DEV_ID") or "").strip() or None
    sim1num = (data.get("SIM1_PHNUM") or "").strip()
    sim2num = (data.get("SIM2_PHNUM") or "").strip()
    
    # SIM卡增强：优先使用SIM*_OP，如果为空则使用SIM*_STA
    sim1op = ((data.get("SIM1_OP") or "").strip() or _bm_op_from_sta(data.get("SIM1_STA") or ""))
    sim2op = ((data.get("SIM2_OP") or "").strip() or _bm_op_from_sta(data.get("SIM2_STA") or ""))

    mac = (mac or "").strip().upper() or None

    # 先按 DEV_ID / MAC / IP 查找（唯一性优先级）
    device: Optional[Device] = None
    if devid:
        device = db.query(Device).filter(Device.devId == devid).first()
    if not device and mac:
        device = db.query(Device).filter(Device.mac == mac).first()
    if not device:
        device = db.query(Device).filter(Device.ip == ip).first()

    # 如果我们是通过 devid/mac 找到设备，且当前 ip 已被"历史重复记录"占用，则清理冲突记录
    if device and device.ip != ip:
        other = db.query(Device).filter(Device.ip == ip).first()
        if other and other.id != device.id:
            try:
                db.delete(other)
                db.flush()
            except Exception:
                db.rollback()
                # 清理失败不影响主流程，继续更新
                db.begin()

    if device:
        # 更新现有设备
        device.devId = devid if devid else device.devId
        # ✅ 扫描默认不覆盖分组：只有显式传 grp 才更新
        if grp is not None and str(grp).strip() != "":
            device.grp = grp
        device.ip = ip
        device.mac = (mac if mac else device.mac)
        device.user = user
        device.passwd = pw
        device.status = 'online'
        device.lastSeen = nowts()
        device.sim1number = sim1num
        device.sim1operator = sim1op  # 使用增强后的运营商信息
        device.sim2number = sim2num
        device.sim2operator = sim2op  # 使用增强后的运营商信息
    else:
        # 插入新设备
        device = Device(
            devId=devid,
            grp=(grp if grp is not None and str(grp).strip() != "" else "auto"),
            ip=ip,
            mac=(mac or ""),
            user=user,
            passwd=pw,
            status='online',
            lastSeen=nowts(),
            sim1number=sim1num,
            sim1operator=sim1op,  # 使用增强后的运营商信息
            sim2number=sim2num,
            sim2operator=sim2op,  # 使用增强后的运营商信息
            created=subprocess.check_output(["date", "+%Y-%m-%d %H:%M:%S"], text=True).strip()
        )
        db.add(device)

    db.commit()
    db.refresh(device)

    return {
        "id": device.id,
        "devId": device.devId or "",
        "alias": device.alias or "",
        "grp": device.grp or "auto",
        "ip": device.ip,
        "mac": device.mac or "",
        "status": device.status or "unknown",
        "lastSeen": device.lastSeen or 0,
        "created": device.created or "",
        "sims": {
            "sim1": {
                "number": device.sim1number or "", 
                "operator": device.sim1operator or "", 
                "label": (device.sim1number or device.sim1operator or "SIM")
            },
            "sim2": {
                "number": device.sim2number or "", 
                "operator": device.sim2operator or "", 
                "label": (device.sim2number or device.sim2operator or "SIM")
            },
        }
    }

def listdevices(db: Session):
    devices = db.query(Device).order_by(Device.created.desc(), Device.id.desc()).all()
    out = []
    for d in devices:
        out.append({
          "id": d.id,
          "devId": d.devId or "",
          "alias": d.alias or "",
          "grp": d.grp or "auto",
          "ip": d.ip,
          "mac": d.mac or "",
          "status": d.status or "unknown",
          "lastSeen": d.lastSeen or 0,
          "created": d.created or "",
          "sims": {
            "sim1": {
                "number": d.sim1number or "", 
                "operator": d.sim1operator or "", 
                "label": (d.sim1number or d.sim1operator or "SIM")
            },
            "sim2": {
                "number": d.sim2number or "", 
                "operator": d.sim2operator or "", 
                "label": (d.sim2number or d.sim2operator or "SIM")
            },
          }
        })
    return out

def getallnumbers(db: Session):
    devices = db.query(Device).all()
    numbers = []
    for d in devices:
      if d.sim1number and d.sim1number.strip():
        numbers.append({
          "deviceId": d.id,
          "deviceName": d.devId or d.ip,
          "ip": d.ip,
          "number": d.sim1number.strip(),
          "operator": d.sim1operator or "",
          "slot": 1
        })
      if d.sim2number and d.sim2number.strip():
        numbers.append({
          "deviceId": d.id,
          "deviceName": d.devId or d.ip,
          "ip": d.ip,
          "number": d.sim2number.strip(),
          "operator": d.sim2operator or "",
          "slot": 2
        })
    return numbers

class DirectSmsReq(BaseModel):
    deviceId: int
    phone: str
    content: str
    slot: int


class DirectDialReq(BaseModel):
    deviceId: int
    slot: int
    phone: str
    tts: str = ""
    duration: int = 175
    tts_times: int = 2
    tts_pause: int = 1
    after_action: int = 1

@app.get("/api/health")
def health():
    return {"status":"ok", "message":"Board LAN Hub API is running"}

# ===== 设备别名/分组 =====
class AliasReq(BaseModel):
    alias: str

@app.post("/api/devices/{devid}/alias")
def api_set_alias(devid: int, req: AliasReq, db: Session = Depends(get_db)):
    alias = (req.alias or "").strip()
    if len(alias) > 24:
        raise HTTPException(400, "alias too long")
    
    device = db.query(Device).filter(Device.id == devid).first()
    if not device:
        raise HTTPException(404, "Device not found")
    
    device.alias = alias
    db.commit()
    return {"ok": True}

class GroupReq(BaseModel):
    group: str

@app.post("/api/devices/{devid}/group")
def api_set_group(devid: int, req: GroupReq, db: Session = Depends(get_db)):
    group = (req.group or "").strip() or "auto"
    
    device = db.query(Device).filter(Device.id == devid).first()
    if not device:
        raise HTTPException(404, "Device not found")
    
    device.grp = group
    db.commit()
    return {"ok": True}

# ===== 增强版批量转发（保持第二版本功能）=====
class EnhancedBatchForwardReq(BaseModel):
    device_ids: List[int]
    forward_method: str
    forwardUrl: str = ""
    notifyUrl: str = ""
    deviceKey0: str = ""
    deviceKey1: str = ""
    deviceKey2: str = ""
    smtpProvider: str = ""
    smtpServer: str = ""
    smtpPort: str = ""
    smtpAccount: str = ""
    smtpPassword: str = ""
    smtpFromEmail: str = ""
    smtpToEmail: str = ""
    smtpEncryption: str = ""
    webhookUrl1: str = ""
    webhookUrl2: str = ""
    webhookUrl3: str = ""
    signKey1: str = ""
    signKey2: str = ""
    signKey3: str = ""
    sc3ApiUrl: str = ""
    sctSendKey: str = ""
    PPToken: str = ""
    PPChannel: str = ""
    PPWebhook: str = ""
    PPFriends: str = ""
    PPGroupId: str = ""
    WPappToken: str = ""
    WPUID: str = ""
    WPTopicId: str = ""
    lyApiUrl: str = ""

@app.post("/api/devices/batch/enhanced-forward")
async def api_enhanced_batch_forward(req: EnhancedBatchForwardReq, db: Session = Depends(get_db)):
    if not req.device_ids:
        raise HTTPException(400, "device_ids required")
    
    results = []
    
    with concurrent.futures.ThreadPoolExecutor(max_workers=CONCURRENCY) as executor:
        futures = []
        devices = db.query(Device).filter(Device.id.in_(req.device_ids)).all()
        
        for device in devices:
            future = executor.submit(
                enhanced_forward_task_sync,
                device,
                req
            )
            futures.append((device.id, future))
        
        for dev_id, future in futures:
            result = future.result()
            results.append(result)
    
    return {"results": results}

def enhanced_forward_task_sync(device: Device, req: EnhancedBatchForwardReq) -> Dict[str, Any]:
    """同步版本的增强转发任务"""
    ip = device.ip
    user = (device.user or DEFAULTUSER).strip()
    pw = (device.passwd or DEFAULTPASS).strip()
    
    try:
        # 检查设备是否可达
        ok, _ = istargetdevice(ip, user, pw)
        if not ok:
            return {"id": device.id, "ip": ip, "ok": False, "error": "auth failed"}
        
        # 构建请求数据
        form_data = {"method": req.forward_method}
        
        if req.forward_method == "0":
            pass
        elif req.forward_method in ["1", "2"]:  # Bark
            form_data.update({
                "BARK_DEVICE_KEY0": req.deviceKey0,
                "BARK_DEVICE_KEY1": req.deviceKey1,
                "BARK_DEVICE_KEY2": req.deviceKey2
            })
        elif req.forward_method == "8":  # SMTP
            form_data.update({
                "SMTP_PROVIDER": req.smtpProvider,
                "SMTP_SERVER": req.smtpServer,
                "SMTP_PORT": req.smtpPort,
                "SMTP_ACCOUNT": req.smtpAccount,
                "SMTP_PASSWORD": req.smtpPassword,
                "SMTP_FROM_EMAIL": req.smtpFromEmail,
                "SMTP_TO_EMAIL": req.smtpToEmail,
                "SMTP_ENCRYPTION": req.smtpEncryption
            })
        elif req.forward_method in ["10", "11", "16"]:  # 企业微信/飞书
            form_data.update({
                "WDF_CWH_URL1": req.webhookUrl1,
                "WDF_CWH_URL2": req.webhookUrl2,
                "WDF_CWH_URL3": req.webhookUrl3
            })
        elif req.forward_method == "13":  # 钉钉
            form_data.update({
                "WDF_CWH_URL1": req.webhookUrl1,
                "WDF_CWH_URL2": req.webhookUrl2,
                "WDF_CWH_URL3": req.webhookUrl3,
                "WDF_SIGN_KEY1": req.signKey1,
                "WDF_SIGN_KEY2": req.signKey2,
                "WDF_SIGN_KEY3": req.signKey3
            })
        elif req.forward_method == "22":  # Server酱3
            form_data.update({
                "SC3_URL": req.sc3ApiUrl
            })
        elif req.forward_method == "21":  # Server酱Turbo
            form_data.update({
                "SCT_SEND_KEY": req.sctSendKey
            })
        elif req.forward_method == "30":  # PushPlus
            form_data.update({
                "PPToken": req.PPToken,
                "PPChannel": req.PPChannel,
                "PPWebhook": req.PPWebhook,
                "PPFriends": req.PPFriends,
                "PPGroupId": req.PPGroupId
            })
        elif req.forward_method == "35":  # WxPusher
            form_data.update({
                "WPappToken": req.WPappToken,
                "WPUID": req.WPUID,
                "WPTopicId": req.WPTopicId
            })
        elif req.forward_method == "90":  # 绿微平台
            form_data.update({
                "LYWEB_API_URL": req.lyApiUrl
            })
        else:
            # 通用URL方式
            form_data.update({
                "forwardUrl": req.forwardUrl,
                "notifyUrl": req.notifyUrl
            })
        
        # 发送配置请求
        resp = requests.post(
            f"http://{ip}/saveForwardConfig",
            data=form_data,
            timeout=TIMEOUT + 5,
            auth=requests.auth.HTTPDigestAuth(user, pw)
        )
        
        return {
            "id": device.id, 
            "ip": ip, 
            "ok": resp.status_code == 200, 
            "status": resp.status_code
        }
        
    except Exception as e:
        return {
            "id": device.id, 
            "ip": ip, 
            "ok": False, 
            "error": str(e)
        }

# ===== 批量 WiFi =====
class BatchWifiReq(BaseModel):
    device_ids: List[int]
    ssid: str
    pwd: str

@app.post("/api/devices/batch/wifi")
def api_batch_wifi(req: BatchWifiReq, db: Session = Depends(get_db)):
    if not req.device_ids:
        raise HTTPException(400, "device_ids required")
    
    results = []
    
    with concurrent.futures.ThreadPoolExecutor(max_workers=CONCURRENCY) as executor:
        futures = []
        devices = db.query(Device).filter(Device.id.in_(req.device_ids)).all()
        
        for device in devices:
            future = executor.submit(
                wifi_task_sync,
                device,
                req.ssid,
                req.pwd
            )
            futures.append((device.id, future))
        
        for dev_id, future in futures:
            result = future.result()
            results.append(result)
    
    return {"results": results}

def wifi_task_sync(device: Device, ssid: str, pwd: str) -> Dict[str, Any]:
    """同步版本的WiFi配置任务"""
    ip = device.ip
    user = (device.user or DEFAULTUSER).strip()
    pw = (device.passwd or DEFAULTPASS).strip()
    
    try:
        ok, _ = istargetdevice(ip, user, pw)
        if not ok:
            return {"id": device.id, "ip": ip, "ok": False, "error": "auth failed"}
        
        resp = requests.get(
            f"http://{ip}/ap",
            params={"a": "apadd", "ssid": ssid, "pwd": pwd},
            timeout=TIMEOUT + 5,
            auth=requests.auth.HTTPDigestAuth(user, pw)
        )
        return {"id": device.id, "ip": ip, "ok": resp.status_code == 200, "status": resp.status_code}
    except Exception as e:
        return {"id": device.id, "ip": ip, "ok": False, "error": str(e)}

# ===== SIM 单台/批量 =====
class SimReq(BaseModel):
    sim1: str = ''
    sim2: str = ''

@app.post("/api/devices/{devid}/sim")
def api_set_sim(devid: int, req: SimReq, db: Session = Depends(get_db)):
    device = db.query(Device).filter(Device.id == devid).first()
    if not device:
        raise HTTPException(404, "Device not found")
    
    ip = device.ip
    user = (device.user or DEFAULTUSER).strip()
    pw = (device.passwd or DEFAULTPASS).strip()
    
    try:
        resp = requests.post(
            f"http://{ip}/mgr",
            params={"a": "updatePhnum"},
            data={"sim1Phnum": req.sim1, "sim2Phnum": req.sim2},
            timeout=TIMEOUT + 5,
            auth=requests.auth.HTTPDigestAuth(user, pw)
        )
        
        if resp.status_code == 200:
            device.sim1number = req.sim1
            device.sim2number = req.sim2
            db.commit()
            return {"ok": True}
        return {"ok": False, "status": resp.status_code}
    except Exception as e:
        return {"ok": False, "error": str(e)}

class BatchSimReq(BaseModel):
    device_ids: List[int]
    sim1: str = ''
    sim2: str = ''

@app.post("/api/devices/batch/sim")
def api_batch_sim(req: BatchSimReq, db: Session = Depends(get_db)):
    if not req.device_ids:
        raise HTTPException(400, "device_ids required")
    
    results = []
    
    with concurrent.futures.ThreadPoolExecutor(max_workers=CONCURRENCY) as executor:
        futures = []
        devices = db.query(Device).filter(Device.id.in_(req.device_ids)).all()
        
        for device in devices:
            future = executor.submit(
                sim_task_sync,
                device,
                req.sim1,
                req.sim2
            )
            futures.append((device.id, future))
        
        for dev_id, future in futures:
            result = future.result()
            results.append(result)
    
    return {"results": results}

def sim_task_sync(device: Device, sim1: str, sim2: str) -> Dict[str, Any]:
    """同步版本的SIM卡配置任务"""
    ip = device.ip
    user = (device.user or DEFAULTUSER).strip()
    pw = (device.passwd or DEFAULTPASS).strip()
    
    try:
        resp = requests.post(
            f"http://{ip}/mgr",
            params={"a": "updatePhnum"},
            data={"sim1Phnum": sim1, "sim2Phnum": sim2},
            timeout=TIMEOUT + 5,
            auth=requests.auth.HTTPDigestAuth(user, pw)
        )
        
        return {"id": device.id, "ip": ip, "ok": resp.status_code == 200, "status": resp.status_code}
    except Exception as e:
        return {"id": device.id, "ip": ip, "ok": False, "error": str(e)}

@app.get("/api/devices/{devid}/detail")
def api_device_detail(devid: int, db: Session = Depends(get_db)):
    device = db.query(Device).filter(Device.id == devid).first()
    if not device:
        raise HTTPException(404, "Device not found")
    
    device_dict = {
        "id": device.id,
        "devId": device.devId or "",
        "alias": device.alias or "",
        "grp": device.grp or "auto",
        "ip": device.ip,
        "mac": device.mac or "",
        "status": device.status or "unknown",
        "lastSeen": device.lastSeen or 0,
        "created": device.created or "",
        "sim1number": device.sim1number or "",
        "sim1operator": device.sim1operator or "",
        "sim2number": device.sim2number or "",
        "sim2operator": device.sim2operator or "",
        "user": device.user or "",
        "pass": device.passwd or ""
    }
    
    return {"device": device_dict, "forwardconfig": {}, "wifilist": []}

@app.get("/api/devices")
def apidevices(db: Session = Depends(get_db)):
    return listdevices(db)

@app.get("/api/numbers")
def apinumbers(db: Session = Depends(get_db)):
    return getallnumbers(db)

@app.delete("/api/devices/{dev_id}")
def deletedevice(dev_id: int, db: Session = Depends(get_db)):
    device = db.query(Device).filter(Device.id == dev_id).first()
    if not device:
        raise HTTPException(404, "Device not found")
    
    db.delete(device)
    db.commit()
    return {"ok": True, "message": "Device deleted"}

class BatchDeleteReq(BaseModel):
    device_ids: List[int]

@app.post("/api/devices/batch/delete")
def api_batch_delete(req: BatchDeleteReq, db: Session = Depends(get_db)):
    if not req.device_ids:
        raise HTTPException(400, "device_ids required")
    deleted = 0
    for dev_id in req.device_ids:
        device = db.query(Device).filter(Device.id == dev_id).first()
        if device:
            db.delete(device)
            deleted += 1
    db.commit()
    return {"ok": True, "deleted": deleted}


class BatchDeleteReq(BaseModel):
    device_ids: List[int]

@app.post("/api/devices/batch/delete")
def api_batch_delete(req: BatchDeleteReq, db: Session = Depends(get_db)):
    if not req.device_ids:
        raise HTTPException(400, "device_ids required")
    deleted = 0
    for dev_id in req.device_ids:
        device = db.query(Device).filter(Device.id == dev_id).first()
        if device:
            db.delete(device)
            deleted += 1
    db.commit()
    return {"ok": True, "deleted": deleted}


@app.post("/api/sms/send-direct")
def smssenddirect(req: DirectSmsReq, db: Session = Depends(get_db)):
    if req.slot not in (1, 2):
        raise HTTPException(400, "slot must be 1 or 2")
    phone = req.phone.strip()
    content = req.content.strip()
    if not phone or not content:
        raise HTTPException(400, "phone/content required")

    device = db.query(Device).filter(Device.id == req.deviceId).first()
    if not device:
        raise HTTPException(404, "Device not found")

    ip = device.ip
    user = (device.user or DEFAULTUSER).strip()
    pw = (device.passwd or DEFAULTPASS).strip()

    try:
        ok, _ = istargetdevice(ip, user, pw)
        if not ok:
            raise HTTPException(400, "Device authentication failed")

        resp = requests.get(
            f"http://{ip}/mgr",
            params={"a": "sendsms", "sid": str(req.slot), "phone": phone, "content": content},
            timeout=TIMEOUT + 3,
            auth=requests.auth.HTTPDigestAuth(user, pw)
        )
        
        if resp.status_code == 200:
            try:
                j = resp.json()
                if isinstance(j, dict) and j.get("success") is True:
                    return {"ok": True, "message": "SMS sent successfully"}
                return {"ok": False, "error": f"device response: {j}"}
            except Exception:
                return {"ok": False, "error": "non-json response"}
        return {"ok": False, "error": f"http {resp.status_code}"}
    except Exception as e:
        return {"ok": False, "error": str(e)}

# ==================== 修复的扫描函数（使用第一版本的逻辑）====================
@app.post("/api/scan/start")
def scanstart(
    cidr: Optional[str] = None, 
    group: Optional[str] = None, 
    user: str = DEFAULTUSER, 
    password: str = DEFAULTPASS,
    db: Session = Depends(get_db)
):
    """扫描内网设备（使用第一版本的可靠逻辑）"""
    if not cidr:
        cidr = guessipv4cidr()

    try:
        net = ip_network(cidr, strict=False)
        if not isinstance(net, IPv4Network):
            raise ValueError("only IPv4 supported scan")
    except Exception as e:
        raise HTTPException(400, f"bad cidr: {e}")

    arptable = getarptable()

    arp_ips: List[str] = []
    if arptable:
        for ip in arptable.keys():
            try:
                if ip_address(ip) in net:
                    arp_ips.append(ip)
            except Exception:
                continue

    # Always add a bounded hosts() scan so we don't miss devices not in ARP/neighbor table.
    host_ips: List[str] = [str(h) for h in islice(net.hosts(), CIDRFALLBACKLIMIT)]

    iplist: List[str] = []
    seen = set()
    for ip in (arp_ips + host_ips):
        if ip in seen:
            continue
        seen.add(ip)
        iplist.append(ip)
        if len(iplist) >= CIDRFALLBACKLIMIT:
            break
        iplist = iplist[:CIDRFALLBACKLIMIT]

    found: List[Dict[str, Any]] = []
    found_lock = threading.Lock()
    
    # 线程池函数
    def probe(ip: str):
        ok, _ = istargetdevice(ip, user, password)
        if ok:
            mac = arptable.get(ip, "")
            # 每个线程使用独立的数据库会话
            thread_db = SessionLocal()
            try:
                d = upsertdevice(thread_db, ip, mac, user, password, group)
                with found_lock:
                    found.append(d)
            finally:
                thread_db.close()
            return True
        return False
    
    # 使用线程池进行并发扫描
    with concurrent.futures.ThreadPoolExecutor(max_workers=CONCURRENCY) as executor:
        futures = {executor.submit(probe, ip): ip for ip in iplist}
        for future in concurrent.futures.as_completed(futures):
            future.result()
    
    return {
        "ok": True, 
        "cidr": cidr, 
        "found": len(found), 
        "devices": [{"ip": d["ip"], "devId": d.get("devId", "")} for d in found]
    }

# ===== dial token helpers =====
def _get_timeout_default() -> int:
    for name in ("TIMEOUT", "REQUEST_TIMEOUT", "HTTP_TIMEOUT"):
        v = globals().get(name)
        if isinstance(v, (int, float)):
            return int(v)
    return 8

def fetch_device_token(ip: str, user: str, pw: str) -> str:
    timeout = _get_timeout_default()
    url = f"http://{ip}/mgr?a=getHtmlData_passwdMgr"
    body = 'keys=%7B%22keys%22%3A%5B%22TOKEN%22%5D%7D'
    r = requests.post(
        url,
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        timeout=timeout + 5,
        auth=requests.auth.HTTPDigestAuth(user, pw),
    )
    r.raise_for_status()
    j = r.json()
    tok = (j.get("data", {}) or {}).get("TOKEN", "") or ""
    tok = re.sub(r"<[^>]+>", "", str(tok)).strip()
    return tok

def ensure_device_token(db: Session, device: Device) -> str:
    tok = (getattr(device, "token", "") or "").strip()
    if tok:
        return tok
    user = (getattr(device, "user", "") or DEFAULTUSER).strip()
    pw = (getattr(device, "passwd", "") or DEFAULTPASS).strip()
    ok, _ = istargetdevice(device.ip, user, pw)
    if not ok:
        raise HTTPException(400, "Device authentication failed")
    tok = fetch_device_token(device.ip, user, pw)
    if not tok:
        raise HTTPException(400, "Failed to fetch token")
    try:
        device.token = tok
        db.commit()
    except Exception:
        pass
    return tok
# ===== end helpers =====

@app.post("/api/tel/dial")
def tel_dial(req: DirectDialReq, db: Session = Depends(get_db)):
    if req.slot not in (1, 2):
        raise HTTPException(400, "slot must be 1 or 2")
    phone = (req.phone or "").strip()
    if not phone:
        raise HTTPException(400, "phone required")

    device = db.query(Device).filter(Device.id == req.deviceId).first()
    if not device:
        raise HTTPException(404, "Device not found")

    token = ensure_device_token(db, device)

    timeout = _get_timeout_default()
    params = {
        "token": token,
        "cmd": "teldial",
        "p1": str(req.slot),
        "p2": phone,
        "p3": str(max(10, int(req.duration or 175))),
        "p4": (req.tts or "").strip(),
        "p5": str(max(0, int(req.tts_times or 0))),
        "p6": str(max(0, int(req.tts_pause or 0))),
        "p7": str(int(req.after_action or 0)),
    }

    try:
        resp = requests.get(f"http://{device.ip}/ctrl", params=params, timeout=timeout + 8)
        try:
            j = resp.json()
        except Exception:
            j = {"raw": resp.text}
        if resp.status_code == 200 and isinstance(j, dict) and j.get("code", 0) == 0:
            return {"ok": True, "resp": j}
        return {"ok": False, "error": j}
    except Exception as e:
        return {"ok": False, "error": str(e)}

PY

  log_info "后端已写入（集成SIM卡增强）"
  log_info "配置文件已创建: $CONFIG_FILE"
}

# 集成补丁的前端UI：两行紧凑SIM卡显示
writefrontendstatic(){
  title "部署前端（集成SIM卡增强显示）"
  local FE="${APPDIR}/frontend"
  mkdir -p "${FE}/src"

  cat > "${FE}/package.json" <<'PKG'
{
  "name": "board-lan-ui",
  "version": "3.2.2",
  "private": true,
  "type": "module",
  "scripts": { "build": "vite build" },
  "dependencies": { "axios": "^1.6.0", "vue": "^3.4.0" },
  "devDependencies": { "@vitejs/plugin-vue": "^5.0.0", "vite": "^5.4.11" }
}
PKG

  cat > "${FE}/vite.config.js" <<VITECFG
import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
export default defineConfig({
  plugins: [vue()],
  base: '/static/',
  build: { outDir: 'dist', emptyOutDir: true }
})
VITECFG

  cat > "${FE}/index.html" <<'HTML'
<!doctype html>
<html lang="zh-CN">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover" />
    <meta name="theme-color" content="#0f172a" />
    <title>绿邮X系列内网群控 v3.2.2</title>
  </head>
  <body>
    <div id="app"></div>
    <script type="module" src="/src/main.js"></script>
  </body>
</html>
HTML

  cat > "${FE}/src/main.js" <<'JS'
import { createApp } from 'vue'
import App from './App.vue'
createApp(App).mount('#app')
JS

  # ==================== 集成补丁的前端UI：两行紧凑显示 ====================
  cat > "${FE}/src/App.vue" <<'VUE_COMPLETE'
<script setup>
import { ref, computed, onMounted, watch } from 'vue'
import axios from 'axios'

const api = axios.create({ baseURL: '' })

const uiPass = ref('')
const authed = ref(false)
const loading = ref(false)
const notice = ref({ text: '', type: 'info' })

function setNotice(text, type = 'info') {
  notice.value = { text, type }
}
function clearNotice() {
  notice.value = { text: '', type: 'info' }
}
function setAuth(pw) {
  const token = window.btoa(`admin:${pw}`)
  api.defaults.headers.common['Authorization'] = `Basic ${token}`
  // 保存到 localStorage
  localStorage.setItem('board_mgr_auth_token', token)
  localStorage.setItem('board_mgr_auth_time', Date.now().toString())
}
async function login() {
  if (!uiPass.value.trim()) return setNotice('请输入密码', 'err')
  setAuth(uiPass.value.trim())
  loading.value = true
  try {
    await api.get('/api/health')
    authed.value = true
    setNotice('登录成功', 'ok')
    await refresh()
  } catch (e) {
    authed.value = false
    setNotice(e?.response?.data?.detail || '密码错误或无权限', 'err')
  } finally {
    loading.value = false
  }
}
function logout() {
  authed.value = false
  uiPass.value = ''
  delete api.defaults.headers.common['Authorization']
  localStorage.removeItem('board_mgr_auth_token')
  localStorage.removeItem('board_mgr_auth_time')
}

// 页面加载时检查是否有保存的token
onMounted(() => {
  const savedToken = localStorage.getItem('board_mgr_auth_token')
  const savedTime = localStorage.getItem('board_mgr_auth_time')
  
  // 如果token存在且是7天内保存的（604800000毫秒）
  if (savedToken && savedTime && (Date.now() - parseInt(savedTime) < 604800000)) {
    api.defaults.headers.common['Authorization'] = `Basic ${savedToken}`
    authed.value = true
    api.get('/api/health').then(() => {
      refresh()
    }).catch(() => {
      logout()
      setNotice('登录已过期，请重新登录', 'err')
    })
  }
})

const devices = ref([])
const numbers = ref([])

const activeTab = ref('devices')
const searchText = ref('')
const groupFilter = ref('all')

const fromSelected = ref('')
const toPhone = ref('')
const content = ref('')

const commMode = ref('sms')
const dialPhone = ref('')
const ttsText = ref('')

const selectedIds = ref([])
const selectAll = ref(false)

const showForwardModal = ref(false)
const showEnhancedForwardModal = ref(false)
const showWifiModal = ref(false)
const showSimModal = ref(false)
const showDetailModal = ref(false)

const forwardUrl = ref('')
const notifyUrl = ref('')

// 增强转发配置
const forwardMethod = ref('0')
const enhancedForwardConfig = ref({
  deviceKey0: '',
  deviceKey1: '',
  deviceKey2: '',
  smtpProvider: '1',
  smtpServer: '',
  smtpPort: '',
  smtpAccount: '',
  smtpPassword: '',
  smtpFromEmail: '',
  smtpToEmail: '',
  smtpEncryption: 'starttls',
  webhookUrl1: '',
  webhookUrl2: '',
  webhookUrl3: '',
  signKey1: '',
  signKey2: '',
  signKey3: '',
  sc3ApiUrl: '',
  sctSendKey: '',
  PPToken: '',
  PPChannel: '',
  PPWebhook: '',
  PPFriends: '',
  PPGroupId: '',
  WPappToken: '',
  WPUID: '',
  WPTopicId: '',
  lyApiUrl: ''
})

const wifiSsid = ref('')
const wifiPwd = ref('')

const sim1Number = ref('')
const sim2Number = ref('')

const deviceDetail = ref(null)

// SMTP配置映射
const smtpConfigs = {
  '1': { domain: '', server: 'smtp.163.com', port: '465' },
  '2': { domain: 'vip.163.com', server: 'smtp.vip.163.com', port: '465' },
  '3': { domain: '', server: 'smtp.ym.163.com', port: '465' },
  '10': { domain: '', server: 'smtp.qq.com', port: '465' },
  '11': { domain: '', server: 'smtp.exmail.qq.com', port: '465' },
  '20': { domain: 'aliyun.com', server: 'smtp.aliyun.com', port: '465' },
  '21': { domain: '', server: 'smtp.qiye.aliyun.com', port: '465' },
  '30': { domain: '139.com', server: 'smtp.139.com', port: '465' },
  '33': { domain: 'wo.com', server: 'smtp.wo.cn', port: '465' },
  '36': { domain: '189.cn', server: 'smtp.189.cn', port: '465' },
  '37': { domain: '21cn.com', server: 'smtp.21cn.com', port: '465' },
  '40': { domain: '', server: 'smtp.sina.com', port: '465' },
  '41': { domain: 'sohu.com', server: 'smtp.sohu.com', port: '465' },
  '42': { domain: '', server: 'smtp.zoho.com', port: '465' },
  '43': { domain: '', server: 'smtp.88.com', port: '465' },
  '50': { domain: '', server: 'smtp.office365.com', port: '587' },
  '51': { domain: 'yahoo.com', server: 'smtp.mail.yahoo.com', port: '465' },
  '52': { domain: 'icloud.com', server: 'smtp.mail.me.com', port: '465' },
  '53': { domain: 'gmail.com', server: 'smtp.gmail.com', port: '465' },
  '54': { domain: 'aol.com', server: 'smtp.aol.com', port: '465' },
  '55': { domain: 'yandex.com', server: 'smtp.yandex.com', port: '465' },
  '56': { domain: 'mail.ru', server: 'smtp.mail.ru', port: '465' },
  '999': { domain: '', server: '', port: '' }
}

watch(() => enhancedForwardConfig.value.smtpProvider, (newVal) => {
  const config = smtpConfigs[newVal]
  if (config && newVal !== '999') {
    enhancedForwardConfig.value.smtpServer = config.server
    enhancedForwardConfig.value.smtpPort = config.port
  }
})

function prettyTime(ts) {
  if (!ts) return '-'
  return new Date(ts * 1000).toLocaleString('zh-CN', {
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  })
}
function displayName(d) {
  return (d?.alias || d?.devId || '').trim() || '-'
}
function splitAlphaNum(s) {
  const str = (s || '').trim()
  const m = str.match(/^([A-Za-z]*)(\d+)?$/)
  if (!m) return { a: str.toUpperCase(), n: null, raw: str.toUpperCase() }
  return { a: (m[1] || '').toUpperCase(), n: m[2] ? parseInt(m[2], 10) : null, raw: str.toUpperCase() }
}
function cmpNatural(a, b) {
  const A = splitAlphaNum(a)
  const B = splitAlphaNum(b)
  if (A.a !== B.a) return A.a < B.a ? -1 : 1
  if (A.n !== null && B.n !== null && A.n !== B.n) return A.n - B.n
  if (A.n === null && B.n !== null) return 1
  if (A.n !== null && B.n === null) return -1
  if (A.raw !== B.raw) return A.raw < B.raw ? -1 : 1
  return 0
}

const uniqueGroups = computed(() => {
  const g = new Set(devices.value.map(d => (d.grp || 'auto')))
  return ['all', ...Array.from(g).sort()]
})

const filteredDevices = computed(() => {
  const t = searchText.value.trim().toLowerCase()
  let arr = devices.value

  if (groupFilter.value !== 'all') {
    arr = arr.filter(d => (d.grp || 'auto') === groupFilter.value)
  }
  if (t) {
    arr = arr.filter(d =>
      displayName(d).toLowerCase().includes(t) ||
      (d.ip || '').toLowerCase().includes(t) ||
      (d.mac || '').toLowerCase().includes(t) ||
      (d.sims?.sim1?.number || '').includes(t) ||
      (d.sims?.sim2?.number || '').includes(t) ||
      (d.sims?.sim1?.operator || '').toLowerCase().includes(t) ||
      (d.sims?.sim2?.operator || '').toLowerCase().includes(t)
    )
  }
  return [...arr].sort((x, y) => cmpNatural(displayName(x), displayName(y)))
})

const filteredNumbers = computed(() => {
  const t = searchText.value.trim().toLowerCase()
  if (!t) return numbers.value
  return numbers.value.filter(n =>
    (n.number || '').includes(t) ||
    (n.deviceName || '').toLowerCase().includes(t) ||
    (n.ip || '').toLowerCase().includes(t) ||
    (n.operator || '').toLowerCase().includes(t)
  )
})

const onlineCount = computed(() => devices.value.filter(d => d.status === 'online').length)
const offlineCount = computed(() => devices.value.filter(d => d.status !== 'online').length)
const selectedCount = computed(() => selectedIds.value.length)

function toggleSelectAll() {
  selectedIds.value = selectAll.value ? filteredDevices.value.map(d => d.id) : []
}

async function loadDevices() {
  try {
    const { data } = await api.get('/api/devices')
    devices.value = Array.isArray(data) ? data : []
  } catch (e) {
    setNotice('加载设备失败：' + (e?.response?.data?.detail || e.message), 'err')
  }
}

async function loadNumbers() {
  try {
    const { data } = await api.get('/api/numbers')
    numbers.value = Array.isArray(data) ? data : []
    if (!fromSelected.value && numbers.value.length) {
      const n = numbers.value[0]
      fromSelected.value = `${n.deviceId}|${n.slot}`
    }
  } catch (e) {
    setNotice('加载号码失败：' + (e?.response?.data?.detail || e.message), 'err')
  }
}

async function refresh() {
  loading.value = true
  try {
    await loadDevices()
    await loadNumbers()
  } catch (e) {
    if (e?.response?.status === 401) {
      logout()
      setNotice('登录已过期，请重新登录', 'err')
    } else {
      setNotice(e?.response?.data?.detail || e.message, 'err')
    }
  } finally {
    loading.value = false
  }
}

async function startScanAdd() {
  loading.value = true
  setNotice('扫描中，请稍候...', 'info')
  try {
    const { data } = await api.post('/api/scan/start')
    setNotice(`扫描完成：找到 ${data.found} 台设备 (网段: ${data.cidr})`, data.found > 0 ? 'ok' : 'warn')
    await refresh()
  } catch (e) {
    setNotice(e?.response?.data?.detail || e.message, 'err')
  } finally {
    loading.value = false
  }
}

async function send() {
  if (!fromSelected.value) return setNotice('请选择发送卡', 'err')
  if (!toPhone.value.trim()) return setNotice('请输入收件号码', 'err')
  if (!content.value.trim()) return setNotice('请输入短信内容', 'err')
  const [deviceId, slot] = fromSelected.value.split('|')

  loading.value = true
  try {
    const payload = { deviceId: Number(deviceId), slot: Number(slot), phone: toPhone.value.trim(), content: content.value.trim() }
    const { data } = await api.post('/api/sms/send-direct', payload)
    if (data.ok) setNotice('发送成功', 'ok')
    else setNotice(data.error || '发送失败', 'err')
  } catch (e) {
    setNotice(e?.response?.data?.error || e?.response?.data?.detail || e.message, 'err')
  } finally {
    loading.value = false
  }
}

async function dial() {
  if (!fromSelected.value) return setNotice('请选择外呼卡', 'err')
  if (!dialPhone.value.trim()) return setNotice('请输入号码', 'err')
  const [deviceId, slot] = fromSelected.value.split('|')
  loading.value = true
  try {
    const payload = { deviceId: Number(deviceId), slot: Number(slot), phone: dialPhone.value.trim(), tts: (ttsText.value || '').trim() }
    const { data } = await api.post('/api/tel/dial', payload)
    if (data.ok) setNotice('已发起拨号', 'ok')
    else setNotice((data.error && (data.error.detail || data.error)) || '拨号失败', 'err')
  } catch (e) {
    setNotice(e?.response?.data?.detail || e?.response?.data?.error || e.message, 'err')
  } finally {
    loading.value = false
  }
}

async function renameDevice(d) {
  const v = window.prompt('输入别名(最多24字符):', d.alias || '')
  if (v === null) return
  loading.value = true
  try {
    await api.post(`/api/devices/${d.id}/alias`, { alias: v.trim() })
    await refresh()
    setNotice('已更新别名', 'ok')
  } catch (e) {
    setNotice(e?.response?.data?.detail || e.message, 'err')
  } finally {
    loading.value = false
  }
}

async function setGroup(d) {
  const v = window.prompt('输入分组名:', d.grp || 'auto')
  if (v === null) return
  loading.value = true
  try {
    await api.post(`/api/devices/${d.id}/group`, { group: (v.trim() || 'auto') })
    await refresh()
    setNotice('已更新分组', 'ok')
  } catch (e) {
    setNotice(e?.response?.data?.detail || e.message, 'err')
  } finally {
    loading.value = false
  }
}

async function deleteDevice(id) {
  if (!confirm('确认删除？')) return
  try {
    await api.delete(`/api/devices/${id}`)
    setNotice('已删除', 'ok')
    await refresh()
  } catch (e) {
    setNotice(e?.response?.data?.detail || e.message, 'err')
  }
}

// 旧版转发配置
function openForwardModal() {
  if (!selectedCount.value) return setNotice('请先勾选设备', 'err')
  showForwardModal.value = true
}
function closeForwardModal() {
  showForwardModal.value = false
  forwardUrl.value = ''
  notifyUrl.value = ''
}
async function applyForward() {
  loading.value = true
  try {
    const { data } = await api.post('/api/devices/batch/forward', {
      device_ids: selectedIds.value,
      forwardUrl: forwardUrl.value.trim(),
      notifyUrl: notifyUrl.value.trim(),
    })
    const ok = (data.results || []).filter(r => r.ok).length
    setNotice(`转发配置完成：${ok}/${(data.results || []).length}`, ok ? 'ok' : 'err')
    closeForwardModal()
  } catch (e) {
    setNotice(e?.response?.data?.detail || e.message, 'err')
  } finally {
    loading.value = false
  }
}

// 增强版转发配置
function openEnhancedForwardModal() {
  if (!selectedCount.value) return setNotice('请先勾选设备', 'err')
  showEnhancedForwardModal.value = true
}
function closeEnhancedForwardModal() {
  showEnhancedForwardModal.value = false
  forwardMethod.value = '0'
  Object.keys(enhancedForwardConfig.value).forEach(key => {
    enhancedForwardConfig.value[key] = ''
  })
  enhancedForwardConfig.value.smtpProvider = '1'
  enhancedForwardConfig.value.smtpEncryption = 'starttls'
}
async function applyEnhancedForward() {
  loading.value = true
  try {
    const payload = {
      device_ids: selectedIds.value,
      forward_method: forwardMethod.value,
      ...enhancedForwardConfig.value
    }
    
    const { data } = await api.post('/api/devices/batch/enhanced-forward', payload)
    const ok = (data.results || []).filter(r => r.ok).length
    setNotice(`转发配置完成：${ok}/${(data.results || []).length}`, ok ? 'ok' : 'err')
    closeEnhancedForwardModal()
  } catch (e) {
    setNotice(e?.response?.data?.detail || e.message, 'err')
  } finally {
    loading.value = false
  }
}

function openWifiModal() {
  if (!selectedCount.value) return setNotice('请先勾选设备', 'err')
  showWifiModal.value = true
}
function closeWifiModal() {
  showWifiModal.value = false
  wifiSsid.value = ''
  wifiPwd.value = ''
}
async function applyWifi() {
  if (!wifiSsid.value.trim()) return setNotice('请输入SSID', 'err')
  loading.value = true
  try {
    const { data } = await api.post('/api/devices/batch/wifi', {
      device_ids: selectedIds.value,
      ssid: wifiSsid.value.trim(),
      pwd: wifiPwd.value.trim(),
    })
    const ok = (data.results || []).filter(r => r.ok).length
    setNotice(`WiFi 添加完成：${ok}/${(data.results || []).length}`, ok ? 'ok' : 'err')
  } catch (e) {
    setNotice(e?.response?.data?.detail || e.message, 'err')
  } finally {
    loading.value = false
  }
}

async function batchDeleteSelected() {
  if (!selectedCount.value) return setNotice('请先勾选设备', 'err')
  if (!confirm(`确认删除所选 ${selectedCount.value} 台设备？`)) return
  loading.value = true
  try {
    const { data } = await api.post('/api/devices/batch/delete', { device_ids: selectedIds.value })
    setNotice(`删除完成：${data.deleted || 0}/${selectedCount.value}`, (data.deleted || 0) ? 'ok' : 'warn')
    selectedIds.value = []
    selectAll.value = false
    await refresh()
  } catch (e) {
    setNotice(e?.response?.data?.detail || e.message, 'err')
  } finally {
    loading.value = false
  }
}

async function showDetail(d) {
  loading.value = true
  try {
    const { data } = await api.get(`/api/devices/${d.id}/detail`)
    deviceDetail.value = data
    showDetailModal.value = true
  } catch (e) {
    setNotice(e?.response?.data?.detail || e.message, 'err')
  } finally {
    loading.value = false
  }
}
function closeDetailModal() {
  showDetailModal.value = false
  deviceDetail.value = null
}
async function saveSimSingle() {
  const id = deviceDetail.value?.device?.id
  if (!id) return
  loading.value = true
  try {
    await api.post(`/api/devices/${id}/sim`, {
      sim1: deviceDetail.value.device.sim1number || '',
      sim2: deviceDetail.value.device.sim2number || '',
    })
    setNotice('已保存卡号', 'ok')
    await refresh()
  } catch (e) {
    setNotice(e?.response?.data?.detail || e.message, 'err')
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <div class="app">
    <!-- 登录界面 -->
    <div v-if="!authed" class="login-container">
      <div class="login-box">
        <h1 class="login-title">绿邮X系列内网群控 v3.2.2</h1>
        <p class="login-subtitle">完整修复版 + SIM卡增强 · 请使用管理员密码登录</p>
        
        <div class="login-form">
          <input 
            v-model="uiPass" 
            class="login-input" 
            type="password" 
            placeholder="请输入密码" 
            @keyup.enter="login"
          />
          <button 
            class="login-button" 
            :disabled="loading" 
            @click="login"
          >
            <span v-if="loading">登录中...</span>
            <span v-else>登录</span>
          </button>
        </div>

        <div v-if="notice.text" class="login-notice" :class="`notice-${notice.type}`">
          {{ notice.text }}
        </div>

        <div class="login-footer">
          <small>Board LAN Hub v3.2.2 · 完整修复版 + SIM卡增强</small>
        </div>
      </div>
    </div>

    <!-- 主界面 -->
    <div v-else class="main-container">
      <!-- 顶部导航栏 -->
      <header class="header">
        <div class="header-left">
          <div class="logo">📱</div>
          <div class="header-title">
            <h1>绿邮X系列内网群控</h1>
            <p class="header-subtitle">完整运营商显示 + 两行紧凑布局</p>
          </div>
        </div>
        
        <div class="header-right">
          <button class="header-btn" @click="startScanAdd" :disabled="loading">
            🔍 扫描添加
          </button>
          <button class="header-btn" @click="refresh" :disabled="loading">
            🔄 刷新
          </button>
          <button class="header-btn logout" @click="logout">
            🚪 退出
          </button>
        </div>
      </header>

      <!-- 通知栏 -->
      <div v-if="notice.text" class="notice-bar" :class="`notice-${notice.type}`">
        <span>{{ notice.text }}</span>
        <button class="notice-close" @click="clearNotice">×</button>
      </div>

      <!-- 统计卡片 -->
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-label">在线设备</div>
          <div class="stat-value" :class="{ 'stat-online': onlineCount > 0 }">{{ onlineCount }}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">离线设备</div>
          <div class="stat-value" :class="{ 'stat-offline': offlineCount > 0 }">{{ offlineCount }}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">总设备数</div>
          <div class="stat-value">{{ devices.length }}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">SIM卡数</div>
          <div class="stat-value">{{ numbers.length }}</div>
        </div>
      </div>

      <!-- 短信发送区域 -->
      <div class="card">
        <div class="card-header">
  <h2 class="card-title">📤 短信发送</h2>
  <div class="sms-tabs">
    <button type="button" class="sms-tab" :class="{active: commMode==='sms'}" @click="commMode='sms'">短信</button>
    <button type="button" class="sms-tab" :class="{active: commMode==='dial'}" @click="commMode='dial'">拨号</button>
  </div>
</div>
        <div class="sms-form">
          <div v-show="commMode==='sms'">
<div class="form-group">
            <label>发送卡号：</label>
            <select v-model="fromSelected" class="form-select">
              <option value="">请选择发送卡</option>
              <option v-for="n in numbers" :key="`${n.deviceId}-${n.slot}`" :value="`${n.deviceId}|${n.slot}`">
                {{ n.number }} ({{ n.operator || '未知运营商' }})
              </option>
            </select>
          </div>
          
          <div class="form-group">
            <label>收件号码：</label>
            <input v-model="toPhone" class="form-input" placeholder="输入手机号码" />
          </div>
          
          <div class="form-group full-width">
            <label>短信内容：</label>
            <textarea v-model="content" class="form-textarea" rows="3" placeholder="输入短信内容..."></textarea>
          </div>
          
          <div class="form-group full-width">
            <button class="btn-send" :disabled="loading || !fromSelected || !toPhone || !content" @click="send">
              📨 发送短信
            </button>
          </div>
        </div>
      
        </div> <!-- /sms -->
        <div v-show="commMode==='dial'">
          <div class="form-group">
            <label>发送卡号：</label>
            <select v-model="fromSelected" class="form-select">
              <option value="">请选择发送卡</option>
              <option v-for="n in numbers" :key="`${n.deviceId}-${n.slot}`" :value="`${n.deviceId}|${n.slot}`">
                {{ n.number }} ({{ n.operator || '未知运营商' }})
              </option>
            </select>
          </div>

          <div class="form-group">
            <label>号码：</label>
            <input v-model="dialPhone" class="form-input" placeholder="输入手机号码" />
          </div>

          <div class="form-group full-width">
            <label>TTS内容：</label>
            <textarea v-model="ttsText" class="form-textarea" rows="3" placeholder="TTS内容..."></textarea>
          </div>

          <div class="form-group full-width">
            <button class="btn-send" :disabled="loading || !fromSelected || !dialPhone" @click="dial">📞 拨打电话</button>
          </div>
        </div> <!-- /dial -->
</div>

      <!-- 设备/号码管理 -->
      <div class="card">
        <div class="card-header">
          <h2 class="card-title">📱 设备与号码管理</h2>
          
          <div class="card-tabs">
            <button class="tab-btn" :class="{ active: activeTab === 'devices' }" @click="activeTab = 'devices'">
              设备列表 ({{ devices.length }})
            </button>
            <button class="tab-btn" :class="{ active: activeTab === 'numbers' }" @click="activeTab = 'numbers'">
              号码列表 ({{ numbers.length }})
            </button>
          </div>
        </div>

        <!-- 工具栏 -->
        <div class="toolbar">
          <div class="search-box">
            <input 
              v-model="searchText" 
              class="search-input" 
              placeholder="搜索设备/号码/IP/MAC/运营商..." 
            />
            <span class="search-icon">🔍</span>
          </div>
          
          <select v-model="groupFilter" class="filter-select">
            <option value="all">全部分组</option>
            <option v-for="g in uniqueGroups.filter(x => x !== 'all')" :key="g" :value="g">{{ g }}</option>
          </select>
          
          <div class="toolbar-actions">
<button class="toolbar-btn" @click="openWifiModal" :disabled="selectedCount === 0">
              📶 配置WiFi
            </button>
          </div>
        </div>

        <!-- 批量操作栏 -->
        <div v-if="selectedCount > 0 && activeTab === 'devices'" class="batch-bar">
          <span class="batch-count">已选择 {{ selectedCount }} 台设备</span>
          <div class="batch-actions">
            <button class="batch-btn" @click="batchDeleteSelected">🗑 删除设备</button>
            <button class="batch-btn cancel" @click="selectedIds = []; selectAll = false">取消选择</button>
          </div>
        </div>

        <!-- 设备表格 -->
        <div v-if="activeTab === 'devices'" class="table-container">
          <table class="data-table">
            <thead>
              <tr>
                <th width="40">
                  <input type="checkbox" v-model="selectAll" @change="toggleSelectAll" class="checkbox">
                </th>
                <th>设备名称</th>
                <th>IP地址</th>
                <th>MAC地址</th>
                <th>状态</th>
                <th>最后在线</th>
                <th>操作</th>
              </tr>
            </thead>
            <tbody>
              <tr v-if="filteredDevices.length === 0">
                <td colspan="7" class="empty-state">
                  <div class="empty-content">
                    <div class="empty-icon">📡</div>
                    <p>暂无设备，点击"扫描添加"按钮发现设备</p>
                    <button class="empty-btn" @click="startScanAdd">开始扫描</button>
                  </div>
                </td>
              </tr>
              <tr v-for="d in filteredDevices" :key="d.id">
                <td>
                  <input type="checkbox" v-model="selectedIds" :value="d.id" class="checkbox">
                </td>
                <td>
                  <div class="device-name">
                    <strong>{{ displayName(d) }}</strong>
                    <small class="device-group">{{ d.grp || 'auto' }}</small>
                  </div>
                  <!-- 集成补丁：两行紧凑SIM卡显示 -->
                  <div v-if="d.sims?.sim1?.number || d.sims?.sim2?.number || d.sims?.sim1?.operator || d.sims?.sim2?.operator" class="device-sims">
                    <span v-if="d.sims?.sim1?.number || d.sims?.sim1?.operator" class="sim-badge bm-sim">
                      <span class="sim-title">SIM1: {{ d.sims?.sim1?.operator || '未知运营商' }}</span>
                      <span class="sim-number mono">{{ d.sims?.sim1?.number || '-' }}</span>
                    </span>
                    <span v-if="d.sims?.sim2?.number || d.sims?.sim2?.operator" class="sim-badge bm-sim">
                      <span class="sim-title">SIM2: {{ d.sims?.sim2?.operator || '未知运营商' }}</span>
                      <span class="sim-number mono">{{ d.sims?.sim2?.number || '-' }}</span>
                    </span>
                  </div>
                </td>
                <td class="mono">{{ d.ip }}</td>
                <td class="mono">{{ d.mac || '-' }}</td>
                <td>
                  <span class="status-badge" :class="d.status === 'online' ? 'online' : 'offline'">
                    {{ d.status === 'online' ? '在线' : '离线' }}
                  </span>
                </td>
                <td class="mono">{{ prettyTime(d.lastSeen) }}</td>
                <td>
                  <div class="action-buttons">
                    <button class="action-btn" @click="showDetail(d)" title="详情">👁️</button>
                    <button class="action-btn" @click="renameDevice(d)" title="改名">✏️</button>
                    <button class="action-btn" @click="setGroup(d)" title="分组">🏷️</button>
                    <button class="action-btn danger" @click="deleteDevice(d.id)" title="删除">🗑️</button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <!-- 号码表格 -->
        <div v-if="activeTab === 'numbers'" class="table-container">
          <table class="data-table">
            <thead>
              <tr>
                <th>手机号码</th>
                <th>卡槽</th>
                <th>运营商</th>
                <th>设备名称</th>
                <th>IP地址</th>
              </tr>
            </thead>
            <tbody>
              <tr v-if="filteredNumbers.length === 0">
                <td colspan="5" class="empty-state">
                  <div class="empty-content">
                    <div class="empty-icon">📞</div>
                    <p>暂无号码，扫描设备后会自动获取号码信息</p>
                  </div>
                </td>
              </tr>
              <tr v-for="n in filteredNumbers" :key="`${n.deviceId}-${n.slot}`">
                <td class="mono">{{ n.number }}</td>
                <td><span class="slot-badge">SIM{{ n.slot }}</span></td>
                <td>{{ n.operator || '-' }}</td>
                <td>{{ n.deviceName }}</td>
                <td class="mono">{{ n.ip }}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <!-- 模态框区域 -->
      <!-- 增强转发模态框 -->
      <div v-if="showEnhancedForwardModal" class="modal-overlay" @click.self="closeEnhancedForwardModal">
        <div class="modal">
          <div class="modal-header">
            <h3>⚙️ 批量配置转发方式</h3>
            <button class="modal-close" @click="closeEnhancedForwardModal">×</button>
          </div>
          
          <div class="modal-body">
            <div class="form-group">
              <label>转发方式：</label>
              <select v-model="forwardMethod" class="form-select">
                <option value="0">----- 不使用快捷配置 -----</option>
                <option value="1">转发至 Bark for iOS</option>
                <option value="8">转发至 邮箱(SMTP)</option>
                <option value="10">转发至 企业微信群Webhook</option>
                <option value="11">转发至 企业微信群Webhook （开启：来电接听＋录音上报）</option>
                <option value="13">转发至 钉钉群Webhook</option>
                <option value="16">转发至 飞书群Webhook</option>
                <option value="22">转发至 Server酱3</option>
                <option value="21">转发至 Server酱Turbo</option>
                <option value="30">转发至 PushPlus(推送加)</option>
                <option value="35">转发至 WxPusher</option>
                <option value="90">转发至 绿微平台普通WEB接口(v1)</option>
              </select>
            </div>
            
            <!-- 根据选择的转发方式显示对应配置 -->
            <div v-if="forwardMethod === '1'" class="config-section">
              <div class="form-group">
                <label>Bark Device Key：</label>
                <input v-model="enhancedForwardConfig.deviceKey0" class="form-input" placeholder="从Bark应用获取的device_key" />
              </div>
            </div>
            
            <div v-if="forwardMethod === '8'" class="config-section">
              <div class="form-group">
                <label>邮箱服务商：</label>
                <select v-model="enhancedForwardConfig.smtpProvider" class="form-select">
                  <option value="1">网易163邮箱</option>
                  <option value="10">腾讯QQ邮箱</option>
                  <option value="20">阿里云邮箱</option>
                  <option value="30">中国移动139邮箱</option>
                  <option value="53">Gmail</option>
                  <option value="999">其他SMTP服务</option>
                </select>
              </div>
              <div class="form-group">
                <label>SMTP服务器：</label>
                <input v-model="enhancedForwardConfig.smtpServer" class="form-input" placeholder="smtp服务器地址" />
              </div>
              <div class="form-group">
                <label>SMTP端口：</label>
                <input v-model="enhancedForwardConfig.smtpPort" class="form-input" placeholder="端口号" />
              </div>
              <div class="form-group">
                <label>邮箱账号：</label>
                <input v-model="enhancedForwardConfig.smtpAccount" class="form-input" placeholder="邮箱账号" />
              </div>
              <div class="form-group">
                <label>邮箱密码/授权码：</label>
                <input v-model="enhancedForwardConfig.smtpPassword" type="password" class="form-input" placeholder="密码或授权码" />
              </div>

            <div v-if="forwardMethod === '10' || forwardMethod === '11' || forwardMethod === '16'" class="config-section">
              <div class="form-group">
                <label>Webhook URL 1：</label>
                <input v-model="enhancedForwardConfig.webhookUrl1" class="form-input" placeholder="Webhook地址（必填）" />
              </div>
              <div class="form-group">
                <label>Webhook URL 2（可选）：</label>
                <input v-model="enhancedForwardConfig.webhookUrl2" class="form-input" placeholder="第二个Webhook地址" />
              </div>
              <div class="form-group">
                <label>Webhook URL 3（可选）：</label>
                <input v-model="enhancedForwardConfig.webhookUrl3" class="form-input" placeholder="第三个Webhook地址" />
              </div>
              <p class="tip">企业微信 / 飞书 的群机器人 Webhook，直接粘贴完整URL即可。</p>
            </div>

            <div v-if="forwardMethod === '13'" class="config-section">
              <div class="form-group">
                <label>钉钉 Webhook URL 1：</label>
                <input v-model="enhancedForwardConfig.webhookUrl1" class="form-input" placeholder="钉钉群机器人Webhook地址（必填）" />
              </div>
              <div class="form-group">
                <label>钉钉 SignKey 1（可选）：</label>
                <input v-model="enhancedForwardConfig.signKey1" class="form-input" placeholder="钉钉加签密钥（不开启加签可留空）" />
              </div>
              <div class="form-group">
                <label>Webhook URL 2（可选）：</label>
                <input v-model="enhancedForwardConfig.webhookUrl2" class="form-input" placeholder="第二个Webhook地址" />
              </div>
              <div class="form-group">
                <label>SignKey 2（可选）：</label>
                <input v-model="enhancedForwardConfig.signKey2" class="form-input" placeholder="第二个加签密钥" />
              </div>
              <div class="form-group">
                <label>Webhook URL 3（可选）：</label>
                <input v-model="enhancedForwardConfig.webhookUrl3" class="form-input" placeholder="第三个Webhook地址" />
              </div>
              <div class="form-group">
                <label>SignKey 3（可选）：</label>
                <input v-model="enhancedForwardConfig.signKey3" class="form-input" placeholder="第三个加签密钥" />
              </div>
              <p class="tip">如果钉钉机器人开启了"加签"，就把 SignKey 填上；否则留空即可。</p>
            </div>

            <div v-if="forwardMethod === '22'" class="config-section">
              <div class="form-group">
                <label>Server酱3 API URL：</label>
                <input v-model="enhancedForwardConfig.sc3ApiUrl" class="form-input" placeholder="例如：https://sctapi.ftqq.com/xxxx.send" />
              </div>
              <p class="tip">Server酱3 通常是一个可直接请求的URL，复制完整地址即可。</p>
            </div>

            <div v-if="forwardMethod === '21'" class="config-section">
              <div class="form-group">
                <label>Server酱Turbo SendKey：</label>
                <input v-model="enhancedForwardConfig.sctSendKey" class="form-input" placeholder="SCTxxxxxx（必填）" />
              </div>
            </div>

            <div v-if="forwardMethod === '30'" class="config-section">
              <div class="form-group">
                <label>PushPlus Token：</label>
                <input v-model="enhancedForwardConfig.PPToken" class="form-input" placeholder="PushPlus token（必填）" />
              </div>
              <div class="form-group">
                <label>Channel（可选）：</label>
                <input v-model="enhancedForwardConfig.PPChannel" class="form-input" placeholder="wechat / webhook / email 等" />
              </div>
              <div class="form-group">
                <label>Webhook（可选）：</label>
                <input v-model="enhancedForwardConfig.PPWebhook" class="form-input" placeholder="当 Channel=webhook 时填写" />
              </div>
              <div class="form-group">
                <label>Friends（可选）：</label>
                <input v-model="enhancedForwardConfig.PPFriends" class="form-input" placeholder="好友编号，多个逗号分隔" />
              </div>
              <div class="form-group">
                <label>GroupId（可选）：</label>
                <input v-model="enhancedForwardConfig.PPGroupId" class="form-input" placeholder="群组ID" />
              </div>
            </div>

            <div v-if="forwardMethod === '35'" class="config-section">
              <div class="form-group">
                <label>WxPusher AppToken：</label>
                <input v-model="enhancedForwardConfig.WPappToken" class="form-input" placeholder="AppToken（必填）" />
              </div>
              <div class="form-group">
                <label>UID（可选）：</label>
                <input v-model="enhancedForwardConfig.WPUID" class="form-input" placeholder="WxPusher UID，多个逗号分隔" />
              </div>
              <div class="form-group">
                <label>TopicId（可选）：</label>
                <input v-model="enhancedForwardConfig.WPTopicId" class="form-input" placeholder="主题ID" />
              </div>
            </div>

            <div v-if="forwardMethod === '90'" class="config-section">
              <div class="form-group">
                <label>绿微平台 API URL：</label>
                <input v-model="enhancedForwardConfig.lyApiUrl" class="form-input" placeholder="平台接口地址（必填）" />
              </div>
            </div>

            </div>
            
            <div class="modal-footer">
              <p class="modal-info">将应用到 {{ selectedCount }} 台设备</p>
              <div class="modal-actions">
                <button class="modal-btn" @click="closeEnhancedForwardModal">取消</button>
                <button class="modal-btn primary" @click="applyEnhancedForward" :disabled="loading">确认配置</button>
              </div>
            </div>
          </div>
        </div>
      </div>

      <!-- WiFi配置模态框 -->
      <div v-if="showWifiModal" class="modal-overlay" @click.self="closeWifiModal">
        <div class="modal">
          <div class="modal-header">
            <h3>📶 批量配置WiFi</h3>
            <button class="modal-close" @click="closeWifiModal">×</button>
          </div>
          
          <div class="modal-body">
            <div class="form-group">
              <label>WiFi名称 (SSID)：</label>
              <input v-model="wifiSsid" class="form-input" placeholder="输入WiFi名称" />
            </div>
            <div class="form-group">
              <label>WiFi密码：</label>
              <input v-model="wifiPwd" type="password" class="form-input" placeholder="输入WiFi密码" />
            </div>
            
            <div class="modal-footer">
              <p class="modal-info">将应用到 {{ selectedCount }} 台设备</p>
              <div class="modal-actions">
                <button class="modal-btn" @click="closeWifiModal">取消</button>
                <button class="modal-btn primary" @click="applyWifi" :disabled="loading">确认配置</button>
              </div>
            </div>
          </div>
        </div>
      </div>

      <!-- SIM卡配置模态框 -->
      <div v-if="showSimModal" class="modal-overlay" @click.self="closeSimModal">
        <div class="modal">
          <div class="modal-header">
            <h3>📞 批量配置SIM卡号</h3>
            <button class="modal-close" @click="closeSimModal">×</button>
          </div>
          
          <div class="modal-body">
            <div class="form-group">
              <label>SIM1 卡号：</label>
              <input v-model="sim1Number" class="form-input" placeholder="SIM1卡号（留空不修改）" />
            </div>
            <div class="form-group">
              <label>SIM2 卡号：</label>
              <input v-model="sim2Number" class="form-input" placeholder="SIM2卡号（留空不修改）" />
            </div>
            
            <div class="modal-footer">
              <p class="modal-info">将应用到 {{ selectedCount }} 台设备</p>
              <div class="modal-actions">
                <button class="modal-btn" @click="closeSimModal">取消</button>
                <button class="modal-btn primary" @click="applySim" :disabled="loading">确认配置</button>
              </div>
            </div>
          </div>
        </div>
      </div>

      <!-- 设备详情模态框 -->
      <div v-if="showDetailModal" class="modal-overlay" @click.self="closeDetailModal">
        <div class="modal">
          <div class="modal-header">
            <h3>📋 设备详情</h3>
            <button class="modal-close" @click="closeDetailModal">×</button>
          </div>
          
          <div class="modal-body" v-if="deviceDetail">
            <div class="detail-section">
              <h4>基本信息</h4>
              <div class="detail-grid">
                <div class="detail-item">
                  <label>设备ID：</label>
                  <span>{{ deviceDetail.device.devId || '-' }}</span>
                </div>
                <div class="detail-item">
                  <label>IP地址：</label>
                  <span class="mono">{{ deviceDetail.device.ip }}</span>
                </div>
                <div class="detail-item">
                  <label>MAC地址：</label>
                  <span class="mono">{{ deviceDetail.device.mac || '-' }}</span>
                </div>
                <div class="detail-item">
                  <label>状态：</label>
                  <span :class="deviceDetail.device.status === 'online' ? 'status-online' : 'status-offline'">
                    {{ deviceDetail.device.status === 'online' ? '在线' : '离线' }}
                  </span>
                </div>
              </div>
            </div>
            
            <div class="detail-section">
              <h4>SIM卡信息</h4>
              <div class="sim-grid">
                <div class="sim-card">
                  <h5>SIM1</h5>
                  <input v-model="deviceDetail.device.sim1number" class="form-input" placeholder="SIM1卡号" />
                  <div class="sim-info">{{ deviceDetail.device.sim1operator || '未知运营商' }}</div>
                </div>
                <div class="sim-card">
                  <h5>SIM2</h5>
                  <input v-model="deviceDetail.device.sim2number" class="form-input" placeholder="SIM2卡号" />
                  <div class="sim-info">{{ deviceDetail.device.sim2operator || '未知运营商' }}</div>
                </div>
              </div>
            </div>
            
            <div class="modal-footer">
              <div class="modal-actions">
                <button class="modal-btn" @click="closeDetailModal">关闭</button>
                <button class="modal-btn primary" @click="saveSimSingle" :disabled="loading">保存卡号</button>
              </div>
            </div>
          </div>
        </div>
      </div>

      <!-- 页脚 -->
      <footer class="footer">
        <p>绿邮X系列内网群控 v3.2.2 + SIM卡增强版</p>
        <p class="footer-note">支持完整运营商显示（移动(46001)）+ 两行紧凑布局</p>
      </footer>
    </div>
  </div>
</template>

<style scoped>
/* 完整的CSS样式，包含SIM卡增强样式 */
* { box-sizing: border-box; margin: 0; padding: 0; }

.app {
  min-height: 100vh;
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
}

/* 登录界面 */
.login-container {
  min-height: 100vh;
  display: flex;
  align-items: center;
  justify-content: center;
  background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
  padding: 20px;
}

.login-box {
  background: white;
  border-radius: 16px;
  padding: 40px;
  width: 100%;
  max-width: 420px;
  box-shadow: 0 20px 60px rgba(0,0,0,0.3);
}

.login-title {
  font-size: 24px;
  font-weight: 700;
  color: #1a202c;
  margin-bottom: 8px;
  text-align: center;
}

.login-subtitle {
  color: #718096;
  text-align: center;
  margin-bottom: 30px;
  font-size: 14px;
}

.login-form {
  margin-bottom: 20px;
}

.login-input {
  width: 100%;
  padding: 14px 16px;
  border: 2px solid #e2e8f0;
  border-radius: 12px;
  font-size: 16px;
  margin-bottom: 16px;
  transition: border-color 0.2s;
}

.login-input:focus {
  outline: none;
  border-color: #667eea;
}

.login-button {
  width: 100%;
  padding: 14px;
  background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
  color: white;
  border: none;
  border-radius: 12px;
  font-size: 16px;
  font-weight: 600;
  cursor: pointer;
  transition: opacity 0.2s;
}

.login-button:disabled {
  opacity: 0.6;
  cursor: not-allowed;
}

.login-button:hover:not(:disabled) {
  opacity: 0.9;
}

.login-notice {
  padding: 12px;
  border-radius: 8px;
  margin-bottom: 20px;
  text-align: center;
  font-size: 14px;
}

.notice-ok {
  background: #c6f6d5;
  color: #22543d;
  border: 1px solid #9ae6b4;
}

.notice-err {
  background: #fed7d7;
  color: #742a2a;
  border: 1px solid #fc8181;
}

.notice-info {
  background: #bee3f8;
  color: #234e52;
  border: 1px solid #90cdf4;
}

.login-footer {
  text-align: center;
  color: #a0aec0;
  font-size: 12px;
  margin-top: 20px;
  padding-top: 20px;
  border-top: 1px solid #e2e8f0;
}

/* 主界面 */
.main-container {
  background: #f7fafc;
  min-height: 100vh;
}

/* 头部 */
.header {
  background: white;
  border-bottom: 1px solid #e2e8f0;
  padding: 16px 24px;
  display: flex;
  justify-content: space-between;
  align-items: center;
}

.header-left {
  display: flex;
  align-items: center;
  gap: 16px;
}

.sms-form > div { display: contents; }

.logo {
  font-size: 32px;
}

.header-title h1 {
  font-size: 20px;
  font-weight: 700;
  color: #1a202c;
  margin-bottom: 4px;
}

.header-subtitle {
  font-size: 12px;
  color: #718096;
}

.header-right {
  display: flex;
  gap: 12px;
}

.header-btn {
  padding: 10px 16px;
  background: #edf2f7;
  border: 1px solid #e2e8f0;
  border-radius: 8px;
  font-size: 14px;
  font-weight: 600;
  color: #4a5568;
  cursor: pointer;
  transition: all 0.2s;
  display: flex;
  align-items: center;
  gap: 6px;
}

.header-btn:hover:not(:disabled) {
  background: #e2e8f0;
}

.header-btn:disabled {
  opacity: 0.6;
  cursor: not-allowed;
}

.header-btn.logout {
  background: #fed7d7;
  color: #c53030;
  border-color: #fc8181;
}

.header-btn.logout:hover {
  background: #feb2b2;
}

/* 通知栏 */
.notice-bar {
  padding: 12px 24px;
  display: flex;
  justify-content: space-between;
  align-items: center;
}

.notice-close {
  background: none;
  border: none;
  font-size: 20px;
  color: inherit;
  cursor: pointer;
  opacity: 0.7;
}

.notice-close:hover {
  opacity: 1;
}

/* 统计卡片 */
.stats-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
  gap: 16px;
  padding: 24px;
}

.stat-card {
  background: white;
  border-radius: 12px;
  padding: 20px;
  border: 1px solid #e2e8f0;
  text-align: center;
}

.stat-label {
  font-size: 14px;
  color: #718096;
  margin-bottom: 8px;
}

.stat-value {
  font-size: 32px;
  font-weight: 700;
  color: #1a202c;
}

.stat-online {
  color: #38a169;
}

.stat-offline {
  color: #e53e3e;
}

/* 卡片通用样式 */
.card {
  background: white;
  border-radius: 12px;
  border: 1px solid #e2e8f0;
  margin: 0 24px 24px;
  overflow: hidden;
}

.card-header {
  padding: 20px 24px;
  border-bottom: 1px solid #e2e8f0;
  display: flex;
  justify-content: space-between;
  align-items: center;
}

.card-title {
  font-size: 18px;
  font-weight: 700;
  color: #1a202c;
}

.card-tabs {
  display: flex;
  gap: 8px;
}

.tab-btn {
  padding: 8px 16px;
  background: #edf2f7;
  border: none;
  border-radius: 6px;
  color: #4a5568;
  font-size: 14px;
  cursor: pointer;
  transition: all 0.2s;
}

.tab-btn.active {
  background: #667eea;
  color: white;
}

/* 工具栏 */
.toolbar {
  padding: 16px 24px;
  border-bottom: 1px solid #e2e8f0;
  display: flex;
  gap: 12px;
  align-items: center;
}

.search-box {
  flex: 1;
  position: relative;
}

.search-input {
  width: 100%;
  padding: 10px 16px 10px 40px;
  border: 1px solid #e2e8f0;
  border-radius: 8px;
  font-size: 14px;
}

.search-icon {
  position: absolute;
  left: 12px;
  top: 50%;
  transform: translateY(-50%);
  color: #a0aec0;
}

.filter-select {
  padding: 10px 16px;
  border: 1px solid #e2e8f0;
  border-radius: 8px;
  font-size: 14px;
  min-width: 140px;
}

.toolbar-actions {
  display: flex;
  gap: 8px;
}

.toolbar-btn {
  padding: 10px 16px;
  background: #edf2f7;
  border: 1px solid #e2e8f0;
  border-radius: 8px;
  color: #4a5568;
  font-size: 14px;
  cursor: pointer;
  transition: all 0.2s;
  display: flex;
  align-items: center;
  gap: 6px;
}

.toolbar-btn:hover:not(:disabled) {
  background: #e2e8f0;
}

.toolbar-btn:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}

/* 批量操作栏 */
.batch-bar {
  padding: 16px 24px;
  background: #ebf8ff;
  border-bottom: 1px solid #bee3f8;
  display: flex;
  justify-content: space-between;
  align-items: center;
}

.batch-count {
  font-weight: 600;
  color: #2c5282;
}

.batch-actions {
  display: flex;
  gap: 8px;
}

.batch-btn {
  padding: 8px 16px;
  background: white;
  border: 1px solid #bee3f8;
  border-radius: 6px;
  color: #2c5282;
  font-size: 13px;
  cursor: pointer;
  transition: all 0.2s;
}

.batch-btn:hover {
  background: #bee3f8;
}

.batch-btn.cancel {
  background: #fed7d7;
  border-color: #fc8181;
  color: #c53030;
}

.batch-btn.cancel:hover {
  background: #feb2b2;
}

/* 表格 */
.table-container {
  overflow-x: auto;
}

.data-table {
  width: 100%;
  border-collapse: collapse;
}

.data-table th {
  background: #f7fafc;
  padding: 12px 24px;
  text-align: left;
  font-size: 12px;
  font-weight: 600;
  color: #718096;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  border-bottom: 1px solid #e2e8f0;
}

.data-table td {
  padding: 16px 24px;
  border-bottom: 1px solid #edf2f7;
  font-size: 14px;
}

.empty-state {
  text-align: center;
  padding: 60px 20px !important;
}

.empty-content {
  max-width: 300px;
  margin: 0 auto;
}

.empty-icon {
  font-size: 48px;
  margin-bottom: 16px;
  opacity: 0.5;
}

.empty-state p {
  color: #a0aec0;
  font-size: 14px;
  margin-bottom: 16px;
}

.empty-btn {
  padding: 10px 20px;
  background: #667eea;
  color: white;
  border: none;
  border-radius: 8px;
  cursor: pointer;
  font-weight: 600;
}

.empty-btn:hover {
  background: #5a67d8;
}

/* 表单组件 */
.form-group {
  margin-bottom: 16px;
}

.tip {
  margin-top: 6px;
  font-size: 12px;
  opacity: 0.75;
}

.form-group label {
  display: block;
  margin-bottom: 6px;
  font-size: 14px;
  font-weight: 600;
  color: #4a5568;
}

.form-input,
.form-select,
.form-textarea {
  width: 100%;
  padding: 10px 12px;
  border: 1px solid #e2e8f0;
  border-radius: 8px;
  font-size: 14px;
  transition: border-color 0.2s;
}

.form-input:focus,
.form-select:focus,
.form-textarea:focus {
  outline: none;
  border-color: #667eea;
}

.form-textarea {
  resize: vertical;
  min-height: 80px;
}

.full-width {
  grid-column: 1 / -1;
}

/* 短信表单 */
.sms-form {
  padding: 24px;
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 16px;
}

.btn-send {
  padding: 12px 24px;
  background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
  color: white;
  border: none;
  border-radius: 8px;
  font-size: 16px;
  font-weight: 600;
  cursor: pointer;
  transition: opacity 0.2s;
}

.btn-send:disabled {
  opacity: 0.6;
  cursor: not-allowed;
}

.btn-send:hover:not(:disabled) {
  opacity: 0.9;
}

/* 设备样式 */
.device-name {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-bottom: 4px;
}

.device-group {
  background: #edf2f7;
  color: #4a5568;
  padding: 2px 8px;
  border-radius: 4px;
  font-size: 11px;
}

/* 集成补丁：两行紧凑SIM卡显示 */
.device-sims{ 
  display:flex; 
  gap:6px; 
  flex-wrap:wrap; 
  align-items:flex-start; 
  margin-top: 4px;
}
.sim-badge.bm-sim{
  display:inline-flex;
  flex-direction:column;
  align-items:flex-start;
  gap:2px;
  padding:4px 8px;
  border:1px solid rgba(255,255,255,.12);
  border-radius:8px;
  background:rgba(255,255,255,.04);
}
.sim-badge.bm-sim .sim-title{
  font-size:10px;
  font-weight:600;
  opacity:.75;
  white-space:nowrap;   /* 移动(46001) 不拆行 */
}
.sim-badge.bm-sim .sim-number{
  font-size:13px;
  font-weight:800;
  opacity:.95;
}

/* 状态标记 */
.status-badge {
  padding: 4px 8px;
  border-radius: 4px;
  font-size: 12px;
  font-weight: 600;
}

.status-badge.online {
  background: #c6f6d5;
  color: #22543d;
}

.status-badge.offline {
  background: #fed7d7;
  color: #742a2a;
}

.status-online {
  color: #38a169;
  font-weight: 600;
}

.status-offline {
  color: #e53e3e;
  font-weight: 600;
}

.slot-badge {
  background: #bee3f8;
  color: #2c5282;
  padding: 2px 8px;
  border-radius: 4px;
  font-size: 11px;
  font-weight: 600;
}

/* 操作按钮 */
.action-buttons {
  display: flex;
  gap: 4px;
}

.action-btn {
  width: 32px;
  height: 32px;
  border: 1px solid #e2e8f0;
  background: white;
  border-radius: 6px;
  cursor: pointer;
  transition: all 0.2s;
  display: flex;
  align-items: center;
  justify-content: center;
}

.action-btn:hover {
  background: #f7fafc;
  border-color: #cbd5e0;
}

.action-btn.danger {
  color: #e53e3e;
  border-color: #fc8181;
}

.action-btn.danger:hover {
  background: #fed7d7;
}

/* 复选框 */
.checkbox {
  width: 18px;
  height: 18px;
  cursor: pointer;
}

.mono {
  font-family: 'SFMono-Regular', Consolas, 'Liberation Mono', Menlo, monospace;
  font-size: 13px;
}

/* 模态框 */
.modal-overlay {
  position: fixed;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  background: rgba(0, 0, 0, 0.5);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 1000;
  padding: 20px;
}

.modal {
  background: white;
  border-radius: 12px;
  width: 100%;
  max-width: 600px;
  max-height: 80vh;
  overflow-y: auto;
  box-shadow: 0 20px 60px rgba(0, 0, 0, 0.3);
}

.modal-header {
  padding: 20px 24px;
  border-bottom: 1px solid #e2e8f0;
  display: flex;
  justify-content: space-between;
  align-items: center;
}

.modal-header h3 {
  font-size: 18px;
  font-weight: 600;
  color: #1a202c;
}

.modal-close {
  background: none;
  border: none;
  font-size: 24px;
  color: #a0aec0;
  cursor: pointer;
  line-height: 1;
}

.modal-close:hover {
  color: #718096;
}

.modal-body {
  padding: 24px;
}

.config-section {
  margin-top: 20px;
  padding-top: 20px;
  border-top: 1px solid #e2e8f0;
}

.modal-footer {
  margin-top: 24px;
  padding-top: 20px;
  border-top: 1px solid #e2e8f0;
}

.modal-info {
  color: #718096;
  font-size: 14px;
  margin-bottom: 16px;
}

.modal-actions {
  display: flex;
  justify-content: flex-end;
  gap: 12px;
}

.modal-btn {
  padding: 10px 20px;
  background: #edf2f7;
  border: 1px solid #e2e8f0;
  border-radius: 8px;
  color: #4a5568;
  font-size: 14px;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.2s;
}

.modal-btn:hover {
  background: #e2e8f0;
}

.modal-btn.primary {
  background: #667eea;
  color: white;
  border-color: #5a67d8;
}

.modal-btn.primary:hover {
  background: #5a67d8;
}

/* 详情页面样式 */
.detail-section {
  margin-bottom: 24px;
}

.detail-section h4 {
  font-size: 16px;
  font-weight: 600;
  color: #2d3748;
  margin-bottom: 12px;
  padding-bottom: 8px;
  border-bottom: 1px solid #e2e8f0;
}

.detail-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
  gap: 16px;
}

.detail-item {
  display: flex;
  flex-direction: column;
}

.detail-item label {
  font-size: 12px;
  color: #718096;
  margin-bottom: 4px;
}

.detail-item span {
  font-size: 14px;
  color: #2d3748;
}

.sim-grid {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 16px;
}

.sim-card {
  background: #f7fafc;
  border-radius: 8px;
  padding: 16px;
  border: 1px solid #e2e8f0;
}

.sim-card h5 {
  font-size: 14px;
  font-weight: 600;
  color: #4a5568;
  margin-bottom: 8px;
}

.sim-info {
  font-size: 12px;
  color: #718096;
  margin-top: 8px;
}

/* 页脚 */
.footer {
  padding: 24px;
  text-align: center;
  color: #a0aec0;
  font-size: 13px;
  border-top: 1px solid #e2e8f0;
  margin-top: 24px;
}

.footer-note {
  font-size: 12px;
  margin-top: 4px;
  opacity: 0.7;
}

/* 响应式设计 */
@media (max-width: 768px) {
  .header {
    flex-direction: column;
    gap: 16px;
    padding: 16px;
  }
  
  .header-right {
    width: 100%;
    justify-content: center;
  }
  
  .stats-grid {
    grid-template-columns: 1fr 1fr;
    padding: 16px;
  }
  
  .card {
    margin: 0 16px 16px;
  }
  
  .sms-form {
    grid-template-columns: 1fr;
  }
  
  .toolbar {
    flex-direction: column;
    align-items: stretch;
  }
  
  .batch-bar {
    flex-direction: column;
    gap: 12px;
    align-items: stretch;
  }
  
  .batch-actions {
    flex-wrap: wrap;
  }
  
  .sim-grid {
    grid-template-columns: 1fr;
  }
  
  .modal {
    max-width: 95%;
  }
}

.sms-tabs{ display:flex; gap:8px; }
.sms-tab{ padding:6px 12px; border-radius:10px; border:1px solid rgba(255,255,255,.25); background:rgba(255,255,255,.06); color:inherit; cursor:pointer; }
.sms-tab.active{ background:rgba(255,255,255,.18); font-weight:600; }
</style>
VUE_COMPLETE

  run_task "npm install" bash -lc "cd '$FE' && npm install --silent" || {
    log_warn "npm install 失败，尝试使用淘宝源"
    bash -lc "cd '$FE' && npm config set registry https://registry.npmmirror.com && npm install --silent"
  }
  run_task "构建静态UI" bash -lc "cd '$FE' && npm run build --silent" || return 1
    # 将构建产物 dist 发布到 static，并校验 index.html
  if [[ ! -f "${FE}/dist/index.html" ]]; then
    log_err "前端构建失败：未生成 ${FE}/dist/index.html"
    log_err "请运行：cd ${FE} && npm run build  查看报错"
    return 1
  fi

  rm -rf "${APPDIR}/static" 2>/dev/null || true
  mkdir -p "${APPDIR}/static"
  cp -a "${FE}/dist/." "${APPDIR}/static/" 2>/dev/null || true

  if [[ ! -f "${APPDIR}/static/index.html" ]]; then
    log_err "前端发布失败：未生成 ${APPDIR}/static/index.html"
    return 1
  fi

  log_info "前端静态文件已输出到：${APPDIR}/static"

}

setupservice(){
  title "配置 systemd 服务（双栈 v4+v6）"

  cat > "${SERVICEAPI4}" <<EOF
[Unit]
Description=Board LAN Hub (IPv4)
After=network.target

[Service]
Type=simple
WorkingDirectory=${APPDIR}
Environment=BMDB=${APPDIR}/data/data.db
Environment=BMSTATIC=${APPDIR}/static
Environment=BMDEVUSER=${SCANUSER}
Environment=BMDEVPASS=${SCANPASS}
Environment=BMUIUSER=admin
Environment=BMUIPASS=${UIPASS}
ExecStart=${APPDIR}/venv/bin/python -m uvicorn app.main:app --host 0.0.0.0 --port ${APIPORT}
Restart=always
RestartSec=2
StandardOutput=journal
StandardError=journal
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

  cat > "${SERVICEAPI6}" <<EOF
[Unit]
Description=Board LAN Hub (IPv6)
After=network.target

[Service]
Type=simple
WorkingDirectory=${APPDIR}
Environment=BMDB=${APPDIR}/data/data.db
Environment=BMSTATIC=${APPDIR}/static
Environment=BMDEVUSER=${SCANUSER}
Environment=BMDEVPASS=${SCANPASS}
Environment=BMUIUSER=admin
Environment=BMUIPASS=${UIPASS}
ExecStart=${APPDIR}/venv/bin/python -m uvicorn app.main:app --host :: --port ${APIPORT}
Restart=always
RestartSec=2
StandardOutput=journal
StandardError=journal
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

  chmod 644 "${SERVICEAPI4}" "${SERVICEAPI6}"
  systemctl daemon-reload
  systemctl enable board-manager-v4.service >/dev/null 2>&1 || true
  systemctl enable board-manager-v6.service >/dev/null 2>&1 || true
  systemctl restart board-manager-v4.service
  systemctl restart board-manager-v6.service
  
  sleep 2
  if systemctl is-active --quiet board-manager-v4.service && \
     systemctl is-active --quiet board-manager-v6.service; then
    log_info "服务启动成功：board-manager-v4 / board-manager-v6"
  else
    log_warn "服务可能未完全启动，请检查日志"
  fi
}

check_service_health(){
  local max_attempts=10
  local attempt=1
  
  while [[ $attempt -le $max_attempts ]]; do
    if curl -s "http://127.0.0.1:${APIPORT}/api/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    attempt=$((attempt + 1))
  done
  return 1
}

status(){
  log_step "服务状态检查："
  systemctl status board-manager-v4.service board-manager-v6.service --no-pager -l
  
  log_step "端口监听状态："
  ss -ltnp | grep -E ":${APIPORT}|\\[::\\]:${APIPORT}" || log_info "端口 ${APIPORT} 未监听"
  
  log_step "服务健康检查："
  if check_service_health; then
    log_info "API 健康检查: ${GREEN}通过${NC}"
  else
    log_warn "API 健康检查: ${YELLOW}失败${NC}"
  fi
}

logs(){
  local lines="${1:-50}"
  log_step "IPv4 服务日志（最近 ${lines} 行）："
  journalctl -u board-manager-v4.service -n "$lines" --no-pager
  echo ""
  log_step "IPv6 服务日志（最近 ${lines} 行）："
  journalctl -u board-manager-v6.service -n "$lines" --no-pager
}

restart(){
  systemctl restart board-manager-v4.service
  systemctl restart board-manager-v6.service
  sleep 1
  status
}

backup_data(){
  need_root
  title "备份数据"
  
  local timestamp=$(date +%Y%m%d_%H%M%S)
  local backup_file="${BACKUP_DIR}/board-manager_backup_${timestamp}.tar.gz"
  
  mkdir -p "$BACKUP_DIR"
  
  log_step "备份数据库和配置..."
  tar -czf "$backup_file" \
    -C "${APPDIR}" data \
    "$CONFIG_FILE" \
    "${SERVICEAPI4}" \
    "${SERVICEAPI6}" 2>/dev/null
  
  if [[ $? -eq 0 ]]; then
    log_info "备份成功: $backup_file"
    log_info "大小: $(du -h "$backup_file" | cut -f1)"
  else
    log_err "备份失败"
    return 1
  fi
}

restore_data(){
  need_root
  title "恢复数据"
  
  if [[ -z "${1:-}" ]]; then
    log_step "可用的备份文件："
    ls -lt "${BACKUP_DIR}/"*.tar.gz 2>/dev/null | head -10
    read -p "请输入备份文件路径: " backup_file
  else
    backup_file="$1"
  fi
  
  if [[ ! -f "$backup_file" ]]; then
    log_err "备份文件不存在: $backup_file"
    return 1
  fi
  
  log_step "停止服务..."
  systemctl stop board-manager-v4.service >/dev/null 2>&1 || true
  systemctl stop board-manager-v6.service >/dev/null 2>&1 || true
  
  log_step "解压备份..."
  tar -xzf "$backup_file" -C / 2>/dev/null || {
    log_err "解压失败"
    return 1
  }
  
  log_step "重启服务..."
  systemctl restart board-manager-v4.service
  systemctl restart board-manager-v6.service
  
  log_info "数据恢复完成"
}

uninstall(){
  need_root
  local force=0
  if [[ "${1:-}" == "--force" ]]; then force=1; shift; fi
  local force_mode=false
  
  if [[ "${1:-}" == "--force" ]]; then
    force_mode=true
  fi
  
  title "安全卸载 Board LAN Hub"
  
  if [[ "$force_mode" != "true" ]]; then
    echo ""
    log_warn "⚠️  即将卸载以下内容："
    log_warn "  - 服务文件: board-manager-v4 / board-manager-v6"
    log_warn "  - 安装目录: ${APPDIR}"
    log_warn "  - 配置文件: ${CONFIG_FILE}"
    log_warn "  - 数据库: ${APPDIR}/data/data.db"
    echo ""
    if [[ $force -eq 0 ]]; then
    read -p "是否确认卸载？(y/N): " confirm
  else
    confirm="y"
  fi
    if [[ ! "${confirm:-}" =~ ^[Yy]$ ]]; then
      log_info "取消卸载"
      exit 0
    fi
    
    if [[ $force -eq 0 ]]; then
    read -p "是否备份数据？(y/N): " backup_confirm
  else
    backup_confirm="n"
  fi
    if [[ "$backup_confirm" =~ ^[Yy]$ ]]; then
      backup_data || log_warn "备份失败，继续卸载"
    fi
  fi
  
  log_step "停止服务..."
  for svc in board-manager-v4 board-manager-v6; do
    if systemctl is-active --quiet "$svc.service" 2>/dev/null; then
      log_info "停止 $svc.service"
      systemctl stop "$svc.service"
      for i in {1..5}; do
        if ! systemctl is-active --quiet "$svc.service" 2>/dev/null; then
          break
        fi
        sleep 1
      done
    fi
  done
  
  log_step "禁用服务..."
  for svc in board-manager-v4 board-manager-v6; do
    systemctl disable "$svc.service" 2>/dev/null || true
  done
  
  log_step "移除服务文件..."
  rm -f "${SERVICEAPI4}" "${SERVICEAPI6}" 2>/dev/null || true
  
  systemctl daemon-reload
  systemctl reset-failed 2>/dev/null || true
  
  log_step "清理安装目录..."
  if [[ -d "${APPDIR}" ]]; then
    if [[ "$force_mode" == "true" ]] || safe_delete "${APPDIR}"; then
      log_info "已删除: ${APPDIR}"
    fi
  fi
  
  log_step "清理配置文件..."
  rm -f "$CONFIG_FILE" 2>/dev/null || true
  
  log_step "清理临时文件..."
  cleanup_temp
  
  log_step "清理NPM缓存..."
  if command -v npm >/dev/null 2>&1; then
    npm cache clean --force 2>/dev/null || true
  fi
  
  # 清理命令入口（卸载后不应还能直接运行 lvyou）
  rm -f /usr/local/bin/lvyou 2>/dev/null || true
  rm -f /usr/local/bin/lvyou.sh 2>/dev/null || true
  rm -f /usr/bin/lvyou 2>/dev/null || true
  rm -f /usr/bin/lvyou.sh 2>/dev/null || true 2>/dev/null || true

  log_info "✅ 卸载完成！"
  echo ""
  log_warn "注意：日志文件仍存在于 journal 中，可通过以下命令查看："
  log_warn "  journalctl -u board-manager-v4.service"
  log_warn "  journalctl -u board-manager-v6.service"
}

doscan(){
  local cidr="$1"; local user="$2"; local pass="$3"
  
  # 从配置文件读取UI密码
  if [[ ! -f "$CONFIG_FILE" ]]; then
    log_err "配置文件不存在: $CONFIG_FILE"
    return 1
  fi
  
  # 直接读取UIPASS
  local ui_pass
  ui_pass=$(grep '^UIPASS=' "$CONFIG_FILE" | cut -d= -f2- | tr -d '"' | tr -d "'")
  
  if [[ -z "$ui_pass" ]]; then
    log_err "无法从配置文件中获取UI密码"
    return 1
  fi
  
  local url="http://127.0.0.1:${APIPORT}/api/scan/start"
  local params=""
  
  if [[ -n "$cidr" ]]; then
    params="cidr=${cidr}"
  fi
  
  if [[ -n "$user" ]]; then
    [[ -n "$params" ]] && params="${params}&"
    params="${params}user=${user}"
  fi
  
  if [[ -n "$pass" ]]; then
    [[ -n "$params" ]] && params="${params}&"
    params="${params}password=${pass}"
  fi
  
  if [[ -n "$params" ]]; then
    url="${url}?${params}"
  fi
  
  log_step "触发扫描请求: ${url}"
  
  # 使用 Basic 认证
  local auth_header="Authorization: Basic $(echo -n "admin:${ui_pass}" | base64)"
  
  run_task "扫描中..." bash -lc "curl -sS -H '$auth_header' -X POST '$url'"
  
  echo ""
  log_info "扫描完成，请在UI中查看结果"
}

installall(){
  need_root
  title "安装 绿邮内网群控 v3.2.2 (完整修复版 + SIM卡增强)"

  if [[ -z "${APIPORT:-}" ]]; then APIPORT=8000; fi
  echo ""
  read -p "请输入服务端口(默认 8000): " _p || true
  if [[ -n "${_p:-}" ]]; then APIPORT="${_p}"; fi
  # 强制要求修改默认密码（首次安装必填；已设置则可跳过）
  echo ""
  log_warn "⚠️ 安全警告：必须修改默认密码！"
  local _need_set=1
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE" 2>/dev/null || true
    if [[ -n "${UIPASS:-}" && "${UIPASS}" != "admin" ]]; then
      _need_set=0
      read -p "检测到已设置UI密码，是否修改？(y/N): " _chg || true
      if [[ "${_chg:-}" =~ ^[Yy]$ ]]; then _need_set=1; fi
    fi
  fi

  if [[ $_need_set -eq 1 ]]; then
    while true; do
      read -p "请设置UI登录密码(可见输入，至少6位): " _up || true
      if [[ ${#_up} -lt 6 ]]; then
        log_err "密码必须至少6位！请重新输入。"
        continue
      fi
      read -p "请确认UI登录密码: " _up2 || true
      if [[ "$_up" != "$_up2" ]]; then
        log_err "两次输入的密码不一致！请重试。"
        continue
      fi
      UIPASS="$_up"
      break
    done
  fi

  log_info "将使用端口：${APIPORT}"
  log_info "UI密码已设置（长度：${#UIPASS}）"

  check_port "${APIPORT}" || exit 1
  install_deps || { log_err "依赖安装失败"; exit 1; }
  install_node || { log_err "Node.js安装失败"; exit 1; }
  ensure_dirs
  write_backend || { log_err "后端部署失败"; exit 1; }
  writefrontendstatic || { log_err "前端部署失败"; exit 1; }
  setupservice
  
  log_step "等待服务启动..."
  if check_service_health; then
    log_info "服务启动成功！"
  else
    log_warn "服务可能启动较慢，请稍后访问"
  fi

  local ip ipv6
  ip=$(get_local_ip)
  ipv6=$(get_ipv6_address)
  
  log_info "================================"
  log_info "安装完成！"
  log_info "版本：v3.2.2 (完整修复版 + SIM卡增强)"
  log_info "特性：完整的运营商显示（移动(46001)）"
  log_info "特性：两行紧凑SIM卡显示布局"
  if [[ -n "$ip" ]]; then
    log_info "IPv4访问： http://${ip}:${APIPORT}/"
  fi
  if [[ -n "$ipv6" ]]; then
    log_info "IPv6访问： http://[${ipv6}]:${APIPORT}/"
  fi
  log_info "本地访问： http://127.0.0.1:${APIPORT}/"
  log_info "访问端口：${APIPORT}"
  log_info "登录方式：网页密码框"
  log_info "登录密码：您设置的密码"
  log_info "SIM卡增强：已启用"
  log_info "运营商显示：完整格式（移动(46001)）"
  log_info "================================"
  log_info "管理命令："
  log_info "  $0 status      # 查看状态"
  log_info "  $0 logs        # 查看日志"
  log_info "  $0 restart     # 重启服务"
  log_info "  $0 backup      # 备份数据"
  log_info "  $0 uninstall   # 安全卸载"
  log_info "  $0 scan        # 触发扫描"
  log_info "================================"

  install_cli_link
}


# SIM卡显示增强补丁
patch_sim_display(){
  need_root
  title "应用SIM卡显示增强补丁"
  
  local ROOT="/opt/board-manager"
  local MAIN="$ROOT/app/main.py"
  local APPVUE="$ROOT/frontend/src/App.vue"
  local FRONT="$ROOT/frontend"
  
  if [[ ! -f "$MAIN" ]]; then
    log_err "找不到 $MAIN，请先安装系统"
    exit 1
  fi
  
  # 备份原始文件
  local timestamp=$(date +%Y%m%d_%H%M%S)
  cp -a "$MAIN" "$MAIN.bak.$timestamp"
  if [[ -f "$APPVUE" ]]; then
    cp -a "$APPVUE" "$APPVUE.bak.$timestamp"
  fi
  
  log_step "更新后端代码..."
  # 这里直接调用已集成的功能，不需要额外补丁
  log_info "后端已集成SIM卡增强功能"
  
  log_step "更新前端代码..."
  if [[ -f "$APPVUE" ]]; then
    # 重新写入前端文件
    writefrontendstatic
  else
    log_warn "找不到前端源码，跳过前端更新"
  fi
  
  log_step "重启服务..."
  systemctl daemon-reload
  systemctl restart board-manager-v4.service
  systemctl restart board-manager-v6.service
  
  log_info "✅ SIM卡显示增强补丁已应用"
  echo ""
  log_info "请执行以下操作："
  log_info "1. 在网页点击「重新扫描/刷新状态」"
  log_info "2. 浏览器强制刷新（Ctrl+F5）"
  log_info "3. SIM卡将显示为两行：运营商在上，号码在下"
}


install_cli_link(){
  need_root
  local target="/usr/local/bin/lvyou.sh"
  if [[ -f "$0" ]]; then
    cp -f "$0" "$target" 2>/dev/null || true
    chmod +x "$target" 2>/dev/null || true
    ln -sf "$target" /usr/local/bin/lvyou 2>/dev/null || true
  fi
}

CMD="${1:-menu}"
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) APPDIR="$2"; shift 2 ;;
    --api-port) APIPORT="$2"; shift 2 ;;
    --user) SCANUSER="$2"; shift 2 ;;
    --pass) SCANPASS="$2"; shift 2 ;;
    --cidr) CIDR="$2"; shift 2 ;;
    *) shift ;;
  esac
done

set_ui_pass(){
  need_root
  local newpass="${1:-}"
  local confirm=""
  title "设置UI密码"

  if [[ -z "$newpass" ]]; then
    while true; do
      read -p "请输入新的 UI 密码(可见输入，至少6位): " newpass || true
      if [[ ${#newpass} -lt 6 ]]; then
        log_err "密码必须至少6位，请重试"
        continue
      fi
      read -p "请确认新的 UI 密码: " confirm || true
      if [[ "$newpass" != "$confirm" ]]; then
        log_err "两次输入不一致，请重试"
        continue
      fi
      break
    done
  else
    if [[ ${#newpass} -lt 6 ]]; then
      log_err "密码必须至少6位"; return 1
    fi
  fi

  UIPASS="$newpass"

  # 更新配置文件（假设密码为常见字母数字，避免复杂转义导致脚本出错）
  if [[ -f "$CONFIG_FILE" ]]; then
    sed -i "s/^UIPASS=.*/UIPASS=\"${UIPASS}\"/" "$CONFIG_FILE" 2>/dev/null || true
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
  fi

  setupservice
  restart
  log_info "UI密码已更新"
}

set_port(){
  need_root
  local newport="${1:-}"
  if [[ -z "$newport" ]]; then
    read -p "请输入新的端口: " newport
  fi
  if [[ -z "$newport" ]]; then
    log_err "端口不能为空"; exit 1
  fi
  
  check_port "$newport" || exit 1
  APIPORT="$newport"
  
  # 更新配置文件
  if [[ -f "$CONFIG_FILE" ]]; then
    sed -i "s/^APIPORT=.*/APIPORT=\"${APIPORT}\"/" "$CONFIG_FILE"
  fi
  
  setupservice
  restart
  log_info "端口已更新：${APIPORT}"
}


show_config(){
  need_root
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE" 2>/dev/null || true
  fi
  title "运行配置(端口/UI用户/扫描账号)"
  echo "端口(APIPORT): ${APIPORT:-8000}"
  echo "UI用户: admin"
  echo "扫描账号(SCANUSER): ${SCANUSER:-admin}"
  echo "扫描密码(SCANPASS): 已设置(隐藏)"
  echo ""
  systemctl is-active board-manager-v4.service >/dev/null 2>&1 && echo "服务(v4): active" || echo "服务(v4): inactive"
  systemctl is-active board-manager-v6.service >/dev/null 2>&1 && echo "服务(v6): active" || echo "服务(v6): inactive"
}

show_urls(){
  need_root
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE" 2>/dev/null || true
  fi
  title "访问地址(IPv4/IPv6/本地)"
  local ip4 ip6
  ip4=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}' | head -n1 || true)
  if [[ -z "$ip4" ]]; then ip4=$(hostname -I 2>/dev/null | awk '{print $1}' || true); fi
  ip6=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/ {print $2}' | cut -d/ -f1 | head -n1 || true)
  [[ -n "$ip4" ]] && echo "IPv4访问： http://${ip4}:${APIPORT}/" || echo "IPv4访问： (未检测到)"
  [[ -n "$ip6" ]] && echo "IPv6访问： http://[${ip6}]:${APIPORT}/" || echo "IPv6访问： (未检测到)"
  echo "本地访问： http://127.0.0.1:${APIPORT}/"
  echo ""
}

set_scan_cred(){
  need_root
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE" 2>/dev/null || true
  fi
  title "设置扫描账号/密码"
  local u p1 p2
  read -p "请输入扫描账号(当前 ${SCANUSER:-admin}): " u || true
  u="${u:-${SCANUSER:-admin}}"
  while true; do
    read -p "请输入扫描密码(可见输入): " p1 || true
    [[ -n "$p1" ]] || { log_err "密码不能为空"; continue; }
    read -p "请确认扫描密码: " p2 || true
    [[ "$p1" == "$p2" ]] || { log_err "两次输入不一致"; continue; }
    break
  done
  SCANUSER="$u"
  SCANPASS="$p1"
  if [[ -f "$CONFIG_FILE" ]]; then
    sed -i "s/^SCANUSER=.*/SCANUSER=\"${SCANUSER}\"/" "$CONFIG_FILE" 2>/dev/null || true
    sed -i "s/^SCANPASS=.*/SCANPASS=\"${SCANPASS}\"/" "$CONFIG_FILE" 2>/dev/null || true
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
  fi
  setupservice
  restart
  log_info "扫描账号/密码已更新"
}

menu(){
  while true; do
    echo ""
    title "lvyou 管理菜单(运维工具)"
    echo "1) 安装/更新"
    echo "2) 查看状态"
    echo "3) 重启服务"
    echo "4) 查看日志(最近200行)"
    echo "5) 设置UI密码"
    echo "6) 设置端口"
    echo "7) 备份数据"
    echo "8) 恢复数据"
    echo "9) 卸载"
    echo "10) 查看运行配置(端口/UI用户/扫描账号)"
    echo "11) 显示访问地址(IPv4/IPv6/本地)"
    echo "12) 设置扫描账号/密码"
    echo "0) 退出"
    echo ""
    read -p "请输入数字选择: " c || true
    case "$c" in
      1) installall ;;
      2) status ;;
      3) restart ;;
      4) logs 200 ;;
      5) set_ui_pass ;;
      6) set_port ;;
      7) backup_data ;;
      8) restore_data ;;
      9) uninstall ;;
      10) show_config ;;
      11) show_urls ;;
      12) set_scan_cred ;;
      0) exit 0 ;;
      *) log_warn "无效选择" ;;
    esac
  done
}

case "$CMD" in
  install) installall ;;
  scan)
    need_root
    if [[ -z "${CIDR:-}" ]]; then CIDR=$(auto_detect_cidr); fi
    doscan "$CIDR" "$SCANUSER" "$SCANPASS"
    ;;
  status) status ;;
  restart) restart ;;
  logs) logs "$@" ;;
  uninstall) uninstall "$@" ;;
  backup) backup_data ;;
  restore) restore_data "$@" ;;
  set-ui-pass) set_ui_pass "${1:-}" ;;
  set-port) set_port "${1:-}" ;;
  show-config) show_config ;;
  show-urls) show_urls ;;
  set-scan-cred) set_scan_cred ;;
  menu) menu ;;
  patch-sim-display) patch_sim_display ;;
  help|*) help ;;
esac

cleanup_temp
exit 0
