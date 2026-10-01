# SunMouse

SunMouse 是一款原生 macOS 鼠标工具，可按设备调整指针与滚轮，并为侧键和鼠标手势配置快捷操作。

## 主要功能

- **按设备调整指针**：设置指针速度、加速度或关闭加速度，并可恢复设备原值。
- **自定义滚轮体验**：分别配置滚动方向、速度、平滑曲线、响应、加速度和惯性；可用修饰键切换横向、缩放、快速或精细滚动。
- **映射侧键操作**：为单击、多击、长按、拖动和滚轮触发配置快捷键、系统动作、AppleScript 或导航操作，也支持组合按键触发。
- **配置鼠标手势**：使用右键方向轨迹、按住按钮滚轮或鼠标点击触发动作，并按应用设置规则范围。
- **适配多只鼠标**：每只鼠标可使用独立的指针和滚轮设置，按键与轨迹状态彼此隔离；支持配置导入和导出。

## 下载与安装

从 [GitHub Releases](https://github.com/AssassinJY/SunMouse/releases) 下载 DMG，打开后将 SunMouse 拖入 Applications。支持 macOS 26 及以上的 Apple Silicon 和 Intel Mac；首次启动需授权辅助功能。

## 首次打开

如果提示「SunMouse 已损坏，无法打开」，在终端执行以下命令后重新打开：

```bash
xattr -dr com.apple.quarantine /Applications/SunMouse.app
```

## 参考项目

SunMouse 将以下项目的代码基础与功能设计整合到一款应用中：

- [LinearMouse](https://github.com/linearmouse/linearmouse)：作为代码基础，保留并改编设备管理、指针控制、事件处理、滚动和设置基础设施。
- [Mac Mouse Fix](https://github.com/noah-nuebling/mac-mouse-fix)：参考侧键与修饰键交互；离散滚轮平滑和连续手势处理采用其相关实现。
- [MacGesture](https://github.com/MacGesture/MacGesture)：参考方向手势识别和按应用过滤规则的行为。
