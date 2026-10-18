# 安装与发布此分支

此分支通过
[`robinzzz1/puro` 的 Gitee 发行版](https://gitee.com/robinzzz1/puro/releases)
安装和更新预编译程序。使用者可直接运行可执行文件；Flutter SDK 镜像通过现有的
`puro config` 命令单独配置。

## macOS 安装

使用指定版本的安装脚本，安装最新发布的版本：

```bash
curl -fsSL https://gitee.com/robinzzz1/puro/releases/download/v1.5.0-ohos.6/install.sh | bash
```

将安装脚本和可执行文件同时固定到此版本：

```bash
curl -fsSL https://gitee.com/robinzzz1/puro/releases/download/v1.5.0-ohos.6/install.sh \
  | PURO_VERSION="1.5.0-ohos.6" bash
```

所选发行版包含对应平台的产物时，安装脚本支持 macOS arm64 和 x64。脚本读取 Gitee
发行版 API，跟随产物下载地址的重定向，使用 `SHA256SUMS` 校验程序，并核对程序内嵌的
版本号。所有校验通过后才运行 `install-puro --promote` 并替换原程序；已有 SDK 环境和
SDK 镜像设置保留。

`PURO_VERSION` 默认为 `latest`，同时接受带 `v` 前缀和纯版本号两种写法。
`PURO_ROOT` 默认为 `~/.puro`。设置 `PURO_REPOSITORY=owner/repo` 可使用其他 Gitee
分支仓库；设置 `PURO_RELEASES_URL` 可指定自定义的 Gitee 发行版 API 地址。
安装脚本会将此地址保存为 `puroBuildsUrl`，供后续更新使用。

PATH 更新后，重新打开终端并验证：

```bash
puro version
puro --json config list
```

现有 SDK 选择命令继续可用：

```bash
puro create harmony --ohos
puro use harmony
```

在项目目录运行 `puro use harmony` 可选择当前项目使用的环境；
运行 `puro use -g harmony` 可设置全局环境。

## Windows 安装

在 [Gitee 发行版页面](https://gitee.com/robinzzz1/puro/releases)选择包含
`puro-windows-x64.exe` 和 `SHA256SUMS` 的版本。下载这两个文件，
然后在它们所在的目录中打开 PowerShell，执行以下命令：

```powershell
$entry = Select-String -Path .\SHA256SUMS -Pattern '^[0-9a-fA-F]{64}\s+\*?puro-windows-x64\.exe$'
if (@($entry).Count -ne 1) { throw 'Expected one Windows checksum' }
$expected = ($entry.Line -split '\s+')[0]
$actual = (Get-FileHash .\puro-windows-x64.exe -Algorithm SHA256).Hash
if ($actual -ne $expected) { throw 'Puro checksum mismatch' }
.\puro-windows-x64.exe --no-install --no-update-check version --plain
.\puro-windows-x64.exe install-puro --promote
puro --json config set puroBuildsUrl https://gitee.com/api/v5/repos/robinzzz1/puro/releases
```

Windows 产物为独立可执行文件。每个发行版的说明正文会列出已提供的平台。
仅包含 macOS arm64 程序的发行版适用于该平台；Windows 和 macOS x64 使用各自对应的
原生构建产物。

## 更新 Puro

```bash
puro upgrade-puro
puro upgrade-puro 1.5.0-ohos.6
```

更新发现、通知和指定版本升级共用同一套 Gitee 发行版解析逻辑。自动更新发现会选择
包含当前平台程序及其校验信息的最高稳定版本。`master` 参数用于选择已明确发布的
`master` 开发版本。现有的 `update-puro` 别名和通过 pub 安装时的升级路径继续可用。

`puroBuildsUrl` 配置项现表示 Gitee 发行版 API 地址。原有的自定义目录式更新源应填写为
此 API 格式：

```bash
puro --json config set puroBuildsUrl https://gitee.com/api/v5/repos/robinzzz1/puro/releases
```

现有的七个 Flutter、Dart、引擎和 OHOS 镜像配置项继续负责 SDK 镜像。
此配置项负责 Puro 程序自身的发行源。

## 构建与发布

使用 Dart 3.11.5，并选择与目标操作系统和架构匹配的编译器。
本地 macOS arm64 构建命令如下：

```bash
cd puro
puro -e harmony dart pub get
mkdir -p ../dist
puro -e harmony dart compile exe bin/puro.dart \
  -o ../dist/puro-darwin-arm64 --define=puro_version=1.5.0-ohos.6
cd ../dist
shasum -a 256 puro-darwin-arm64 > SHA256SUMS
cp ../installer/install.sh .
cd ..
```

### 使用 Rosetta 构建 macOS x64 版本

在已安装 Rosetta 的 Apple Silicon Mac 上，使用 macOS x64 Dart SDK 生成 Intel Mac
程序。本地 Dart 3.11.5 x64 SDK 安装路径为
`$HOME/.cache/puro-build/dart-3.11.5-macos-x64/dart-sdk/bin/dart`：

```bash
cd puro
arch -x86_64 "$HOME/.cache/puro-build/dart-3.11.5-macos-x64/dart-sdk/bin/dart" \
  compile exe bin/puro.dart -o ../dist/puro-darwin-x64 \
  --define=puro_version=1.5.0-ohos.6
cd ..
```

统一发布时，将 `puro-darwin-arm64`、`puro-darwin-x64` 和 `puro-windows-x64.exe`
汇总到 `dist/`，并为每个程序生成校验记录。版本号通过 `--define=puro_version` 明确写入。

### 基于固定 Gitee 源码提交的原生 CI 构建

GitHub 镜像中的 `workflow_dispatch` 入口接受 `version` 和 `source_sha` 参数。
工作流从固定的 `https://gitee.com/robinzzz1/puro.git` 源仓库匿名拉取指定的 40 位提交，
校验检出的 SHA，并在日志中记录各平台构建使用的源码提交：

```bash
gh workflow run release.yml --repo payailk/puro --ref master \
  -f version=1.5.0-ohos.6 \
  -f source_sha=c2b1fd06b580ae2befefdefe923bf76a185a0a3e
```

手动运行会编译三个平台的原生程序、验证内嵌版本号并上传产物。构建任务匿名读取 Gitee
源码，通过 GitHub 产物通道上传程序。Gitee 凭证仅保存在本地发布机。
标签推送触发的工作流继续执行现有的分析、测试和自动 Gitee 发布，发布时使用
`GITEE_ACCESS_TOKEN` Actions 密钥。

版本 `1.5.0-ohos.6` 的三个平台产物已由运行 `39087060796` 成功构建，
源码提交为 `c2b1fd06b580ae2befefdefe923bf76a185a0a3e`。
将各平台产物下载到同一个发布目录：

```bash
release_dir=dist/v1.5.0-ohos.6
mkdir -p "$release_dir"
gh run download 39087060796 --repo payailk/puro --name puro-darwin-arm64 --dir "$release_dir"
gh run download 39087060796 --repo payailk/puro --name puro-darwin-x64 --dir "$release_dir"
gh run download 39087060796 --repo payailk/puro --name puro-windows-x64.exe --dir "$release_dir"
(cd "$release_dir" && shasum -a 256 puro-darwin-arm64 puro-darwin-x64 puro-windows-x64.exe > SHA256SUMS)
cp installer/install.sh "$release_dir/"
```

### 统一发布到 Gitee

提交并推送源码，在发布前创建与源码匹配的 Gitee 标签。
`v1.5.0-ohos.6` 标签固定指向下方所示的 CI 源码提交。后续文档更新使用独立提交，
确保该标签持续对应已发布程序的实际源码：

```bash
git push origin master
git tag v1.5.0-ohos.6 c2b1fd06b580ae2befefdefe923bf76a185a0a3e
git push origin v1.5.0-ohos.6
python3 installer/publish_gitee.py \
  --version 1.5.0-ohos.6 \
  --directory dist/v1.5.0-ohos.6 \
  --token-file ~/.config/puro/gitee-release-token
```

令牌文件的读取权限仅授予其所有者（`chmod 600`）。发布脚本也接受 CI 环境中的
`GITEE_ACCESS_TOKEN` 或 `GITEE_TOKEN`。使用具有目标仓库写入权限的令牌，
并将其单独保存在源码和发布产物目录之外。

发布脚本先验证校验清单和远端标签，上传期间创建预发布版本，校验已上传的产物，
全部完成后将发行版标记为稳定版本。重复执行同一命令可继续上传内容匹配的产物；
内容冲突时暂停发布。发行说明会列出包含的平台。
保留已发布的版本产物，供固定版本安装和回退使用。
`1.5.0-ohos.4`、`1.5.0-ohos.5` 和 `1.5.0-ohos.6` 继续同时提供。

现有 GitHub Actions 构建矩阵支持从 GitHub 镜像构建三个平台的原生程序，
其发布任务使用 `GITEE_ACCESS_TOKEN` Actions 密钥将产物上传到 Gitee。
向 Gitee 推送标签用于发布源码标签；在本地执行上述 Python 命令可发布程序产物。

## 本地安装脚本检查

```bash
bash -n installer/install.sh
python3 installer/test_install.py
```

这些检查使用本地模拟发行产物和独立根目录，使用者现有的 Puro 安装及 SDK 环境保留。
