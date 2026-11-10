# SmartThings Edge Driver: YSRSAI Light PIR Lux

## SmartThings Edge channel (English)

The YSRSAI Light-PIR-Lux SmartThings Edge driver channel is available at:

https://callaway.smartthings.com/channels/f6ef8e37-4ac3-47b8-bf40-64412dd6ae40?status=accepted

### Installation

1. Sign in with the Samsung account associated with your SmartThings hub.
2. Open the channel link above and follow the prompts to enroll your hub or accept the invitation, if required.
3. Select the appropriate driver in the channel and install it on the hub.
4. Put the YSRSAI Light-PIR-Lux device into pairing mode and add it in the SmartThings app.
5. Verify that SmartThings assigned the intended Edge driver. If the device was previously paired, it may need to be removed and paired again; record any automations and settings before removing it.

A compatible SmartThings hub, a supported firmware version and an eligible account are required. Channel availability, driver selection and device capabilities depend on the account, hub, installed driver and firmware. The channel link has not been verified in this project session.

### Device overview

The device identifies itself as manufacturer `YSRSAI` and model `Light-PIR-Lux`. Depending on the firmware and driver profile, it may expose a main light, motion and illuminance sensors, and up to four scene-button components. Check the installed driver and test each capability on your hub; features are not guaranteed by the channel link alone.

---

## 原有中文说明

此驱动面向 TLSR8258 Zigbee 3.0 三端点设备，匹配 Basic Cluster：

```text
manufacturerName: YSRSAI
modelIdentifier:  Light-PIR-Lux
```

## Endpoint 到 SmartThings Component 的映射

| Zigbee Endpoint | ZCL Cluster | SmartThings Component | Capability |
| --- | --- | --- | --- |
| EP1 (`0x01`) | On/Off、Level Control、Color Control | `main` | `switch`、`switchLevel`、`colorTemperature` |
| EP2 (`0x02`) | Occupancy Sensing | `motion` | `motionSensor` |
| EP3 (`0x03`) | Illuminance Measurement | `illuminance` | `illuminanceMeasurement` |
| EP4 (`0x04`) | Multistate Input / PresentValue | `key1` | `button` |
| EP5 (`0x05`) | Multistate Input / PresentValue | `key2` | `button` |
| EP6 (`0x06`) | Multistate Input / PresentValue | `key3` | `button` |
| EP7 (`0x07`) | Multistate Input / PresentValue | `key4` | `button` |

色温范围：`2000-6500 K`。对应 Zigbee `ColorTemperatureMireds` 约为 `154-500 mired`，换算关系为 `mired = 1,000,000 / kelvin`。驱动会忽略超出该范围的色温命令和设备上报；由于 Zigbee 使用整数 mired，界面端点可能显示为约 `2000-6494 K`。

照度值按 Zigbee 标准从 `MeasuredValue` 解码为 lux：

```text
lux = 10 ^ ((MeasuredValue - 1) / 10000)
```

## 前置条件

1. 先烧录本工作区中的 YSRSAI 身份固件：
   `../tlsr8258-light-pir-lux/build/tlsr_tc32/sampleLight_8258/sampleLight_8258.bin`
2. 全片擦除，或在设备在线时从 SmartThings 删除，使网关不会使用旧的 Basic 描述符缓存。
3. 安装本驱动后，再让设备重新入网。

## 安装和调试

在有 SmartThings CLI 的终端中，进入本目录后执行：

```bash
smartthings login
smartthings edge:drivers:package . --install
```

若 CLI 版本把命令拆分为 package/install 两步，按该版本的 `smartthings edge:drivers:package --help` 输出执行；先打包上传，再选择目标 Hub 安装。

查看 Hub 日志：

```bash
smartthings edge:logcat
```

## 验证清单

1. SmartThings 扫描到型号 `YSRSAI / Light-PIR-Lux` 并分配本驱动。
2. App 中 `main` 可开关和调光。
3. 色温控件向 EP1 发送 Color Control 的 `MoveToColorTemperature`，并回读/订阅 `ColorTemperatureMireds`。
4. PIR 变化时 `motion` 从 inactive / active 切换。
5. EP3 上报的照度以 lux 显示在 `illuminance` 组件。
6. 从 App 修改灯状态后，EP1 的 On/Off 与 Level 属性能回报同步。
7. EP4~EP7 的四键事件显示为四个 button component：固件 `PresentValue=1` 映射 `pushed`，`2` 映射 `double`，`3/4/5` 映射 `held`。

## 限制

- 这是一个单物理设备、多 component 的 Driver，不会生成三张独立设备卡。
- 色温控制有效范围约为 `2000-6500 K`（约 `154-500 mired`）；实际显示端点受 Zigbee 整数 mired 量化影响。
- 该 Driver 仅改善 SmartThings 显示与控制，不改变 Hue、Tuya、Alexa 等网关的识别策略。
