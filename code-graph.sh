#!/bin/bash
set -euo pipefail

# 工作区 codegraph 索引脚本
# 用法: code-graph.sh [工作区路径] [排除目录]
#   工作区默认为脚本所在目录的上一级；排除目录默认为本脚本所在目录
#   （工具包以 git clone 方式放入工作区时，其自身 .git 不应建索引）
#
# 行为：
#   - CLI：优先 PATH 上的 codegraph，缺失时回退 npx -y @colbymchenry/codegraph
#   - 工作区根：无论是否 git 仓库都确保 .codegraph 存在（MCP server cwd 在根，
#     无索引会进入静默态）
#   - 各含 .git 的子仓库：逐个 init（已存在 .codegraph 则跳过）
#   - 跳过 node_modules 与排除目录内部

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${1:-$(dirname "$SCRIPT_DIR")}"
EXCLUDE="${2:-$SCRIPT_DIR}"
WORKSPACE="$(cd "$WORKSPACE" && pwd)"
EXCLUDE="${EXCLUDE%/}"

# CLI 解析：codegraph 优先，npx 回退
if command -v codegraph >/dev/null 2>&1; then
    CG=(codegraph)
else
    command -v npx >/dev/null 2>&1 || { echo "❌ 未找到 codegraph，且 npx 不可用"; exit 1; }
    CG=(npx -y @colbymchenry/codegraph)
fi

init_one() {
    local repo="$1"
    if [ -d "$repo/.codegraph" ]; then
        echo "[跳过] ${repo}（.codegraph 已存在）"
        return 0
    fi
    echo "▶ 初始化: $repo"
    (cd "$repo" && "${CG[@]}" init)
    echo "----------------------------------------"
}

echo "▶ 工作区: $WORKSPACE"
echo "▶ CLI: ${CG[*]}"

# 工作区根：必建索引（MCP server cwd 在根）
init_one "$WORKSPACE"

# 各含 .git 的子仓库（排除工具包自身与 node_modules）
# find 对个别无权限目录报错不致命，仅警告
find "$WORKSPACE" \
    \( -name node_modules -o -path "$EXCLUDE" \) -prune -o \
    -type d -name .git -print 2>/dev/null | while read -r git_dir; do
    repo_path="$(dirname "$git_dir")"
    if [ "$repo_path" = "$WORKSPACE" ]; then continue; fi   # 根已处理
    init_one "$repo_path"
done || echo "[warn] 子仓库扫描部分失败（权限等原因），已忽略"

echo "✅ codegraph 索引完成（根目录 + 各子仓库）"
