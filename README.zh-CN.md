# DigUp 中文分支

[English / 上游说明](README.md) · [本分支仓库](https://github.com/yuezheng2006/DigUp)

DigUp 是本地文件搜索工具。描述记得的内容，即可查找图片、截图、PDF、文档、音视频片段和代码。索引与搜索在本机进行，首次使用需要下载模型。

本 fork 增加**简体中文界面**，保留英文。包括 macOS 的首次引导、搜索窗口、快捷搜索面板、设置、菜单、下载和索引提示，以及 Windows/Linux 的网页界面、托盘菜单和索引状态。中文系统自动使用简体中文；英文系统使用英文；不支持的语言回退英文。语言变更后需重启应用。繁体中文系统目前也显示简体中文，未提供繁体翻译。

代码搜索仍使用 `code:` 前缀，例如 `code: 保存设置的位置`。文件名、文件内容、路径、索引数据和内部协议不会被翻译。命令行输出、底层错误和第三方组件的文案可能仍为英文。

## 在 Mac 上构建

需要 macOS 14 或更新版本、Xcode、Swift 6.2 或更新版本，以及 git、CMake；具体依赖见英文 README。

```sh
git clone --branch feat/chinese-localization https://github.com/yuezheng2006/DigUp.git
cd DigUp
./build.sh
open build.noindex/DigUp.app
```

构建脚本会下载并编译固定版本的 llama.cpp。首次运行应用后，按引导下载模型并选择搜索目录。构建产物默认仅本地签名，不是经过 Apple 公证的发行安装包。

macOS 可在“系统设置 → 通用 → 语言与地区 → 应用程序”中为 DigUp 指定简体中文或英文。开发时也可仅对一次启动指定语言：

```sh
build.noindex/DigUp.app/Contents/MacOS/DigUp -AppleLanguages '(zh-Hans)'
```

Windows/Linux 构建方法沿用英文 README 和 `scripts/package-*.sh`。本次在 Mac 上验证 Swift 应用与 Rust 测试；未进行 Windows/Linux 真机安装测试。

## 更新来源

此分支暂时采用手动更新。“检查更新”会打开 [本 fork 的发布页](https://github.com/yuezheng2006/DigUp/releases)，不会自动安装上游版本。发布独立签名的更新包之前，不应重新启用自动更新。所有中文开发提交和 PR 都留在此 fork。

## 搜索能力的范围

本次修改提供界面本地化，没有更换模型、修改搜索算法或重建现有索引。原模型支持多语言语义搜索；中文检索质量仍取决于原模型。上游对无空格中文的关键词分词限制仍存在，本分支不宣称已经解决。此改动未运行模型语义质量评测。

## 验证与维护

```sh
scripts/check-localization.sh
swift test
LANGUAGE=en_US cargo test --manifest-path shell/src-tauri/Cargo.toml
LANGUAGE=zh_CN cargo test --manifest-path shell/src-tauri/Cargo.toml status::tests::lines
```

`swift test` 需要先运行 `scripts/build-llama.sh`。模型向量参考测试需要模型文件，未配置时沿用原测试的跳过规则。

Mac 文案位于 `Sources/DigUpApp/Resources/{en,zh-Hans}.lproj/Localizable.strings`，系统权限提示位于 `Resources/zh-Hans.lproj/InfoPlist.strings`。网页文案位于 `shell/ui/i18n.js`，原生托盘文案位于 Rust 的 `i18n.rs`、`main.rs` 和 `status.rs`。动态值使用 `{0}`、`{1}` 等占位符，翻译可调换顺序，但应保留所有占位符。
