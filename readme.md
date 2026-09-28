# agents-envs — AI 工程环境一键搭建工具包

把这个工具包克隆到你的工作区里（如 `agents-envs/`，跑完脚本会自动改名为 `.agents-envs/` 藏起来），运行一条命令，即可获得完整的 Trae AI 工程环境：**三个 MCP 服务**（codegraph / mnemosyne / aoci）+ **AOCI 仓库认知索引** + **代码图谱**。

## 快速开始

macOS / Linux：

```bash
cd ~/my-project
git clone <本仓库地址> agents-envs
bash agents-envs/bootstrap.sh
```

Windows（PowerShell）：

```powershell
cd C:\my-project
git clone <本仓库地址> agents-envs
powershell -ExecutionPolicy Bypass -File agents-envs\bootstrap.ps1
```

完成后在 Trae 中重新打开（或 Reload）该工作区，`.trae/mcp.json` 即生效。Agent 会话开始时先调 `aoci_rules` 建立本工程认知契约，再按需 `aoci_overview` 建立全局认知（见 `AGENTS.md` 尾部精简指引与 `AOCI.md`）。

> 脚本默认作用于**工具包目录的父目录**（即你的工作区根），并把工具包自动隐藏化为 `<工作区>/.agents-envs`——不碍眼，且仍是 git 仓库。也可以显式指定：
> `bootstrap.sh --workspace <路径>` / `bootstrap.ps1 -Workspace <路径>`（工具包在工作区外时不做重命名）。
> 重复运行安全：所有步骤幂等，已存在的一律跳过，不会覆盖已有认知与配置。

### 之后想更新环境

工具包留在 `.agents-envs/`，随时拉新版重跑即可：

```bash
cd ~/my-project/.agents-envs
git pull
bash bootstrap.sh          # PowerShell 用 bootstrap.ps1
```

> `.agents-envs/` 不会自动更新，务必先 `git pull` 成功再重跑，否则跑的还是旧版本。
> 若 `git pull` 报 `local changes would be overwritten`，通常是文件权限位（mode）差异所致：
> `git checkout -- .` 丢弃后重试即可（工具包不应有本地改动）。

## bootstrap 做的五件事

1. **依赖预检**：git / curl / node（建议 ≥18）/ python3 ≥3.10 / pipx（缺失时自动经 pip 镜像安装）；
2. **安装三个 MCP 工具**：
   - `aoci`：GitHub Releases 单二进制 → `~/bin/aoci`（下载经 SHA256SUMS 校验）；
   - `mnemosyne`：pipx 安装 PyPI 包 `mnemosyne-memory[all]`（pypi.org 不可达时自动回退阿里云/腾讯镜像）；
   - `codegraph`：npm 包 `@colbymchenry/codegraph`，无需预装，npx 按需拉起（脚本仅预热缓存）；
3. **生成 `<工作区>/.trae/mcp.json`**：读取 [trae_mcp_config.json](trae_mcp_config.json) 模板，把 `__MNEMOSYNE_BIN__` / `__AOCI_BIN__` 占位符替换为本机二进制绝对路径（已有 mcp.json 时先备份为 `mcp.json.bak.<时间戳>`）；
4. **AGENTS.md + AOCI 工作区初始化**：先从 [AGENTS.MD.TEMPLATE](AGENTS.MD.TEMPLATE) 部署工作区级 `AGENTS.md`（缺失时），再 `aoci init`（缺 `aoci.txt` 骨架时）+ `aoci scan`（缺基线时）。init 追加的 aoci 运行时合同区块（百行级）自动收拢到独立 `AOCI.md`，主 `AGENTS.md` 仅留精简指引（会话合同由 `aoci_rules` 实时签发，静态文档本不作合同）；并生成/补齐工作区 `.gitignore`（OS 杂项 + AOCI 正式资产白名单 + 工具数据目录，已有则只追加缺失规则）；
5. **codegraph 索引**：工作区根必建（MCP server 的 cwd 在根，无索引进静默态），另为各含 `.git` 的子仓库建图（排除 `node_modules` 与工具包自身）。

> 第 3 与第 4 步之间还有一步**工具包隐藏化**：工具包位于工作区内且名为 `agents-envs` 时自动改名为 `.agents-envs`，同时向 `.gitignore` 加忽略规则、向 aoci 声明 `exclude-toolkit` 排除规则（aoci 不读工作区 .gitignore，基线排除须走其自有 scope 规则）——保证工具包文件既不进你的 git 提交，也不进 AOCI 认知基线。

## 搭建产物（出现在你的工作区）

| 路径 | 说明 |
| --- | --- |
| `.trae/mcp.json` | 三个 MCP 服务的注册配置（IDE 变量 `${workspaceFolder}` 等由 Trae 运行时解析） |
| `aoci.txt` + `.aoci/` | AOCI 仓库认知索引与字节级基线（基线跨平台要求 LF，见 `.gitattributes`） |
| `AGENTS.md` | 工作区级 Agent 约束：模板部署的工作流与 MCP 工具约束 + 尾部 AOCI 精简指引（已存在则一律不覆盖） |
| `AOCI.md` | aoci init 追加的运行时合同区块存档（收拢自 AGENTS.md，可提交版本化；会话合同以 `aoci_rules` 实时签发为准） |
| `.gitignore` | OS 杂项（`.DS_Store`/`Thumbs.db`）+ AOCI 正式资产白名单（`aoci.txt` 等 3 个）+ 工具数据目录（`.codegraph/`、`.mnemosyne/`、`.trae/mcp.json`、`.aoci/`、`.agents-envs/`）忽略 |
| `.agents-envs/` | 工具包自身（无参运行时自动由 `agents-envs/` 重命名而来；自身是 git 仓库，`git pull` 随时更新环境） |
| `.codegraph/` | 代码图谱数据库（自带 gitignore，建议整体提交或忽略均可） |
| `.mnemosyne/` | 记忆库数据目录（mnemosyne 服务首次运行时创建，bank 名 = 工作区目录名） |

## 工具包内容

| 文件 | 用途 |
| --- | --- |
| `bootstrap.sh` | 一键搭建主入口（macOS / Linux） |
| `bootstrap.ps1` | 一键搭建主入口（Windows，与 sh 版逻辑对齐；**未在真实 Windows 实测**） |
| `trae_mcp_config.json` | mcp.json 模板（占位符版本，勿直接当配置用） |
| `aoci.sh` | 单独执行 AOCI init / scan + aoci 区块收拢（bootstrap 已内置，供手动补跑） |
| `code-graph.sh` | 单独执行 codegraph 索引（同上） |
| `AGENTS.MD.TEMPLATE` | 工作区 AGENTS.md 通用模板（工作流分级 + 三类 MCP 工具约束；bootstrap 在工作区缺失时部署，AOCI init 再向其追加 aoci 区块） |
| `.gitattributes` | `* text=auto eol=lf`，保证 AOCI 字节级基线跨平台一致 |

## 环境变量（均可选）

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `AOCI_VERSION` | `v0.1.0-rc14` | aoci 发布标签。rc 为预发布，GitHub latest API 不含预发布，故显式固定 |
| `MNEMOSYNE_EXTRAS` | `all` | pip extras；Windows 上若 `llama-cpp` 依赖装不上可设为 `mcp` 瘦身 |
| `PIP_INDEX_URL` | 未设 | 自定义 pip/pipx 索引源；未设置时按 [用户值 →] 阿里云 → 腾讯 → 默认 PyPI 顺序回退 |
| `CODEGRAPH_SKIP_WARMUP` | 未设 | 设为 `1` 跳过 codegraph npm 缓存预热 |
| `GITHUB_API` / `GITHUB_DL` | github.com | GitHub 基址覆盖（代理/镜像场景） |

## 常见问题

- **pypi.org 连不上**：脚本内置阿里云 / 腾讯镜像回退链，通常无需干预；也可显式 `PIP_INDEX_URL=<你的镜像>` 后重跑。
- **重跑会怎样**：所有步骤幂等——工具已装则跳过、mcp.json 内容一致则不写、工具包已叫 `.agents-envs` 则不再重命名、`AGENTS.md` 已存在则不覆盖、aoci 区块已收拢则不再处理、`.gitignore` 只追加缺失规则、aoci 排除规则已存在则跳过、`aoci.txt`/基线已存在则跳过 init/scan、`.codegraph` 已存在则跳过该仓库。
- **怎么更新到新版工具包**：`cd <工作区>/.agents-envs && git pull && bash bootstrap.sh`（重跑幂等，只增量生效）。
- **重建 AOCI 基线**：`aoci --repo <工作区> scan --force`。
- **PATH 警告**：`~/bin`、`~/.local/bin` 不在 PATH 只影响终端直呼 `aoci` / `mnemosyne`，MCP 配置写的是绝对路径，不受影响。
- **已有 `.trae/mcp.json`**：覆盖前自动备份为 `mcp.json.bak.<时间戳>`。

## 已知限制

- `bootstrap.ps1` 未在真实 Windows 环境实测，遇到问题请对照 `bootstrap.sh` 排查；
- AOCI 预发布版本需显式指定 `AOCI_VERSION`（latest API 不含 rc）；
- `mnemosyne-memory[all]` 含本地推理依赖（llama-cpp 等），安装体积较大，对网络与编译环境有要求。
