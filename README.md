# YSRSAI Light PIR Lux — SmartThings Edge driver

An unofficial SmartThings Edge driver based on an existing YSRSAI Light PIR Lux project. It is not an official SmartThings or Zigbee2MQTT (Z2M) driver, and is not officially supported by Z2M.

## Device and requirements

The Zigbee fingerprint matches manufacturer `YSRSAI` and model `Light-PIR-Lux`. A compatible SmartThings hub, a SmartThings account and compatible device firmware are required. This repository contains the driver, not firmware.

## Install

1. Sign in to SmartThings with the account associated with your hub.
2. Open the [driver channel invitation](https://callaway.smartthings.com/channels/f6ef8e37-4ac3-47b8-bf40-64412dd6ae40?status=accepted), accept or enroll the hub as prompted, and install the YSRSAI Light PIR Lux driver on that hub.
3. Put the device in pairing mode and add it using the SmartThings app. Confirm that the intended driver was assigned. For an already paired device, use the app's driver selection where available; re-pairing may be necessary. Record automations and settings before removing a device.

The channel URL is supplied by the project owner; its accessibility, enrollment and the driver available there have not been verified for this release. The hub must have the driver installed; downloading this repository alone does not install it.

## Capabilities

The driver maps EP1 to the light, EP2 to motion, EP3 to illuminance and EP4–EP7 to four scene-key components. Available features depend on the device firmware and selected profile; a declared capability does not guarantee hardware support.

| EP1 device type | Driver profile | Declared light capabilities |
| --- | --- | --- |
| `0x0101` | `light-pir-lux-dim` | Switch and level |
| `0x010C` | `light-pir-lux-cct` | Switch, level and color temperature |
| `0x0102` or `0x010D` | `light-pir-lux` | Switch, level, color temperature and color control |

If EP1's device type is missing or not recognized, the driver leaves the current profile unchanged. The fingerprint's initial profile is `light-pir-lux`.

### Color temperature range

For profiles that expose color temperature, the driver accepts and reports approximately **2000-6500 K**. The corresponding Zigbee `ColorTemperatureMireds` range is approximately **154-500 mired** (`mired = 1,000,000 / kelvin`). Commands and reports outside this range are ignored. The exact displayed endpoint can differ slightly because Zigbee uses integer mired values.

For scene-key Multistate Input PresentValue reports, the driver maps `1` to `pushed`, `2` to `double`, and `3` to `held`; other values are ignored. Firmware must send compatible reports for these events to appear.

## Status and limitations

This is based on an existing project and the package identifies itself as a test driver. The channel link, installation, profile selection and all device capabilities have not been verified in this publication session. Test with your own hub and firmware; behavior can vary by firmware, device and SmartThings configuration. No license is specified in this repository.
