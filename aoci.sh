#!/bin/bash
set -euo pipefail

# ========== 配置区域 ==========
# 用法: aoci.sh [工作区路径]
#   不传参时默认为脚本所在目录的上一级（工具包子目录部署模式）
# 幂等：aoci.txt 缺失才 init；基线缺失才 scan
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${1:-$(dirname "$SCRIPT_DIR")}"
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"

# aoci 可执行文件路径：优先 PATH，其次 ~/bin/aoci
AOCI_PATH=$(command -v aoci 2>/dev/null || echo "$HOME/bin/aoci")
# ==============================

# 1. 检查 aoci
if [ ! -x "$AOCI_PATH" ]; then
    echo "❌ 未找到可执行的 aoci：$AOCI_PATH"
    echo "   请先运行 bootstrap.sh 安装，或自行安装后重试"
    exit 1
fi

echo "📂 工作区：$PROJECT_ROOT"
AOCI_VER="$("$AOCI_PATH" --version 2>/dev/null | head -1 || echo "")"
echo "🔧 aoci：$AOCI_PATH ($AOCI_VER)"

# 2. 工程初始化（幂等：仅骨架缺失时）
if [ ! -f "$PROJECT_ROOT/aoci.txt" ]; then
    echo "🚀 执行 AOCI 初始化..."
    "$AOCI_PATH" --repo "$PROJECT_ROOT" init --locale zh-CN
else
    echo "✅ 检测到 aoci.txt，跳过 init（不覆盖既有正式认知）。"
fi

# 3. 建立基线（幂等：仅基线缺失时；重建需手动 scan --force）
if [ -f "$PROJECT_ROOT/.aoci/baseline.json" ]; then
    echo "✅ 基线已存在，跳过 scan（重建：aoci --repo \"$PROJECT_ROOT\" scan --force）"
else
    echo "🔍 执行 AOCI 扫描..."
    "$AOCI_PATH" --repo "$PROJECT_ROOT" scan
fi

# 4. 完成
echo "✅ AOCI 工程初始化完成。"
echo "💡 提示：aoci.txt 等核心文件必须保留在项目根目录才能正常参与 Git 治理。"
echo "💡 如需隐藏显示，请在编辑器中配置隐藏，切勿移动物理文件。"
