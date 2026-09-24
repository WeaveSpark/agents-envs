#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
#  bootstrap.sh — 一键搭建 AI 工程环境（macOS / Linux）
#
#  用法（在本工具包目录内执行，默认作用于其父级工作区）：
#    bash <工具包路径>/bootstrap.sh [选项]
#
#  做五件事：
#    1. 预检依赖：git / curl / node+npm / python3(>=3.10) / pipx
#    2. 安装三个 MCP 工具（已存在则跳过，幂等可重跑）：
#       - aoci       GitHub Releases 单二进制 → ~/bin/aoci（SHA256SUMS 校验）
#       - mnemosyne  pipx 安装 PyPI 包 mnemosyne-memory[EXTRAS]
#       - codegraph  无需安装，npx 按需拉起（此处仅预热 npm 缓存）
#    3. 由模板生成 <工作区>/.trae/mcp.json（解析本机二进制绝对路径）
#    4. AOCI 工作区初始化：init（缺骨架时）+ scan（缺基线时）
#    5. codegraph 索引：工作区根 + 各含 .git 的子仓库
#
#  选项：
#    --workspace <路径>   显式指定目标工作区（默认：本工具包目录的父目录）
#    --skip-install       跳过工具安装，仅部署配置与初始化
#    -h | --help          帮助
#
#  环境变量：
#    AOCI_VERSION         aoci 发布标签（默认 v0.1.0-rc14；rc 为预发布，
#                         GitHub latest API 不含预发布，故显式固定）
#    MNEMOSYNE_EXTRAS     pip extras，默认 all（与既有工作区一致；
#                         可改为 "mcp,embeddings" 瘦身）
#    PIP_INDEX_URL        pip/pipx 索引源；未设置时按
#                         [阿里云镜像 → 腾讯镜像 → 默认 PyPI] 顺序回退
#    CODEGRAPH_SKIP_WARMUP=1  跳过 codegraph npm 缓存预热
#    GITHUB_API / GITHUB_DL  GitHub 基址覆盖（代理场景用）
# ──────────────────────────────────────────────────────────────
set -euo pipefail

TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AOCI_VERSION="${AOCI_VERSION:-v0.1.0-rc14}"
MNEMOSYNE_EXTRAS="${MNEMOSYNE_EXTRAS:-all}"
GITHUB_DL="${GITHUB_DL:-https://github.com}"
AOCI_REPO="aoci-spec/aoci-code"
AOCI_HOME_BIN="$HOME/bin/aoci"
MNEMOSYNE_DEFAULT_BIN="$HOME/.local/bin/mnemosyne"
PYPI_MIRRORS=(
  "https://mirrors.aliyun.com/pypi/simple/"
  "https://mirrors.cloud.tencent.com/pypi/simple/"
  "" # 空串 = pip 默认源（PyPI）
)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RESET='\033[0m'
info()  { echo -e "${CYAN}[info]${RESET}  $1"; }
ok()    { echo -e "${GREEN}[ok]${RESET}    $1"; }
warn()  { echo -e "${YELLOW}[warn]${RESET}  $1"; }
err()   { echo -e "${RED}[error]${RESET} $1"; }
step()  { echo ""; echo -e "${CYAN}== $1 ==${RESET}"; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# ── 参数解析 ──────────────────────────────────────────────────
WORKSPACE=""
SKIP_INSTALL=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace) WORKSPACE="${2:-}"; [[ -n "$WORKSPACE" ]] || { err "--workspace 需要路径参数"; exit 1; }; shift 2 ;;
    --skip-install) SKIP_INSTALL=true; shift ;;
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{1,2\}//'; exit 0 ;;
    *) err "未知参数: $1（--help 查看用法）"; exit 1 ;;
  esac
done

if [[ -z "$WORKSPACE" ]]; then
  WORKSPACE="$(dirname "$TOOLKIT_DIR")"
fi
[[ -d "$WORKSPACE" ]] || { err "工作区目录不存在: $WORKSPACE"; exit 1; }
WORKSPACE="$(cd "$WORKSPACE" && pwd)"
[[ -w "$WORKSPACE" ]] || { err "工作区不可写: $WORKSPACE"; exit 1; }

info "工具包: $TOOLKIT_DIR"
info "工作区: $WORKSPACE"

# ── 1. 依赖预检 ───────────────────────────────────────────────
step "1/5 依赖预检"

need_cmd() { command -v "$1" >/dev/null 2>&1; }

MISSING=()
for c in git curl node npm python3; do
  if need_cmd "$c"; then
    ok "$c ($(command -v "$c"))"
  else
    MISSING+=("$c"); err "$c 未安装"
  fi
done

if python3 -c 'import sys;sys.exit(0 if sys.version_info>=(3,10) else 1)' 2>/dev/null; then
  ok "python3 >=3.10 ($(python3 -V 2>&1))"
else
  err "python3 需要 >=3.10（mnemosyne 的 mcp extra 要求，当前 $(python3 -V 2>&1)）"
  MISSING+=("python3>=3.10")
fi

if [[ ${#MISSING[@]} -gt 0 ]]; then
  err "缺少必要依赖: ${MISSING[*]}"
  echo    "  macOS:  brew install git node python pipx"
  echo    "  Linux:  用系统包管理器安装；pipx 可 apt/brew 安装，或 python3 -m pip install --user pipx"
  exit 1
fi

node_major="$(node -p 'parseInt(process.versions.node.split(".")[0],10)' 2>/dev/null || echo 0)"
if (( node_major < 18 )); then
  warn "node 版本偏低（v${node_major}.x，建议 >=18），codegraph 可能无法运行"
else
  ok "node v$(node -v)"
fi

# pipx：优先命令行，其次 python3 -m pipx，缺则经镜像 pip --user 自动装
PIP_RUN=()
if need_cmd pipx; then
  PIP_RUN=(pipx); ok "pipx ($(command -v pipx))"
elif python3 -m pipx --version >/dev/null 2>&1; then
  PIP_RUN=(python3 -m pipx); ok "pipx (python3 -m pipx)"
else
  warn "pipx 未安装，尝试经 pip 镜像自动安装（--user）"
  pipx_installed=false
  pip_install_flags=(--user --quiet)
  for idx in "${PYPI_MIRRORS[@]}"; do
    idx_flag=(); [[ -n "$idx" ]] && idx_flag=(-i "$idx") || true
    # PEP 668（Debian/Ubuntu）场景补 --break-system-packages 再试一次
    if python3 -m pip install "${pip_install_flags[@]}" "${idx_flag[@]}" pipx 2>/dev/null \
      || python3 -m pip install "${pip_install_flags[@]}" --break-system-packages "${idx_flag[@]}" pipx 2>/dev/null; then
      PIP_RUN=(python3 -m pipx); pipx_installed=true; ok "pipx 已自动安装 (python3 -m pipx)"; break
    fi
  done
  $pipx_installed || { err "pipx 自动安装失败，请手动安装后重跑（如 apt install pipx / brew install pipx）"; exit 1; }
fi

# ── 2. 安装三个 MCP 工具 ──────────────────────────────────────
step "2/5 安装 MCP 工具（aoci / mnemosyne / codegraph）"

# ---- 2.1 aoci ----
resolve_aoci() {
  local p
  for p in "$(command -v aoci 2>/dev/null || true)" "$AOCI_HOME_BIN" "/usr/local/bin/aoci"; do
    if [[ -n "$p" && -x "$p" ]] && "$p" --version >/dev/null 2>&1; then
      echo "$p"; return 0
    fi
  done
  return 1
}

AOCI_BIN=""
if AOCI_BIN="$(resolve_aoci)"; then
  ok "aoci 已就绪: $AOCI_BIN ($("$AOCI_BIN" --version 2>/dev/null | head -1))"
elif [[ "$SKIP_INSTALL" == true ]]; then
  err "aoci 不可用且指定了 --skip-install"; exit 1
else
  info "下载 aoci $AOCI_VERSION ..."
  os_arch() {
    local s m
    s="$(uname -s | tr '[:upper:]' '[:lower:]')"; m="$(uname -m)"
    case "$s-$m" in
      darwin-arm64|darwin-arm64e) echo "darwin_arm64" ;;
      darwin-x86_64|darwin-amd64) echo "darwin_amd64" ;;
      linux-x86_64|linux-amd64)   echo "linux_amd64" ;;
      linux-aarch64|linux-arm64)  echo "linux_arm64" ;;
      *) return 1 ;;
    esac
  }
  PLATFORM="$(os_arch)" || { err "不支持的系统: $(uname -s)-$(uname -m)"; exit 1; }
  VER_NUM="${AOCI_VERSION#v}"
  ASSET="aoci_${VER_NUM}_${PLATFORM}.tar.gz"
  TMP_DL="$(mktemp -d)"
  trap 'rm -rf "$TMP_DL"' EXIT

  if ! curl -fSL --retry 3 -o "$TMP_DL/$ASSET" "$GITHUB_DL/$AOCI_REPO/releases/download/$AOCI_VERSION/$ASSET"; then
    err "下载失败: $GITHUB_DL/$AOCI_REPO/releases/download/$AOCI_VERSION/$ASSET"
    echo    "  可尝试: AOCI_VERSION=<其他标签> 重跑，或设置代理后重试"
    exit 1
  fi
  # SHA256SUMS 校验（拿不到校验文件时警告但不阻塞）
  if curl -fsSL --retry 2 -o "$TMP_DL/SHA256SUMS" "$GITHUB_DL/$AOCI_REPO/releases/download/$AOCI_VERSION/SHA256SUMS"; then
    expect="$(awk -v a="$ASSET" '$2==a {print $1}' "$TMP_DL/SHA256SUMS" | tr -d '\r')"
    actual="$(sha256_of "$TMP_DL/$ASSET")"
    if [[ -n "$expect" && "$expect" != "$actual" ]]; then
      err "SHA256 校验失败: ${ASSET}（期望 ${expect}，实际 ${actual}）"; exit 1
    fi
    [[ -n "$expect" ]] && ok "SHA256 校验通过" || true
  else
    warn "未能获取 SHA256SUMS，跳过校验"
  fi
  tar -xzf "$TMP_DL/$ASSET" -C "$TMP_DL"
  bin_path="$(find "$TMP_DL" -type f -name aoci | head -1)"
  [[ -n "$bin_path" ]] || { err "压缩包内未找到 aoci 二进制"; exit 1; }
  mkdir -p "$HOME/bin"
  cp "$bin_path" "$AOCI_HOME_BIN"
  chmod +x "$AOCI_HOME_BIN"
  command -v xattr >/dev/null 2>&1 && xattr -d com.apple.quarantine "$AOCI_HOME_BIN" 2>/dev/null || true
  AOCI_BIN="$AOCI_HOME_BIN"
  ok "aoci 已安装: $AOCI_BIN ($("$AOCI_BIN" --version 2>/dev/null | head -1))"
  [[ ":$PATH:" != *":$HOME/bin:"* ]] && warn "PATH 未含 ~/bin（仅影响终端直呼 aoci，MCP 不受影响）" || true
fi

# ---- 2.2 mnemosyne ----
resolve_mnemosyne() {
  local p
  for p in "$(command -v mnemosyne 2>/dev/null || true)" "$MNEMOSYNE_DEFAULT_BIN"; do
    if [[ -n "$p" && -x "$p" ]]; then echo "$p"; return 0; fi
  done
  return 1
}

MNEMOSYNE_BIN=""
if MNEMOSYNE_BIN="$(resolve_mnemosyne)"; then
  ok "mnemosyne 已就绪: $MNEMOSYNE_BIN"
elif [[ "$SKIP_INSTALL" == true ]]; then
  err "mnemosyne 不可用且指定了 --skip-install"; exit 1
else
  SPEC="mnemosyne-memory[${MNEMOSYNE_EXTRAS}]"
  info "pipx 安装 $SPEC ..."
  idx_list=()
  [[ -n "${PIP_INDEX_URL:-}" ]] && idx_list+=("$PIP_INDEX_URL") || true
  for idx in "${PYPI_MIRRORS[@]}"; do idx_list+=("$idx"); done

  installed=false
  for idx in "${idx_list[@]}"; do
    if [[ -z "$idx" ]]; then
      info "尝试索引源: 默认源(PyPI)"
      if "${PIP_RUN[@]}" install "$SPEC"; then installed=true; break; fi
    else
      info "尝试索引源: $idx"
      if env PIP_INDEX_URL="$idx" "${PIP_RUN[@]}" install "$SPEC"; then installed=true; break; fi
    fi
  done
  $installed || { err "mnemosyne 安装失败（所有索引源均失败），可设 PIP_INDEX_URL=<可用镜像> 重试"; exit 1; }

  MNEMOSYNE_BIN="$(resolve_mnemosyne)" || {
    err "安装完成但找不到 mnemosyne 可执行文件（pipx bin 目录不在预期位置）"
    "${PIP_RUN[@]}" list 2>/dev/null || true
    exit 1
  }
  ok "mnemosyne 已安装: $MNEMOSYNE_BIN"
  [[ ":$PATH:" != *":$HOME/.local/bin:"* ]] && warn "PATH 未含 ~/.local/bin（仅影响终端直呼 mnemosyne，MCP 不受影响）" || true
fi

# ---- 2.3 codegraph ----
# 无需预装：MCP 经 npx 按需拉起。此处预热 npm 缓存，首次 IDE 启动更快（失败仅警告）。
if [[ "${CODEGRAPH_SKIP_WARMUP:-0}" == "1" ]]; then
  info "跳过 codegraph 预热（CODEGRAPH_SKIP_WARMUP=1）"
elif CG_VER="$(npx -y @colbymchenry/codegraph --version 2>/dev/null | tail -1)"; then
  ok "codegraph 可用 (npx, v${CG_VER})"
else
  warn "codegraph npx 预热失败（不影响配置生成，首次 IDE 使用时会再拉取）"
fi

# ── 3. 生成 .trae/mcp.json ────────────────────────────────────
step "3/5 生成 $WORKSPACE/.trae/mcp.json"

TRAE_DIR="$WORKSPACE/.trae"
MCP_JSON="$TRAE_DIR/mcp.json"
mkdir -p "$TRAE_DIR"

NEW_MCP="$(mktemp)"
python3 - "$TOOLKIT_DIR/trae_mcp_config.json" "$NEW_MCP" "$MNEMOSYNE_BIN" "$AOCI_BIN" <<'PY'
import json, sys
tpl_path, out_path, mnemosyne, aoci = sys.argv[1:5]
cfg = json.load(open(tpl_path, encoding="utf-8"))
cfg["mcpServers"]["mnemosyne"]["command"] = mnemosyne
cfg["mcpServers"]["aoci"]["command"] = aoci
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY

if [[ -f "$MCP_JSON" ]] && cmp -s "$NEW_MCP" "$MCP_JSON"; then
  ok "mcp.json 已是最新，无需更新"
else
  if [[ -f "$MCP_JSON" ]]; then
    cp "$MCP_JSON" "$MCP_JSON.bak.$(date +%Y%m%d%H%M%S)"
    info "原 mcp.json 已备份为 mcp.json.bak.<时间戳>"
  fi
  mv "$NEW_MCP" "$MCP_JSON"
  NEW_MCP=""
  python3 -m json.tool "$MCP_JSON" >/dev/null && ok "已生成 ${MCP_JSON}（JSON 校验通过）"
fi
[[ -n "$NEW_MCP" ]] && rm -f "$NEW_MCP"

# ── 4. AOCI 工作区初始化 ──────────────────────────────────────
step "4/5 AOCI 初始化（init + scan）"

if [[ ! -f "$WORKSPACE/aoci.txt" ]]; then
  "$AOCI_BIN" --repo "$WORKSPACE" init --locale zh-CN
  ok "aoci init 完成（AGENTS.md 缺失时会一并生成，已存在则不覆盖）"
else
  ok "aoci.txt 已存在，跳过 init（不覆盖既有正式认知）"
fi

if [[ -f "$WORKSPACE/.aoci/baseline.json" ]]; then
  ok "基线已存在，跳过 scan（重建需 aoci --repo <工作区> scan --force）"
else
  "$AOCI_BIN" --repo "$WORKSPACE" scan
  ok "基线已建立"
fi

# ── 5. codegraph 索引 ─────────────────────────────────────────
step "5/5 codegraph 索引（工作区根 + 子仓库）"

bash "$TOOLKIT_DIR/code-graph.sh" "$WORKSPACE" "$TOOLKIT_DIR"

# ── 收尾 ──────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}===== AI 工程环境搭建完成 =====${RESET}"
echo "  MCP 服务   : codegraph / mnemosyne / aoci → $MCP_JSON"
echo "  记忆库     : $WORKSPACE/.mnemosyne/data（bank=$(basename "$WORKSPACE")）"
echo "  认知索引   : $WORKSPACE/aoci.txt (+ .aoci/)"
echo "  代码图谱   : $WORKSPACE/.codegraph/ 及各子仓库"
echo ""
echo "后续步骤:"
echo "  1. 在 Trae 中重新打开/Reload 该工作区，使 .trae/mcp.json 生效"
echo "  2. Windows 同事请使用 bootstrap.ps1（本脚本仅覆盖 macOS/Linux）"
if [[ ":$PATH:" != *":$HOME/bin:"* || ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
  echo "  3. 建议把 ~/bin 与 ~/.local/bin 加入 PATH（仅影响终端直呼 aoci/mnemosyne）"
fi
