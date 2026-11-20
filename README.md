# xray-oh

Xray-core 的鸿蒙 VPN 客户端（2in1 PC / 手机 / 平板）。系统 VPN 的 TUN 直接交给 Xray 自带的 TCP/IP 协议栈，不经过 tun2socks。

## 在 DevEco Studio 里测试

1. **打开工程**：File > Open，选择本目录。
2. **签名**：File > Project Structure > Signing Configs，勾选 *Automatically generate signature*，需要登录华为账号。`bundleName` 现在是 `com.example.xrayoh`，可以先在 `AppScope/app.json5` 里改成你自己的再签名。
3. **运行**：选中设备后点 Run。
   - 默认只编了 `arm64-v8a`，真机和 Mac 上的模拟器都是 arm64。
   - 部分模拟器镜像没有 VPN 授权组件，建议用真机。
4. **连接**：在应用里粘贴一份完整的 Xray JSON 配置，点"连接"。首次连接时系统会弹出 VPN 授权。日志显示在下方。

`entry/libs/arm64-v8a/libxray.so` 已经编好，在 DevEco 里直接编译就行。只有改了 Go 代码或 Xray 源码才需要重新编译它（见下文）。

## 配置

只需要提供 `outbounds`，其余部分应用会自动补上（见 `entry/src/main/ets/service/XrayConfig.ets`）：

- 没有 `tun` 入站时，自动添加一个，tag 为 `tun-in`。
- 从 TUN 发往 53 端口的流量会交给 `dns` 出站，没有这个出站时自动添加，tag 为 `dns-out`。
- 没有 `dns` 段时，使用 `1.1.1.1` 和 `8.8.8.8`。

示例（VLESS + REALITY，`<...>` 部分换成你自己的）：

```json
{
  "log": { "loglevel": "info" },
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [{ "address": "<服务器 IP>", "port": 443,
                    "users": [{ "id": "<UUID>", "encryption": "none", "flow": "xtls-rprx-vision" }] }]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": { "serverName": "<SNI>", "fingerprint": "chrome",
                             "password": "<公钥>", "shortId": "<shortId>" }
      }
    },
    { "tag": "direct", "protocol": "freedom" }
  ]
}
```

**目前请把服务器地址写成 IP。** 写成域名的话，解析它用的是系统解析器，解析请求会进入这个 VPN 自身。

## 结构

| 位置 | 内容 |
| --- | --- |
| `golib/` | Go 写的 C ABI（`XrayStart`/`XrayStop`/`XraySetCallbacks`…），编成 `libxray.so` |
| `entry/src/main/cpp/napi_init.cpp` | NAPI 模块 `libxraybridge.so`：启动和停止放在工作线程；Xray 每开一个 socket 就排队给 JS 做 `protect(fd)` |
| `entry/src/main/ets/vpnability/` | `XrayVpnExtensionAbility`：建 VPN（`vpn-tun`，默认路由 v4+v6），启动和停止 Xray |
| `entry/src/main/ets/service/` | UI 进程这一侧的控制器、配置补全、跨进程事件 |

两个进程之间通过 CommonEvent 通信：
- 发布时只投递给本应用；
- 订阅时只接收本应用发布的事件。

扩展进程每 2 秒发一次心跳，UI 超过 10 秒收不到，就判定扩展已退出。

## 重新编译 libxray.so

```bash
bash scripts/build_libxray.sh
```

依赖以下几样：

- **鸿蒙版 Go 1.27 工具链**：放在 `~/ohos-toolchain/ohos-go-1.27.4`，可以用 `OHOS_GO` 覆盖。官方 Go 编出的 c-shared 库在鸿蒙（musl）上加载会崩，必须用带 `openharmony` 端口和 arm64 TLSDESC 的版本。
  - 这个工具链是把第三方分支 [star4277/ohos-go](https://github.com/star4277/ohos-go) v1.26.5-beta1 的补丁三方合并到官方 go1.27.4 上得到的。
  - 合并记录在 `~/ohos-toolchain/port`（git 仓库，分支 `ohos-1.27.4`）。
  - 重新生成工具链：`cd ~/ohos-toolchain/port && git archive ohos-1.27.4 | tar -x -C <目标目录>`，然后在 `<目标目录>/src` 下执行 `GOROOT_BOOTSTRAP=<任意 go1.24.6+> bash make.bash`。
- **DevEco 自带的 OHOS clang**。
- **同级目录 `../xray-core` 的 `harmonyos` 分支**（`golib/go.mod` 用 `replace` 指向它）。这个分支让鸿蒙在 TUN 和进程查找上走 Android 的路子：TUN fd 由外部传入，不做 `TUNGETIFF` 检查。

脚本会检查产物里有 `R_AARCH64_TLSDESC`，并且只导出 `Xray*` 符号。

## 已验证与未验证

- **已在 2in1 模拟器（API 24）上验证**：`dlopen` libxray.so；主线程和外来线程调用 Go；Xray 启动、输出日志、停止。
- **未验证**（需要真机，`hdc shell` 进程没有网络权限，没法测）：
  - VPN 建立后流量是否真的走 Xray；
  - `protect` 能否把 Xray 自己的连接排除出 VPN；
  - 鸿蒙给的 TUN fd 能否用非阻塞模式和 `F_DUPFD_CLOEXEC` 处理。
- **还没做**：
  - 代理服务器用域名时的解析；
  - geoip/geosite 数据文件（资源目录是应用的 `filesDir`，配置里用了 `geoip:`/`geosite:` 时需要先把 `.dat` 放进去）；
  - 流量统计、自动重连、托盘保活。
