# ──────────────────────────────────────────────────────────────
#  bootstrap.ps1 — 一键搭建 AI 工程环境（Windows）
#
#  ⚠ 本脚本是 bootstrap.sh（macOS/Linux）的对齐移植，
#    未在真实 Windows 环境实测；遇到问题请对照 bootstrap.sh 排查。
#
#  用法（在本工具包目录内执行，默认作用于其父级工作区）：
#    powershell -ExecutionPolicy Bypass -File <工具包路径>\bootstrap.ps1 [选项]
#
#  做五件事（与 bootstrap.sh 相同）：
#    1. 预检依赖：git / node+npm / python(>=3.10) / pipx
#    2. 安装三个 MCP 工具（已存在则跳过，幂等可重跑）：
#       - aoci       GitHub Releases 单二进制 → ~\bin\aoci.exe（SHA256SUMS 校验）
#       - mnemosyne  pipx 安装 PyPI 包 mnemosyne-memory[EXTRAS]
#       - codegraph  无需安装，npx 按需拉起（此处仅预热 npm 缓存）
#    3. 由模板生成 <工作区>\.trae\mcp.json（解析本机二进制绝对路径）
#    4. AOCI 工作区初始化：init（缺骨架时）+ scan（缺基线时）
#    5. codegraph 索引：工作区根 + 各含 .git 的子仓库
#
#  选项：
#    -Workspace <路径>   显式指定目标工作区（默认：本工具包目录的父目录）
#    -SkipInstall        跳过工具安装，仅部署配置与初始化
#    -Help               显示本帮助
#
#  环境变量：
#    AOCI_VERSION         aoci 发布标签（默认 v0.1.0-rc14；rc 为预发布，
#                         GitHub latest API 不含预发布，故显式固定）
#    MNEMOSYNE_EXTRAS     pip extras，默认 all；Windows 上若 llama-cpp
#                         依赖装不上，可改为 "mcp" 瘦身
#    PIP_INDEX_URL        pip/pipx 索引源；未设置时按
#                         [阿里云镜像 → 腾讯镜像 → 默认 PyPI] 顺序回退
#    CODEGRAPH_SKIP_WARMUP=1  跳过 codegraph npm 缓存预热
#    GITHUB_DL            GitHub 基址覆盖（代理场景用）
# ──────────────────────────────────────────────────────────────
[CmdletBinding()]
param(
    [string]$Workspace,
    [switch]$SkipInstall,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
# 老版 Windows PowerShell 默认 TLS 较低，强制启用 TLS 1.2
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

function Info([string]$m) { Write-Host "[info]  $m" -ForegroundColor Cyan }
function Ok([string]$m)   { Write-Host "[ok]    $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "[warn]  $m" -ForegroundColor Yellow }
function Err([string]$m)  { Write-Host "[error] $m" -ForegroundColor Red }
function Step([string]$m) { Write-Host ''; Write-Host "== $m ==" -ForegroundColor Cyan }

if ($Help) {
    # 打印文件头部注释（两条 ── 分隔线之间）
    $seen = 0
    foreach ($l in (Get-Content -LiteralPath $PSCommandPath)) {
        Write-Host ($l -replace '^# ?', '')
        if ($l -match '^# ──') { $seen++ }
        if ($seen -ge 2) { break }
    }
    exit 0
}

$ToolkitDir     = Split-Path -Parent $PSCommandPath
$AociVersion    = if ($env:AOCI_VERSION)     { $env:AOCI_VERSION }     else { 'v0.1.0-rc14' }
$MnemosyneExtras= if ($env:MNEMOSYNE_EXTRAS) { $env:MNEMOSYNE_EXTRAS } else { 'all' }
$GitHubDl       = if ($env:GITHUB_DL)        { $env:GITHUB_DL }        else { 'https://github.com' }
$AociRepo = 'aoci-spec/aoci-code'
$AociHomeBin        = Join-Path $HOME 'bin\aoci.exe'
$MnemosyneDefaultBin = Join-Path $HOME '.local\bin\mnemosyne.exe'
$PypiMirrors = @(
    'https://mirrors.aliyun.com/pypi/simple/'
    'https://mirrors.cloud.tencent.com/pypi/simple/'
    ''   # 空串 = pip 默认源（PyPI）
)

if (-not $Workspace) { $Workspace = Split-Path -Parent $ToolkitDir }
if (-not (Test-Path -LiteralPath $Workspace -PathType Container)) {
    Err "工作区目录不存在: $Workspace"; exit 1
}
$Workspace = (Resolve-Path -LiteralPath $Workspace).Path

Info "工具包: $ToolkitDir"
Info "工作区: $Workspace"

# ── 1. 依赖预检 ───────────────────────────────────────────────
Step '1/5 依赖预检'

$missing = @()
foreach ($c in @('git','node','npm','python')) {
    $cmd = Get-Command $c -ErrorAction SilentlyContinue
    if ($cmd) { Ok "$c ($($cmd.Source))" }
    else { $missing += $c; Err "$c 未安装" }
}

if (Get-Command python -ErrorAction SilentlyContinue) {
    & python -c "import sys;sys.exit(0 if sys.version_info>=(3,10) else 1)" *> $null
    if ($LASTEXITCODE -eq 0) {
        $pyVer = (& python -V 2>&1)
        Ok "python >=3.10 ($pyVer)"
    } else {
        Err "python 需要 >=3.10（mnemosyne 的 mcp extra 要求，当前 $(& python -V 2>&1)）"
        $missing += 'python>=3.10'
    }
}

if (Get-Command node -ErrorAction SilentlyContinue) {
    $nodeMajor = [int](& node -p "parseInt(process.versions.node.split('.')[0],10)")
    if ($nodeMajor -lt 18) {
        Warn "node 版本偏低（v$nodeMajor.x，建议 >=18），codegraph 可能无法运行"
    } else {
        Ok "node $(& node -v)"
    }
}

if ($missing.Count -gt 0) {
    Err "缺少必要依赖: $($missing -join ' ')"
    Write-Host '  Windows: 安装 Git for Windows / Node.js LTS / Python 3.10+（python.org 安装时勾选 Add to PATH）'
    exit 1
}

# pipx：优先命令行，其次 python -m pipx，缺则经镜像 pip --user 自动装
$PipCmd = $null; $PipArgs = @()
if (Get-Command pipx -ErrorAction SilentlyContinue) {
    $PipCmd = 'pipx'; $PipArgs = @()
    Ok "pipx ($((Get-Command pipx).Source))"
} else {
    & python -m pipx --version *> $null
    if ($LASTEXITCODE -eq 0) {
        $PipCmd = 'python'; $PipArgs = @('-m','pipx')
        Ok 'pipx (python -m pipx)'
    } else {
        Warn 'pipx 未安装，尝试经 pip 镜像自动安装（--user）'
        $pipxInstalled = $false
        $savedIdx = $env:PIP_INDEX_URL
        try {
            foreach ($idx in $PypiMirrors) {
                if ($idx) { $env:PIP_INDEX_URL = $idx; Info "尝试索引源: $idx" }
                else      { $env:PIP_INDEX_URL = $null; Info '尝试索引源: 默认源(PyPI)' }
                & python -m pip install --user --quiet pipx *> $null
                if ($LASTEXITCODE -eq 0) {
                    $PipCmd = 'python'; $PipArgs = @('-m','pipx')
                    $pipxInstalled = $true
                    Ok 'pipx 已自动安装 (python -m pipx)'
                    break
                }
            }
        } finally {
            $env:PIP_INDEX_URL = $savedIdx
        }
        if (-not $pipxInstalled) {
            Err 'pipx 自动安装失败，请手动安装后重跑（python -m pip install --user pipx）'
            exit 1
        }
    }
}

# ── 2. 安装三个 MCP 工具 ──────────────────────────────────────
Step '2/5 安装 MCP 工具（aoci / mnemosyne / codegraph）'

# ---- 2.1 aoci ----
function Resolve-Aoci {
    $c = Get-Command aoci -ErrorAction SilentlyContinue
    if ($c) {
        & $c.Source --version *> $null
        if ($LASTEXITCODE -eq 0) { return $c.Source }
    }
    if (Test-Path -LiteralPath $AociHomeBin) {
        & $AociHomeBin --version *> $null
        if ($LASTEXITCODE -eq 0) { return $AociHomeBin }
    }
    return $null
}

$AociBin = Resolve-Aoci
if ($AociBin) {
    $v = (& $AociBin --version 2>&1 | Select-Object -First 1)
    Ok "aoci 已就绪: $AociBin ($v)"
} elseif ($SkipInstall) {
    Err 'aoci 不可用且指定了 -SkipInstall'; exit 1
} else {
    Info "下载 aoci $AociVersion ..."
    $platform = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'windows_arm64' } else { 'windows_amd64' }
    $verNum = $AociVersion.TrimStart('v')
    $asset = "aoci_${verNum}_${platform}.zip"
    $tmp = Join-Path $env:TEMP ("aoci-bootstrap-" + [IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $ProgressPreference = 'SilentlyContinue'   # 关进度条，加速大文件下载
    try {
        $assetPath = Join-Path $tmp $asset
        $url = "$GitHubDl/$AociRepo/releases/download/$AociVersion/$asset"
        try {
            Invoke-WebRequest -Uri $url -OutFile $assetPath -UseBasicParsing
        } catch {
            Err "下载失败: $url"
            Write-Host '  可尝试: AOCI_VERSION=<其他标签> 重跑，或设置代理后重试'
            exit 1
        }
        # SHA256SUMS 校验（拿不到校验文件时警告但不阻塞）
        $sumsPath = Join-Path $tmp 'SHA256SUMS'
        $sumsUrl = "$GitHubDl/$AociRepo/releases/download/$AociVersion/SHA256SUMS"
        try {
            Invoke-WebRequest -Uri $sumsUrl -OutFile $sumsPath -UseBasicParsing
            $pattern = [regex]::Escape($asset) + '\s*$'
            $line = Get-Content -LiteralPath $sumsPath |
                Where-Object { $_ -match $pattern } | Select-Object -First 1
            $expect = $null
            if ($line) { $expect = ($line -split '\s+')[0].ToLower() }
            $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $assetPath).Hash.ToLower()
            if ($expect -and ($expect -ne $actual)) {
                Err "SHA256 校验失败: $asset（期望 $expect，实际 $actual）"
                exit 1
            }
            if ($expect) { Ok 'SHA256 校验通过' }
        } catch {
            Warn '未能获取 SHA256SUMS，跳过校验'
        }
        $extractDir = Join-Path $tmp 'extract'
        Expand-Archive -LiteralPath $assetPath -DestinationPath $extractDir -Force
        $bin = Get-ChildItem -LiteralPath $extractDir -Recurse -Filter 'aoci.exe' |
            Select-Object -First 1
        if (-not $bin) { Err '压缩包内未找到 aoci.exe'; exit 1 }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $AociHomeBin) | Out-Null
        Copy-Item -LiteralPath $bin.FullName -Destination $AociHomeBin -Force
        $AociBin = $AociHomeBin
        $v = (& $AociBin --version 2>&1 | Select-Object -First 1)
        Ok "aoci 已安装: $AociBin ($v)"
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
    if ($env:PATH -notlike "*$(Join-Path $HOME 'bin')*") {
        Warn 'PATH 未含 ~\bin（仅影响终端直呼 aoci，MCP 不受影响）'
    }
}

# ---- 2.2 mnemosyne ----
function Resolve-Mnemosyne {
    $c = Get-Command mnemosyne -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    if (Test-Path -LiteralPath $MnemosyneDefaultBin) { return $MnemosyneDefaultBin }
    return $null
}

$MnemosyneBin = Resolve-Mnemosyne
if ($MnemosyneBin) {
    Ok "mnemosyne 已就绪: $MnemosyneBin"
} elseif ($SkipInstall) {
    Err 'mnemosyne 不可用且指定了 -SkipInstall'; exit 1
} else {
    $spec = "mnemosyne-memory[$MnemosyneExtras]"
    Info "pipx 安装 $spec ..."
    $savedIdx = $env:PIP_INDEX_URL
    $idxList = @()
    if ($savedIdx) { $idxList += $savedIdx }
    $idxList += $PypiMirrors
    $installed = $false
    try {
        foreach ($idx in $idxList) {
            if ($idx) { $env:PIP_INDEX_URL = $idx; Info "尝试索引源: $idx" }
            else      { $env:PIP_INDEX_URL = $null; Info '尝试索引源: 默认源(PyPI)' }
            & $PipCmd @PipArgs install $spec
            if ($LASTEXITCODE -eq 0) { $installed = $true; break }
        }
    } finally {
        $env:PIP_INDEX_URL = $savedIdx
    }
    if (-not $installed) {
        Err 'mnemosyne 安装失败（所有索引源均失败），可设 PIP_INDEX_URL=<可用镜像> 重试'
        exit 1
    }
    $MnemosyneBin = Resolve-Mnemosyne
    if (-not $MnemosyneBin) {
        Err '安装完成但找不到 mnemosyne 可执行文件（pipx bin 目录不在预期位置）'
        & $PipCmd @PipArgs list
        exit 1
    }
    Ok "mnemosyne 已安装: $MnemosyneBin"
    if ($env:PATH -notlike "*$(Join-Path $HOME '.local\bin')*") {
        Warn 'PATH 未含 ~\.local\bin（仅影响终端直呼 mnemosyne，MCP 不受影响）'
    }
}

# ---- 2.3 codegraph ----
# 无需预装：MCP 经 npx 按需拉起。此处预热 npm 缓存，首次 IDE 启动更快（失败仅警告）。
if ($env:CODEGRAPH_SKIP_WARMUP -eq '1') {
    Info '跳过 codegraph 预热（CODEGRAPH_SKIP_WARMUP=1）'
} else {
    $cgVer = (& npx -y '@colbymchenry/codegraph' --version 2>$null | Select-Object -Last 1)
    if ($LASTEXITCODE -eq 0 -and $cgVer) { Ok "codegraph 可用 (npx, v$cgVer)" }
    else { Warn 'codegraph npx 预热失败（不影响配置生成，首次 IDE 使用时会再拉取）' }
}

# ── 3. 生成 .trae\mcp.json ────────────────────────────────────
Step "3/5 生成 $Workspace\.trae\mcp.json"

$TraeDir = Join-Path $Workspace '.trae'
$McpJson = Join-Path $TraeDir 'mcp.json'
New-Item -ItemType Directory -Force -Path $TraeDir | Out-Null

# 模板占位符 → 本机二进制路径（做 JSON 转义：反斜杠与引号）
function ConvertTo-JsonEscaped([string]$s) {
    return $s.Replace('\', '\\').Replace('"', '\"')
}
$tpl = Get-Content -LiteralPath (Join-Path $ToolkitDir 'trae_mcp_config.json') -Raw
if (-not $tpl) { Err '读取模板 trae_mcp_config.json 失败'; exit 1 }
$new = $tpl.Replace('__MNEMOSYNE_BIN__', (ConvertTo-JsonEscaped $MnemosyneBin))
$new = $new.Replace('__AOCI_BIN__', (ConvertTo-JsonEscaped $AociBin))
try { $new | ConvertFrom-Json | Out-Null }
catch { Err '模板渲染结果不是合法 JSON'; exit 1 }

$needWrite = $true
if (Test-Path -LiteralPath $McpJson) {
    $old = Get-Content -LiteralPath $McpJson -Raw
    if ($old -eq $new) { $needWrite = $false; Ok 'mcp.json 已是最新，无需更新' }
}
if ($needWrite) {
    if (Test-Path -LiteralPath $McpJson) {
        $stamp = Get-Date -Format 'yyyyMMddHHmmss'
        Copy-Item -LiteralPath $McpJson -Destination "$McpJson.bak.$stamp"
        Info '原 mcp.json 已备份为 mcp.json.bak.<时间戳>'
    }
    # UTF-8 无 BOM 写入
    [IO.File]::WriteAllText($McpJson, $new, (New-Object System.Text.UTF8Encoding $false))
    Ok "已生成 $McpJson（JSON 校验通过）"
}

# ── 4. AOCI 工作区初始化 ──────────────────────────────────────
Step '4/5 AOCI 初始化（init + scan）'

if (-not (Test-Path -LiteralPath (Join-Path $Workspace 'aoci.txt'))) {
    & $AociBin --repo $Workspace init --locale zh-CN
    if ($LASTEXITCODE -ne 0) { Err 'aoci init 失败'; exit 1 }
    Ok 'aoci init 完成（AGENTS.md 缺失时会一并生成，已存在则不覆盖）'
} else {
    Ok 'aoci.txt 已存在，跳过 init（不覆盖既有正式认知）'
}

if (Test-Path -LiteralPath (Join-Path $Workspace '.aoci\baseline.json')) {
    Ok '基线已存在，跳过 scan（重建需 aoci --repo <工作区> scan --force）'
} else {
    & $AociBin --repo $Workspace scan
    if ($LASTEXITCODE -ne 0) { Err 'aoci scan 失败'; exit 1 }
    Ok '基线已建立'
}

# ── 5. codegraph 索引 ─────────────────────────────────────────
Step '5/5 codegraph 索引（工作区根 + 子仓库）'

function Invoke-CgInit([string]$Repo) {
    Push-Location -LiteralPath $Repo
    try {
        if (Get-Command codegraph -ErrorAction SilentlyContinue) { & codegraph init }
        else { & npx -y '@colbymchenry/codegraph' init }
        return ($LASTEXITCODE -eq 0)
    } finally { Pop-Location }
}
function Init-One([string]$Repo) {
    if (Test-Path -LiteralPath (Join-Path $Repo '.codegraph')) {
        Write-Host "[跳过] $Repo（.codegraph 已存在）"
        return
    }
    Write-Host "▶ 初始化: $Repo"
    if (-not (Invoke-CgInit $Repo)) { Write-Host "[warn] $Repo 索引失败，已跳过" }
}

# 工作区根必建索引（MCP server 的 cwd 在根，无索引进静默态）
Init-One $Workspace

# 扫描子仓库（排除 node_modules 与工具包自身；超大仓库递归可能较慢）
$toolkitPrefix = $ToolkitDir.TrimEnd('\') + '\'
$gitDirs = @(Get-ChildItem -LiteralPath $Workspace -Directory -Recurse -Force -Filter '.git' -ErrorAction SilentlyContinue)
foreach ($g in $gitDirs) {
    if ($g.FullName -like '*\node_modules\*') { continue }
    if ($g.FullName.StartsWith($toolkitPrefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
    $repoPath = Split-Path -Parent $g.FullName
    if ($repoPath -eq $Workspace) { continue }
    Init-One $repoPath
}

# ── 收尾 ──────────────────────────────────────────────────────
Write-Host ''
Write-Host '===== AI 工程环境搭建完成 =====' -ForegroundColor Green
Write-Host "  MCP 服务   : codegraph / mnemosyne / aoci → $McpJson"
Write-Host "  记忆库     : $(Join-Path $Workspace '.mnemosyne\data')（bank=$(Split-Path -Leaf $Workspace)）"
Write-Host "  认知索引   : $(Join-Path $Workspace 'aoci.txt') (+ .aoci\)"
Write-Host "  代码图谱   : $(Join-Path $Workspace '.codegraph\') 及各子仓库"
Write-Host ''
Write-Host '后续步骤:'
Write-Host '  1. 在 Trae 中重新打开/Reload 该工作区，使 .trae\mcp.json 生效'
Write-Host '  2. macOS/Linux 同事请使用 bootstrap.sh（本脚本仅覆盖 Windows）'
$needPathTip = ($env:PATH -notlike "*$(Join-Path $HOME 'bin')*") -or
               ($env:PATH -notlike "*$(Join-Path $HOME '.local\bin')*")
if ($needPathTip) {
    Write-Host '  3. 建议把 ~\bin 与 ~\.local\bin 加入 PATH（仅影响终端直呼 aoci/mnemosyne）'
}
