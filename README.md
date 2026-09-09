# Scripts Repository

个人常用自动化与一键安装脚本集合。

---

## 快速使用 (One-Line Run)

无需保存文件到本地，在终端直接拉取并运行。

> **提示**：请将命令中的 `<script_name.sh>` 替换为实际的文件名（例如 `install.sh`）。

### 1. 国内服务器加速（推荐）

通过专用反向代理节点加速拉取：

* **使用 curl：**
  ```bash
  bash -c "$(curl -fsSL https://gitpy.223327.xyz/https://raw.githubusercontent.com/Colzry/scripts/main/<script_name.sh>)"

- **使用 wget：**

  ```bash
  bash -c "$(wget -qO- https://gitpy.223327.xyz/https://raw.githubusercontent.com/Colzry/scripts/main/<script_name.sh>)"
  ```

### 2. 国际网络 / 海外服务器 (GitHub 原生)

海外机房或拥有直连网络的环境：

- **使用 curl：**

  ```bash
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/Colzry/scripts/main/<script_name.sh>)"
  ```

- **使用 wget：**

  ```bash
  bash -c "$(wget -qO- https://raw.githubusercontent.com/Colzry/scripts/main/<script_name.sh>)"
  ```

## 下载到本地使用 (Download to Local)

如需审计代码、保留文件或多次运行：

```bash
# 1. 下载脚本（以加速节点为例）
curl -fsSL -O https://gitpy.223327.xyz/https://raw.githubusercontent.com/Colzry/scripts/main/<script_name.sh>

# 2. 赋予执行权限
chmod +x <script_name.sh>

# 3. 运行
./<script_name.sh>
```

## 完整仓库克隆 (Git Clone)

```bash
# 国内加速克隆
git clone https://gitpy.223327.xyz/https://github.com/Colzry/scripts.git

# 原生克隆
git clonehttps://github.com/Colzry/scripts.git
```