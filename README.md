# EnvCue

> macOS 菜单栏 shell 环境**场景切换器** —— 在 personal / work 等全局场景间一键切换,菜单栏常驻显示当前在哪个场景,切换后对已开终端给出**诚实可见**的生效提示。

**状态:开发中**(设计已定稿,实现进行中;里程碑见下方[路线图](#路线图))。

---

## 为什么

你可能也把 alias、插件、各 SDK 配置、以及多套需要切换的环境(个人/公司不同的 LLM API_KEY、不同 JDK……)全塞进一份 `~/.zshrc`。于是:

1. **不知道此刻用的是哪套** —— 得 `echo $API_KEY` 才能确认。
2. **切换全靠手改 / 靠变量命名约定** —— 不直观、易错。
3. **密钥明文躺在 dotfile 里** —— 有泄露风险。

EnvCue 解决的就是这三点:**可见性**(菜单栏随时显示当前场景)、**安全**(密钥进 Keychain,明文不落盘)、**诚实**(任何切换都给明确可见的生效路径,绝不假装热加载成功)。

## 定位:整合 + 可见性 + 诚实,不造轮子

EnvCue 坐在 [mise](https://mise.jdx.dev/) / [direnv](https://direnv.net/) 之上,只做整个品类都空着的两件事 —— **可见性** 与 **诚实**。它**永不碰 PATH**:

| 关注点 | 谁来做 |
|---|---|
| PATH / 版本 / 按目录加载 | **委托 mise·direnv**,EnvCue 永不写 PATH |
| 密钥存储 | macOS **Keychain**(工具自身不持有、不落盘明文) |
| 场景定义 → 求值 → 写快照 → shell 读取生效 → 诚实提示 | **EnvCue** |

## 核心设计原则

- **机密与配置分家**:API key 进 Keychain(只存引用,source 时实时取);普通环境变量进 `~/.config/envcue/`(TOML 明文、可分享、手改友好)。**任何盘上文件都没有明文密钥。**
- **确定性、可追溯的求值**:任何变量的最终值都能一眼追溯来自哪一层(`base` 还是当前 `scene`),没有隐式优先级。
- **承认物理约束**:运行中的 shell 无法被外部改写环境。EnvCue 只控制 (a) 下一个 shell 启动读到什么,(b) 已开终端在下一个 prompt 重读 —— 并且**只在本终端真受影响时,打印一次性单行提示**,从不谎报。

## 它如何工作(概览)

```
场景定义 (base + scene, TOML)
        │  求值(纯函数,base < scene 叠加)
        ▼
   原子写快照 snapshot.zsh  +  generation 指纹
        │
        ├─ 新 shell 启动 → .zshrc shim 自动 source
        └─ 已开终端下个 prompt → precmd hook 检测 generation
                                 变了才重读(才取密钥)→ 打印一次诚实提示
```

- 密钥在快照里只是 `$(envcue keychain-get ...)` 引用,真值经 stdout 管道进 shell —— **不进 argv、不进 history**。
- `generation` 只对**环境内容**取指纹(不含场景名):两个场景若解析出的环境完全相同,切换**不会**打提示(因为这个终端的环境确实没变)。

## 范围(v1)

**做:** 仅 macOS(Tahoe 26+)/ 仅 zsh;`base + scene` 层模型(scene 互斥,同一时刻一个);Keychain 密钥后端;切换前 diff 预览;菜单栏可见性(SwiftUI + Liquid Glass)。

**不做(明确推迟,数据模型预留):** 多 scene 自由叠加、mise/direnv 可视化管理、常驻 prompt 段、版本切换(JDK 等)、GUI 应用环境注入、bash/fish、远程同步/团队协作。**自己做按目录加载或任何 PATH 操作 —— 永久不做,委托 mise·direnv。**

## 安装

> 尚未发布。M3 完成后将提供 Homebrew 分发:
>
> ```sh
> brew install mars/tap/envcue
> ```
>
> 届时一并补上英文 `README.md` 与 `README.zh-CN.md`。

## 技术栈

Swift · SwiftUI `MenuBarExtra` · 最低 macOS Tahoe 26 · Liquid Glass(全用系统材质,不自绘)· 单二进制双模式(菜单栏 `.app` + `envcue` CLI)· macOS Keychain。

## 路线图

| 里程碑 | 内容 | 状态 |
|---|---|---|
| **M1** | CLI 全链路(求值 / 密钥 / 快照 / shim / 子命令)—— 可日常自用 | 🚧 进行中 |
| **M2** | 菜单栏可见性 + Liquid Glass 体验 | ⏳ |
| **M3** | Homebrew 分发 + 双语 README | ⏳ |

## 许可

[MIT](./LICENSE) © 2026 Mars
