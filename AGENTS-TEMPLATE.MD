# AGENTS-TEMPLATE: Codegraph 图索引约束模板

> 复制本文件内容到你的项目的 `AGENTS.md` 或等效 Agent 约束文件中，将 `<WORKSPACE>` 替换为实际工作区路径。

---

## Codegraph MCP 快速上手

工作区 `.trae/mcp.json` 启动**单个** `codegraph` MCP server（`@colbymchenry/codegraph`），**首次接触工程或改动前必优先使用**：

| 意图 | MCP 工具 | 关键参数 | 说明 |
|------|----------|----------|------|
| 架构 / 符号 / 调用链 / 源码（统一入口） | `codegraph_explore` | `query` + `projectPath`? | 默认唯一暴露的工具。返回相关符号逐字源码（带行号，同 Read）+ 调用路径 + 影响摘要 |

### MCP 配置

```json
{
  "mcpServers": {
    "codegraph": {
      "command": "npx",
      "args": ["-y", "@colbymchenry/codegraph", "serve", "--mcp"],
      "cwd": "${workspaceFolder}",
      "env": {
        "CODEGRAPH_MCP_TOOLS": "explore,search,callers,callees,impact,node,files,status"
      }
    }
  }
}
```

server 通过 `rootUri`（= 工作区根）启动。**不再按子项目拆分多个 server**--所有子项目通过同一 server 的 `projectPath` 参数查询。

### 工具面：全部 8 个工具启用

`@colbymchenry/codegraph` 的 MCP server 上游默认只暴露 `codegraph_explore`。上方配置已通过 `CODEGRAPH_MCP_TOOLS` 启用全部 8 个工具（`codegraph_explore` / `codegraph_search` / `codegraph_callers` / `codegraph_callees` / `codegraph_impact` / `codegraph_node` / `codegraph_status` / `codegraph_files`）。逗号分隔，短名等价（`node` = `codegraph_node`）。

### 使用规则

1. **先调 `codegraph_explore`**：传入用户任务原文（`query` 参数），完整句子比关键词路由更准
2. **返回源码即读即用**：源码是当下从磁盘重读的，逐字、带行号--视同已执行过 Read，**不要再 Read 同一文件**
3. **跨项目查询传 `projectPath`**：查另一项目（须已 `codegraph init`）传其相对路径；不传则查工作区根索引
4. **一两次通常足够**：不够再追加 `codegraph_explore`，不要退回 grep / Read 循环

### 索引生命周期

| 阶段 | 命令 | 说明 |
|------|------|------|
| 初始索引 | `codegraph init [path]` | 创建 `.codegraph/` + 全量建图（一步完成） |
| 自动同步 | 文件监听（默认开启） | 文件变更即自动同步，索引不会过期，无需手动重跑 |
| 手动重建 | `codegraph index [path]` | 从零全量重建（仅索引损坏 / 大范围重构后异常时用） |
| 增量同步 | `codegraph sync [path]` | 同步自上次索引以来的变更 |
| 诊断 | `codegraph status [path]` | 人类可读就绪状态 + 文件 / 节点 / 边统计 |

> 自动同步刷新磁盘索引且 MCP server 实时感知，**无需重启 MCP server**。这取代了旧的手动 `codegraph index` + 重启 MCP 流程。

### 收尾重新索引

与自更新协议同步执行。改动后**通常无需手动操作**--文件监听已自动同步。仅当索引损坏或大范围重构后结果异常时手动重建：

| 改动类型 | 是否手动索引 | 说明 |
|----------|----------|------|
| 单文件内函数体 / 逻辑修改 | 否 | 文件监听自动处理 |
| 新增 / 删除 / 重命名文件、签名变更、跨文件依赖变化 | 否 | 文件监听自动处理 |
| 索引损坏 / 结果异常 | 是 | `codegraph index <path>` 全量重建 |
| 仅文档 / 配置 / 注释变更 | 否 | - |

**仅重建受影响项目**，不要全量重索引所有项目。

### 未索引项目的行为

MCP server 启动时若 cwd 项目无 `.codegraph/`，**自动进入静默态**：不列出任何工具，只提示 agent 用常规工具 / 让用户跑 `codegraph init`。不会报错刷屏。

### 快速初始化（新项目）

```bash
# 1. 安装 codegraph CLI（任选其一）
npm i -g @colbymchenry/codegraph
# 或零安装运行：npx -y @colbymchenry/codegraph

# 2. 索引所有子项目（每个含 .git 的仓库各 init 一次）
bash .codegraph-command/index.sh

# 3. 部署 MCP 配置到 Trae
cp .codegraph-command/trae_mcp_config.json .trae/mcp.json
```
