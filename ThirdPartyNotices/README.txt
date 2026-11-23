渡舟 / Ferry 第三方组件说明

Ferry 自有代码采用 MIT 许可证。OpenMTP 用作架构与设备行为参考；目录批量属性读取与解析代码改编自该仓库，保留 MIT 许可。未使用其应用界面或预编译二进制。

1. github.com/ganeshrvel/go-mtpfs
版本 v1.0.4-0.20240426083057-1c3302b3c476
https://github.com/ganeshrvel/go-mtpfs
采用 BSD 许可证，全文见 go-mtpfs-BSD.txt。实际使用其 mtp 包，不挂载 FUSE 文件系统。
源码固定保存在 engine/vendor，Ferry 对 mtp 包的初始化、会话与设备选择逻辑作了本地 USB 初始化修补：核对活动配置、检查接口申请结果、激活备用设置、保留失败原因并清理未选中的句柄，以及用户允许时的 macOS 系统授权接管与对称归还；关闭会话失败不再自动 Reset。上游版本未升级，补丁说明见 engine/vendor/README.ferry.md；构建显式使用 -mod=vendor。

2. github.com/ganeshrvel/usb
版本 v0.0.0-20210103155855-14d96f5ae403
https://github.com/ganeshrvel/usb
采用 BSD 许可证，全文见 usb-BSD.txt。
源码随 engine/vendor 固定保存。Ferry 在 usb.go 中增加 GET_INTERFACE 与 USB 端口路径封装，补丁说明见 engine/vendor/README.ferry.md。

3. libusb 1.0.29
https://libusb.info/
采用 LGPL-2.1-or-later，全文见 libusb-LGPL-2.1.txt。
源码 https://github.com/libusb/libusb/releases/download/v1.0.29/libusb-1.0.29.tar.bz2
SHA-256 5977fc950f8d1395ccea9bd48c06b3f808fd3c2c961b44b0c2e6e29fc3a70a85
使用未修改的源代码，以动态库方式链接。发布构建同时提供完整源码归档。
构建命令见 scripts/prepare-deps.sh；运行时库位于 Ferry.app/Contents/Frameworks/libusb-1.0.0.dylib。
允许用户替换兼容的修改版本用于调试。替换后需重新进行本地签名：
codesign --force --sign - Ferry.app/Contents/Frameworks/libusb-1.0.0.dylib
codesign --force --sign - Ferry.app
该应用不限制为调试修改后的 LGPL 库而进行的逆向工程。

4. OpenMTP
https://github.com/ganeshrvel/openmtp
目录读取模块改编自 OpenMTP 的 ffi/kalam/native/directory/list.go、properties.go 及相关测试，采用 MIT 许可证，全文见 OpenMTP-MIT.txt。Ferry 适配为自己的 Entry 类型、上下文取消、本地化阶段提示和兼容回退，不依赖 OpenMTP 安装或 go-mtpx。
