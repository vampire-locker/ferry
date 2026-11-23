# Ferry MTP 本地补丁

此目录由 `go mod vendor` 从 engine/go.mod 锁定的版本生成，保留第三方 BSD 许可证。构建与检查入口显式使用 `-mod=vendor`，不能改为直接使用模块缓存，否则会绕过补丁。

本地修改位于 `github.com/ganeshrvel/go-mtpfs/mtp` 的初始化、会话、选择与日期解析逻辑，以及 `github.com/ganeshrvel/usb/usb.go` 的 GET_INTERFACE 与端口路径封装：

- 仅从设备当前活动配置选择端点，优先标准 Still Image（6/1/1）接口，保留非标准接口名称探测。
- 打开后核对活动配置，再申请接口；检查 claim 的错误，失败时释放句柄，不带着未取得的接口打开会话。
- 先用 GET_INTERFACE 读取实际 alternate setting（严格要求 1 字节响应），仅在与端点所属设置不同时调用 SET_INTERFACE，避免重复设置默认 0 导致 Android OUT 端点超时；标准接口在可选名称缺失时仍可识别，存在名称时保留上游 MTP 校验；空 pattern 时不额外读取 USB 序列号。
- 移除申请接口之后的 SetConfiguration 操作，配置变化交给下一次重新枚举，普通初始化不调用 Configure 或额外 USB reset 恢复。
- 默认 ad-hoc 本地包不携带受限制的 com.apple.vm.device-access 权限，通过一次性管理员授权引擎完成接管后永久降权；不得因静态 codesign 检查通过就附加该权限，AMFI 会在启动前拒绝。
- macOS 的 `SelectDeviceWithDriverDetach` 仅在显式允许且调用方具备正确签名/授权配置时，对标准 6/1/1 或命名 MTP 接口查询系统占用并通过 libusb 请求授权接管；默认 `SelectDevice` 不接管，未指定目标时仍在多候选设备接管前拒绝。`SelectDeviceByUSBTarget` 在打开前按总线、完整端口路径和 VID/PID 筛选唯一目标，并在 claim/接管前核验可用序列号；无匹配或不唯一时释放全部引用，不回退到其他手机。USB 地址可能因接管重新识别而变化，不用于目标标识。授权错误保留为可识别的错误链。
- 记录成功接管状态，关闭会话并释放接口后对称调用 AttachKernelDriver；失败路径也归还，移除 CloseSession 失败时的自动 Reset。libusb 接管的是整台设备，捕获/归还属于用户已授权的例外，后端可能重新识别 USB。应用用常驻串行 helper 保持连接，避免每次读取都反复接管。
- 保留候选设备打开错误及底层错误链，失败、未匹配和多设备路径释放所有未选中的句柄与引用。
- 仅在实际成功接管后、收到完整 `SessionAlreadyOpened` 响应时，关闭已有会话并重试一次；USB/同步错误不恢复，关闭失败不继续，不使用带 Reset 的 `Configure`。
- `initialize_test.go` 验证备用设置选择和有限会话恢复，`usb_target_test.go` 使用注入操作验证只打开所选手机、目标缺失/歧义/打开失败的清理与无回退，以及序列号校验；`scripts/test.sh` 显式运行 vendored MTP 包测试。
- `date.go` 提供批量属性与逐对象 ObjectInfo 共用的 ParseDateTime。无时区日期以 Mac 本地时区解析，假定手机与 Mac 时区相同；明确带 Z 或数值时差时保留原语义，不再移除 Z。支持小数秒与末尾句点，缺失日期保持零值、非法日期拒绝。`date_test.go` 覆盖东八区月末/年末、闰日、UTC、数值时差和西半球冬夏时，防止错误的 UTC 假设影响显示、筛选与下载文件时间。

依赖版本未升级。重新运行 `go mod vendor` 会覆盖本地修改，升级依赖时必须重新审查并迁移这些补丁。
