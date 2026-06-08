# CLAUDE.md — EnvCue 项目宪法

> Claude Code 每个会话都会读取本文件。这里只放**每次都必须遵守的常驻约束**,细节见 `docs/`。
> 设计文档是唯一事实来源(source of truth):**代码服从文档,不服从记忆、不服从直觉。**
>
> EnvCue 比一般自用小工具重在三处真实风险,范式据此定点加重(见 `docs/workflow.md`):
> ① 它往**用户自己的 `~/.zshrc`** 注入 shim;② 两个精巧的**安全机制**(generation 仅内容指纹、密钥经 stdout 管道)靠自验测不出对抗性漏洞;③ 有 **Liquid Glass 视觉门**。

## 你的角色

你是本项目的 **generator**。按 `docs/tasks.md` 顺序实现 T0–T6,自底向上(纯逻辑先行、系统副作用后置)。每个任务的收尾(强制):

1. 自测:`swift build` / `swift test` / 该任务 DoD 指定的脚本或集成验证。
2. 对照 `docs/tasks.md` 该任务的 DoD 逐条自验,并对照下方**六条不变量**自查。
3. **若该任务命中安全门(G1/G2/G3),先过门再 commit**(见 `docs/workflow.md` §3,阻塞式)。
4. 过了就 `git commit` 并 push。**Commit messages must be in English**,形如 `Tn: <short summary>`(如 `T1: add deterministic evaluate()`),并带 `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` 尾注。
5. 在下方"当前进度"清单勾选 Tn,直接进入下一个任务。

不一口气连做多个任务(一次一个,做完收尾再进下一个)。不命中安全门的任务**不需要等评审**——自验 DoD 通过即可推进;**命中安全门的任务必须先过阻塞评审**。

详细流程见 `docs/workflow.md`。

## 红线(违反即返工,不可协商)

### A. 范围红线
v1 仅 **macOS Tahoe(26)+ / 仅 zsh / Swift**;层模型 `base + scene`,**scene 互斥**;密钥后端 `keychain`(默认)/ `env`(兜底,v1 压到最小)。
out-of-scope 一律**不实现**:多 scene 叠加、mise/direnv 可视化、常驻 prompt 段、**任何 PATH 操作**(永久委托 mise·direnv)、版本切换、GUI 应用注入、bash/fish、远程同步/团队。
(数据模型须为这些**预留**:`unset` 已入模型;scene 互斥约束写在调用/求值层,未来放开叠加只改叠加策略,模型不动。)

### B. 六条不变量(贯穿所有任务,review 必盯 — 即 `docs/tasks.md` 末尾的关键不变量)
1. **求值只在 `EnvCueCore` 一处**;GUI 与 CLI 共用同一条 apply 路径(NFR-6)。
2. **任何盘上文件无明文密钥**;密钥不进 argv、不进 history(NFR-1)。快照里 secret 只能是 `$(envcue keychain-get --account '<account>')`,真值经 stdout 管道进 shell。
3. **零 PATH 操作**(NFR-4)。快照与 hook 都不得产生任何 PATH 改写。
4. **precmd 每 prompt 不 fork**:用 zsh builtin `read < file` 判断 generation,**禁 `$(cat ...)`**;只有 generation 变了才 source(才取密钥)。
5. **generation = 仅 ResolvedEnv 内容指纹**(不含 active scene 名),撑起"仅本终端实际受影响才提示"的诚实(NFR-2)。
6. **原子写以 generation 为提交点**:先 fsync+rename 快照,**最后**才 rename generation;绝无指向半写快照的新 gen 被读到(NFR-5)。

> 其中**第 2 条(无明文密钥)是全设计的安全地基**,安全门 G1/G2/G3 即围绕它与第 4/5/6 条对抗性核验。

## 核心约定(实现时反复用到)

- **机密与配置分家**:机密进 Keychain(`service = "dev.mars.envcue"`,`account = "{layer}/{VAR}"`),配置进 `~/.config/envcue/`(XDG,TOML 明文可分享)。层文件的 `secret` 条目**只存 account 引用,绝不存明文**。详见 `docs/design.md` §2–3。
- **状态目录是生成物,勿手改**:`state/{snapshot.zsh, generation, manifest.json}`。
- **求值确定性**:`evaluate(base, scene?)` 是纯函数,不读当前进程 env,每项携带来源层,相同输入相同输出。详见 `docs/design.md` §4。
- **密钥永不取值做 diff**:secret 的"changed"判定基于 account 引用变化,不解密;UI 显引用不显明文、不显 last-4。
- **shim 幂等**:以 `# >>> envcue >>>` / `# <<< envcue <<<` 成对锚点做幂等注入/卸载,不破坏用户既有 `.zshrc`(FR-6)。

## 工作纪律

- **一文件一 owner**:每个任务"主要负责的模块"见 `docs/tasks.md` 阶段表;尽量不并发写同一文件。
- **不擅改设计文档**:开发期 `docs/*.md` 冻结。实现中发现 spec/design 与现实冲突 → 写 `docs/PROPOSAL-NNN-<topic>.md`(说明冲突 + 临时裁断 + 选项),交 maintainer 拍板,**不得单方面改文档、也不硬干**。详见 `docs/workflow.md` §5。
- **DoD 即验收点**:动手前先复述该任务的 DoD,实现后逐条对照。
- **错误可读**:所有面向用户的错误是人类可读消息,不是 panic backtrace;`Err` 的 Display **禁止**包含 key。
- **质量门**:提交前 `swift build`、`swift test` 应通过。
- **任务即提交**:每个任务一个独立 commit,作为该任务的评审快照;未 commit 不算任务完成。
- **只提交本任务的改动**:commit 前先 `git status`,**只 `git add` 属于当前任务 Tn 的文件**,不用 `git add -A` / `git add .`。发现工作区有不属于本任务的改动 → **停下来问 maintainer**,不擅自提交或还原。

## 里程碑闸门

- **M1 = T1+T2+T3+T4**:CLI 全链路打通,**可日常自用**(proposal §6 的最小验证形态)。M1 后 maintainer 自用数周再决定是否产品化。
- **M2 = +T5**:菜单栏可见性 + Liquid Glass 体验(进 T5 前先过**视觉门**,见 `docs/workflow.md` §4)。
- **M3 = +T6**:Homebrew 分发,达决策闸门评估条件。

> **三个安全门 G1/G2/G3 全部通过,是迈过 M1 的前置条件**(阻塞式)。

## 关键文件导航

| 路径 | 作用 |
|---|---|
| `docs/proposal.md` | 动机、范围、已锁定决策 |
| `docs/spec.md` | WHAT:数据模型、求值语义、FR/NFR、8 条验收 |
| `docs/design.md` | HOW:5 模块、generation 触发器、密钥 stdout 握手、文件契约、Liquid Glass UI |
| `docs/tasks.md` | T0–T6 拆解 + 每任务 DoD + 关键不变量 |
| `docs/workflow.md` | 开发流程、安全门/视觉门、评审 prompt、里程碑 |
| `docs/PROPOSAL-NNN-*.md` | spec 与现实冲突时的提案(按需新建) |

## 当前进度

<!-- 每完成一个任务更新这里,方便跨会话快速定位。命中安全门的任务在勾选时注明门已过。 -->
- [x] T0 工程骨架(Swift Package 5 target + 双模式入口)
- [x] T1 EnvCueCore(模型 + 求值 + diff + 序列化 + generation)  ← **安全门 G1 已过**(T1.5/T1.6)
- [x] T2 EnvCueKeychain(generic password 读写 + keychain-get stdout)  ← **安全门 G2 已过**(T2+T3)
- [x] T3 EnvCueShell(原子写 + shim 幂等 + precmd hook 模板)  ← **安全门 G2 已过**(T2+T3)
- [x] T4 EnvCueCLI(子命令装配,走单写者 apply 路径)  ← **安全门 G3 已过**(端到端无泄露;含 PROPOSAL-001 字段校验 / PROPOSAL-002 指纹编码落地)→ **M1 达成**(G1/G2/G3 全过)
- [x] T5 EnvCueApp(MenuBarExtra + inline diff + Liquid Glass,走单写者 apply 路径)  ← **视觉门已过** + **真机行为回归已过**(两终端收敛/提示一次/无明文/零 PATH/ps 抓不到);App 图标改静态蓝紫图(见 PROPOSAL-003,打包进 `.app` 随 T6)→ **M2 达成**
- [ ] T6 集成与分发(真机回归 + Homebrew)→ **M3**
  - [ ] M3 收尾:README 转双语 —— 现有中文 `README.md` 迁到 `README.zh-CN.md`,新写**英文** `README.md`(GitHub 默认展示),两份顶部互加语言切换链接;同步补上可用的 `brew install csthink/tap/envcue` 安装段(tap 仓 `csthink/homebrew-tap`)
