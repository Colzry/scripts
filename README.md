# Scripts Repository

个人常用自动化与一键安装脚本集合。

所有脚本都通过**统一入口 `main.sh`** 调用：只需要记住一条命令，入口会以菜单形式
列出仓库内的全部管理脚本，选择编号即可运行。**不需要为每个脚本单独记录下载链接。**

---

## 一键使用（统一入口）

### 1. 国内服务器加速（推荐）

通过专用反向代理节点加速拉取入口脚本：

- **使用 curl：**

  ```bash
  bash -c "$(curl -fsSL https://gitpy.223327.xyz/https://raw.githubusercontent.com/Colzry/scripts/main/main.sh)"
  ```

- **使用 wget：**

  ```bash
  bash -c "$(wget -qO- https://gitpy.223327.xyz/https://raw.githubusercontent.com/Colzry/scripts/main/main.sh)"
  ```

### 2. 国际网络 / 海外服务器（GitHub 原生）

海外机房或拥有直连网络的环境：

- **使用 curl：**

  ```bash
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/Colzry/scripts/main/main.sh)"
  ```

- **使用 wget：**

  ```bash
  bash -c "$(wget -qO- https://raw.githubusercontent.com/Colzry/scripts/main/main.sh)"
  ```

运行后会看到如下菜单，输入编号即可启动对应脚本，输入 `0` 返回/退出：

```text
==========================================
   Colzry/scripts 脚本集合统一入口
==========================================
 当前下载源: 加速节点 (gitpy.223327.xyz)
 脚本来源:   在线拉取 (缓存目录: /root/.cache/scripts-repo)
------------------------------------------
 1. Aria2 & AriaNg 管理
    安装/配置后端、做种与限速、BT Trackers、吸血 Peer 防火墙、任务迁移、日志排查、清理工具箱
 2. FileBrowser Quantum 管理
    ...
------------------------------------------
 0. 退出
 r. 强制重新下载脚本 (刷新缓存)
 s. 切换下载源
 m. 手动指定脚本文件名运行
==========================================
请输入操作编号 [0-5 默认: 0]:
```

---

## 可用脚本清单

| 编号 | 脚本文件 | 功能简介 |
| :--: | :-- | :-- |
| 1 | `aria2_manager.sh` | **Aria2 & AriaNg 管理**：安装/配置后端、并发与限速、BT 做种策略、Trackers 更新与定时任务、吸血 Peer 防火墙、任务迁移/转移、日志排查、小文件清理工具箱 |
| 2 | `filebrowser_manager.sh` | **FileBrowser Quantum 管理**：安装/更新、全局设置与源目录增删改、账号管理、停用/启用、状态查看、卸载 |
| 3 | `frp_manager.sh` | **FRP 内网穿透管理**：frps/frpc 安装更新、多实例配置管理、服务启停看板、Acme.sh 证书申请与部署、完整卸载 |
| 4 | `rathole_manager.sh` | **Rathole 内网穿透管理**：服务端/客户端安装更新、配置与实例管理、Acme.sh 证书与续期 Hook、完整卸载 |
| 5 | `webdav_manager.sh` | **WebDAV 文件服务管理**：安装/更新、全局设置与账号增删改、停用/启用、状态查看、卸载 |

> 所有管理脚本都会自动识别 **root（系统级服务）** 与 **普通用户（用户级服务）**，按当前身份选择对应的 systemd 单元路径，无需手动区分。

---

## 直接启动指定脚本

如果不想经过菜单，也可以在启动入口时直接指定目标脚本。

### 方式一：环境变量 `SCRIPT_ID`（推荐，编号 / 文件名 / 文件名关键字均可）

```bash
# 按菜单编号
SCRIPT_ID=1 bash -c "$(curl -fsSL https://gitpy.223327.xyz/https://raw.githubusercontent.com/Colzry/scripts/main/main.sh)"

# 按文件名关键字
SCRIPT_ID=aria2 bash -c "$(curl -fsSL https://gitpy.223327.xyz/https://raw.githubusercontent.com/Colzry/scripts/main/main.sh)"

# 按完整文件名
SCRIPT_ID=webdav_manager.sh bash -c "$(curl -fsSL https://gitpy.223327.xyz/https://raw.githubusercontent.com/Colzry/scripts/main/main.sh)"
```

### 方式二：把目标编号作为位置参数传入

```bash
bash -c "$(curl -fsSL https://gitpy.223327.xyz/https://raw.githubusercontent.com/Colzry/scripts/main/main.sh)" - 1
```

### 方式三：已经克隆/下载到本地

```bash
./main.sh          # 打开交互式菜单
./main.sh 3        # 直接运行第 3 个脚本 (FRP 管理)
./main.sh frp      # 按文件名关键字匹配并运行
```

---

## 入口脚本的进阶选项

菜单中除了脚本编号，还提供以下操作：

| 选项 | 说明 |
| :--: | :-- |
| `0` | 退出入口（输入为空时默认执行本项） |
| `r` | 强制重新下载脚本，刷新本地缓存（下次启动时生效） |
| `s` | 在「国内加速节点」与「GitHub 原生」之间切换下载源 |
| `m` | 手动输入仓库中的任意脚本文件名运行（例如 `aria2_manager.sh`） |

**缓存机制**

- 拉取到的脚本会缓存在 `${XDG_CACHE_HOME:-$HOME/.cache}/scripts-repo/`，本次会话内同一脚本不会重复下载。
- 缓存有效期 24 小时；过期后会尝试联网刷新，**刷新失败时自动回退到已缓存的旧版本**，确保离线/网络受限环境仍可运行。
- 下载优先使用当前选择的下载源，失败后会自动尝试另一个来源；同时会校验文件是否为合法的 shell 脚本，避免把代理的错误页面当成脚本执行。

**本地优先**

当 `main.sh` 与各脚本位于同一目录（例如已 `git clone`）时，入口会**直接运行同目录下的脚本文件**，不再联网；通过管道方式（`curl | bash`）运行时则始终使用缓存/在线拉取。

---

## 下载到本地使用（可选）

如需审计代码、保留文件或反复运行，只下载入口脚本即可：

```bash
# 1. 下载统一入口（以加速节点为例）
curl -fsSL -O https://gitpy.223327.xyz/https://raw.githubusercontent.com/Colzry/scripts/main/main.sh

# 2. 赋予执行权限
chmod +x main.sh

# 3. 运行
./main.sh
```

> 入口会在首次使用时把选中的脚本自动拉取到本地缓存，因此无需手动下载各个管理脚本。

---

## 完整仓库克隆（Git Clone）

```bash
# 国内加速克隆
git clone https://gitpy.223327.xyz/https://github.com/Colzry/scripts.git

# 原生克隆
git clone https://github.com/Colzry/scripts.git
```

克隆后直接执行 `./main.sh` 即可，入口会优先使用仓库中的本地脚本。

---

## 维护说明

- **新增脚本**：把脚本放入仓库，并在 `main.sh` 的 `SCRIPT_ENTRIES` 注册表中追加一行
  `文件名|菜单标题|功能简介` 即可自动出现在菜单中，无需再额外维护下载链接与文档。
- **换行符**：仓库通过 `.gitattributes` 强制所有 `*.sh` 使用 LF 换行，请在 Windows 下注意编辑器设置。
- **安全提示**：一键命令会直接执行远程仓库中的代码，请在信任本仓库内容的前提下使用；对安全敏感的环境建议先「下载到本地」审阅后再运行。
