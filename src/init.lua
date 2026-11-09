local capabilities = require "st.capabilities"
local ZigbeeDriver = require "st.zigbee"
local clusters = require "st.zigbee.zcl.clusters"
local device_management = require "st.zigbee.device_management"
local log = require "log"

local OnOff = clusters.OnOff
local Level = clusters.Level
local OccupancySensing = clusters.OccupancySensing
local IlluminanceMeasurement = clusters.IlluminanceMeasurement
local ColorControl = clusters.ColorControl

local EP_LIGHT = 0x01
local EP_OCCUPANCY = 0x02
local EP_ILLUMINANCE = 0x03
local EP_KEY1 = 0x04
local EP_KEY4 = 0x07
local MULTISTATE_INPUT = 0x0012
local PRESENT_VALUE = 0x0055
local REPORT_ATTRIBUTES = 0x0A
local BUTTON_DEDUP_SECONDS = 5

local function light_device_type(device)
  local endpoints = device.zigbee_endpoints
  local ep = endpoints and endpoints[EP_LIGHT]
  return ep and ep.device_id
end

local function select_light_profile(device)
  local kind = light_device_type(device)
  local profiles = {
    [0x0101] = "light-pir-lux-dim",
    [0x010C] = "light-pir-lux-cct",
    [0x0102] = "light-pir-lux",
    [0x010D] = "light-pir-lux"
  }
  local name = profiles[kind]
  if name and device.profile and device.profile.id then
    -- try_update_metadata accepts a profile YAML name and avoids relying on
    -- the mutable SmartThings profile identifier. Missing EP1 leaves the
    -- current profile unchanged instead of guessing.
    device:try_update_metadata({ profile = name })
  end
end

local function supports_color_control(device)
  local kind = light_device_type(device)
  return kind == 0x0102 or kind == 0x010D
end

local function supports_temperature(device)
  local kind = light_device_type(device)
  return kind == 0x010C or kind == 0x010D or kind == 0x0102
end

local function component_to_endpoint(device, component_id)
  if component_id == "main" then
    return EP_LIGHT
  elseif component_id == "motion" then
    return EP_OCCUPANCY
  elseif component_id == "illuminance" then
    return EP_ILLUMINANCE
  elseif component_id == "key1" then
    return 0x04
  elseif component_id == "key2" then
    return 0x05
  elseif component_id == "key3" then
    return 0x06
  elseif component_id == "key4" then
    return 0x07
  end
  return nil
end

local function endpoint_to_component(device, endpoint)
  if endpoint == EP_LIGHT then
    return "main"
  elseif endpoint == EP_OCCUPANCY then
    return "motion"
  elseif endpoint == EP_ILLUMINANCE then
    return "illuminance"
  elseif endpoint and endpoint >= EP_KEY1 and endpoint <= EP_KEY4 then
    return "key" .. tostring(endpoint - 3)
  end
  return nil
end

local function emit_switch(driver, device, value, zb_rx)
  local endpoint = zb_rx.address_header.src_endpoint.value
  if endpoint ~= EP_LIGHT then
    return
  end
  local component = endpoint_to_component(device, endpoint)
  local state = value.value and "on" or "off"
  device:emit_component_event(device.profile.components[component], capabilities.switch.switch[state]())
end

local function emit_button(driver, device, value, zb_rx)
  local endpoint = zb_rx.address_header.src_endpoint.value
  if endpoint < EP_KEY1 or endpoint > EP_KEY4 then return end

  -- Read responses are snapshots, not new physical button actions.
  local header = zb_rx.body.zcl_header
  if header.cmd.value ~= REPORT_ATTRIBUTES then return end

  local event_name = ({ [1] = "pushed", [2] = "double", [3] = "held" })[value.value]
  if not event_name then return end

  -- Suppress retransmitted frames without suppressing distinct equal-valued presses.
  local now = os.time()
  local recent = device:get_field("button_recent_frames") or {}
  local key = endpoint .. ":" .. header.seqno.value .. ":" .. value.value
  for frame, received_at in pairs(recent) do
    if now - received_at >= BUTTON_DEDUP_SECONDS or now < received_at then
      recent[frame] = nil
    end
  end
  if recent[key] then return end
  recent[key] = now
  device:set_field("button_recent_frames", recent)

  local component = device.profile.components[endpoint_to_component(device, endpoint)]
  device:emit_component_event(component, capabilities.button.button[event_name]({ state_change = true }))
end

local function emit_main_level(driver, device, value, zb_rx)
  if zb_rx.address_header.src_endpoint.value ~= EP_LIGHT or type(value.value) ~= "number" or value.value < 0 or value.value > 254 then return end
  local level = math.floor((value.value * 100 / 254) + 0.5)
  device:emit_component_event(device.profile.components.main, capabilities.switchLevel.level(level))
end

local function emit_color_temperature(driver, device, value, zb_rx)
  local mireds = value.value
  if zb_rx.address_header.src_endpoint.value ~= EP_LIGHT or type(mireds) ~= "number" or mireds <= 0 or mireds >= 0xFFFF then
    return
  end

  local kelvin = math.floor((1000000 / mireds) + 0.5)
  device:emit_component_event(device.profile.components.main, capabilities.colorTemperature.colorTemperature(kelvin))
end

local function emit_motion(driver, device, value, zb_rx)
  log.info(string.format("PIR occupancy ep=%s value=%s", tostring(zb_rx.address_header.src_endpoint.value), tostring(value.value)))
  local occupied = (value.value & 0x01) ~= 0
  local state = occupied and "active" or "inactive"
  device:emit_component_event(device.profile.components.motion, capabilities.motionSensor.motion[state]())
end

local function emit_illuminance(driver, device, value, zb_rx)
  local measured_value = value.value
  if measured_value == nil or measured_value == 0xFFFF then
    return
  end

  local lux = math.floor((10 ^ ((measured_value - 1) / 10000)) + 0.5)
  device:emit_component_event(device.profile.components.illuminance, capabilities.illuminanceMeasurement.illuminance(lux))
end

-- Invalidate delayed level commands/readbacks whenever a new light command arrives.
local function invalidate_level(device)
  local generation = (device:get_field("level_generation") or 0) + 1
  device:set_field("level_generation", generation)
  return generation
end

local function switch_on(driver, device, command)
  local component = command.component
  if component == "main" then
    invalidate_level(device)
    device:send_to_component(component, OnOff.server.commands.On(device))
    -- Device firmware updates its attribute but may not report it. Read the
    -- actual value back rather than emitting an unverified optimistic state.
    device.thread:call_with_delay(0.5, function()
      device:send_to_component(component, OnOff.attributes.OnOff:read(device))
    end)
  end
end

local function switch_off(driver, device, command)
  local component = command.component
  if component == "main" then
    invalidate_level(device)
    device:send_to_component(component, OnOff.server.commands.Off(device))
    device.thread:call_with_delay(0.5, function()
      device:send_to_component(component, OnOff.attributes.OnOff:read(device))
    end)
  end
end

local function set_level(driver, device, command)
  if type(command.args.level) ~= "number" then return end
  local level = math.floor((math.max(0, math.min(100, command.args.level)) * 254 / 100) + 0.5)
  local generation = invalidate_level(device)
  local function send_latest()
    if device:get_field("level_generation") ~= generation then return end
    device:send_to_component("main", Level.server.commands.MoveToLevelWithOnOff(device, level, 0, 0, 0))
    local read_timer = device.thread:call_with_delay(1, function()
      if device:get_field("level_generation") ~= generation then return end
      device:send_to_component("main", Level.attributes.CurrentLevel:read(device))
      device:send_to_component("main", OnOff.attributes.OnOff:read(device))
    end)
    if not read_timer then
      log.warn("Level readback timer unavailable; reading state immediately")
      device:send_to_component("main", Level.attributes.CurrentLevel:read(device))
      device:send_to_component("main", OnOff.attributes.OnOff:read(device))
    end
  end
  local timer = device.thread:call_with_delay(0.2, send_latest)
  if not timer then
    log.warn("Level debounce timer unavailable; sending latest command immediately")
    send_latest()
  end
end

local function set_color_temperature(driver, device, command)
  local kelvin = command.args.temperature
  if kelvin == nil or kelvin <= 0 then
    return
  end

  local mireds = math.floor((1000000 / kelvin) + 0.5)
  device:send_to_component("main", ColorControl.server.commands.MoveToColorTemperature(device, mireds, 0, 0, 0))
  device.thread:call_with_delay(1, function()
    device:send_to_component("main", ColorControl.attributes.ColorTemperatureMireds:read(device))
  end)
end

local function color_byte(value)
  if type(value) ~= "number" then return nil end
  return math.floor(math.max(0, math.min(100, value)) * 254 / 100 + 0.5)
end

local function read_color_after_command(device)
  device.thread:call_with_delay(1, function()
    log.info("Reading EP1 color state after command")
    device:send_to_component("main", ColorControl.attributes.CurrentHue:read(device))
    device:send_to_component("main", ColorControl.attributes.CurrentSaturation:read(device))
    device:send_to_component("main", ColorControl.attributes.ColorMode:read(device))
  end)
end

local function set_hue(driver, device, command)
  local hue = color_byte(command.args.hue)
  if hue then
    device:send_to_component("main", ColorControl.server.commands.MoveToHue(device, hue, 0, 0, 0, 0))
    read_color_after_command(device)
  end
end

local function set_saturation(driver, device, command)
  local saturation = color_byte(command.args.saturation)
  if saturation then
    device:send_to_component("main", ColorControl.server.commands.MoveToSaturation(device, saturation, 0, 0, 0))
    read_color_after_command(device)
  end
end

local function set_color(driver, device, command)
  local color = command.args.color
  if type(color) ~= "table" then return end
  local hue, saturation = color_byte(color.hue), color_byte(color.saturation)
  if hue and saturation then
    log.info(string.format("Set color EP1 hue=%d saturation=%d", hue, saturation))
    device:send_to_component("main", ColorControl.server.commands.MoveToHueAndSaturation(device, hue, saturation, 0, 0, 0))
    read_color_after_command(device)
  end
end

local function emit_hue(driver, device, value, zb_rx)
  log.info(string.format("EP1 current hue=%s", tostring(value.value)))
  if zb_rx.address_header.src_endpoint.value == EP_LIGHT and value.value and value.value <= 254 then
    device:emit_component_event(device.profile.components.main, capabilities.colorControl.hue(math.floor(value.value * 100 / 254 + 0.5)))
  end
end

local function emit_saturation(driver, device, value, zb_rx)
  log.info(string.format("EP1 current saturation=%s", tostring(value.value)))
  if zb_rx.address_header.src_endpoint.value == EP_LIGHT and value.value and value.value <= 254 then
    device:emit_component_event(device.profile.components.main, capabilities.colorControl.saturation(math.floor(value.value * 100 / 254 + 0.5)))
  end
end

local function log_color_mode(driver, device, value, zb_rx)
  if zb_rx.address_header.src_endpoint.value ~= EP_LIGHT then return end
  log.info(string.format("EP1 current color mode=%s", tostring(value.value)))
  if value.value == 1 then
    log.warn("EP1 uses XY color mode; hue and saturation may not reflect its current color")
  end
end

local function device_added(driver, device)
  device:refresh()
end

local function device_refresh(driver, device, command)
  device:send_to_component("main", OnOff.attributes.OnOff:read(device))
  device:send_to_component("main", Level.attributes.CurrentLevel:read(device))
  if supports_temperature(device) then
    device:send_to_component("main", ColorControl.attributes.ColorTemperatureMireds:read(device))
  end
  if supports_color_control(device) then
    device:send_to_component("main", ColorControl.attributes.CurrentHue:read(device))
    device:send_to_component("main", ColorControl.attributes.CurrentSaturation:read(device))
    device:send_to_component("main", ColorControl.attributes.ColorMode:read(device))
  end
  device:send_to_component("motion", OccupancySensing.attributes.Occupancy:read(device))
  device:send_to_component("illuminance", IlluminanceMeasurement.attributes.MeasuredValue:read(device))
end

local function configure_pir(driver, device)
  log.info("Requesting PIR EP2 bind and occupancy reporting")
  device:send(device_management.build_bind_request(device, OccupancySensing.ID, driver.environment_info.hub_zigbee_eui, EP_OCCUPANCY))
  device:send_to_component("motion", OccupancySensing.attributes.Occupancy:configure_reporting(device, 0, 300))
end

local do_configure

local function device_init(driver, device)
  device:set_component_to_endpoint_fn(component_to_endpoint)
  device:set_endpoint_to_component_fn(endpoint_to_component)
  select_light_profile(device)
  device.thread:call_with_delay(2, function()
    for key = 1, 4 do
      local component = device.profile.components["key" .. tostring(key)]
      device:emit_component_event(component, capabilities.button.supportedButtonValues(
        { "pushed", "double", "held" }, { visibility = { displayed = false } }))
      device:emit_component_event(component, capabilities.button.numberOfButtons(
        { value = 1 }, { visibility = { displayed = false } }))
    end
    do_configure(driver, device)
  end)
end

do_configure = function(driver, device)
  configure_pir(driver, device)
  device:send(device_management.build_bind_request(device, OnOff.ID, driver.environment_info.hub_zigbee_eui, EP_LIGHT))
  device:send(device_management.build_bind_request(device, Level.ID, driver.environment_info.hub_zigbee_eui, EP_LIGHT))
  if supports_temperature(device) or supports_color_control(device) then
    device:send(device_management.build_bind_request(device, ColorControl.ID, driver.environment_info.hub_zigbee_eui, EP_LIGHT))
  end
  device:send(device_management.build_bind_request(device, IlluminanceMeasurement.ID, driver.environment_info.hub_zigbee_eui, EP_ILLUMINANCE))
  device:send_to_component("main", OnOff.attributes.OnOff:configure_reporting(device, 1, 300))
  device:send_to_component("main", Level.attributes.CurrentLevel:configure_reporting(device, 1, 300, 1))
  device:send_to_component("illuminance", IlluminanceMeasurement.attributes.MeasuredValue:configure_reporting(device, 5, 300, 100))
  if supports_temperature(device) then
    device:send_to_component("main", ColorControl.attributes.ColorTemperatureMireds:configure_reporting(device, 1, 300, 1))
  end
  if supports_color_control(device) then
    device:send_to_component("main", ColorControl.attributes.CurrentHue:configure_reporting(device, 1, 300, 1))
    device:send_to_component("main", ColorControl.attributes.CurrentSaturation:configure_reporting(device, 1, 300, 1))
  end
  -- Firmware sends each action directly to the coordinator; avoid a second
  -- configured attribute report that could duplicate button events.
  device_refresh(driver, device)
end

local light_pir_lux = {
  supported_capabilities = {
    capabilities.switch,
    capabilities.switchLevel,
    capabilities.colorTemperature,
    capabilities.colorControl,
    capabilities.refresh,
    capabilities.motionSensor,
    capabilities.button,
    capabilities.illuminanceMeasurement
  },
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    doConfigure = do_configure
  },
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = switch_on,
      [capabilities.switch.commands.off.NAME] = switch_off
    },
    [capabilities.switchLevel.ID] = {
      [capabilities.switchLevel.commands.setLevel.NAME] = set_level
    },
    [capabilities.colorTemperature.ID] = {
      [capabilities.colorTemperature.commands.setColorTemperature.NAME] = set_color_temperature
    },
    [capabilities.colorControl.ID] = {
      [capabilities.colorControl.commands.setHue.NAME] = set_hue,
      [capabilities.colorControl.commands.setSaturation.NAME] = set_saturation,
      [capabilities.colorControl.commands.setColor.NAME] = set_color
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = do_configure
    }
  },
  zigbee_handlers = {
    attr = {
      [MULTISTATE_INPUT] = {
        [PRESENT_VALUE] = emit_button
      },
      [OnOff.ID] = {
        [OnOff.attributes.OnOff.ID] = emit_switch
      },
      [Level.ID] = {
        [Level.attributes.CurrentLevel.ID] = emit_main_level
      },
      [ColorControl.ID] = {
        [ColorControl.attributes.ColorTemperatureMireds.ID] = emit_color_temperature,
        [ColorControl.attributes.CurrentHue.ID] = emit_hue,
        [ColorControl.attributes.CurrentSaturation.ID] = emit_saturation,
        [ColorControl.attributes.ColorMode.ID] = log_color_mode
      },
      [OccupancySensing.ID] = {
        [OccupancySensing.attributes.Occupancy.ID] = emit_motion
      },
      [IlluminanceMeasurement.ID] = {
        [IlluminanceMeasurement.attributes.MeasuredValue.ID] = emit_illuminance
      }
    }
  },
  zigbee_channel_configuration = {
    { cluster = OnOff.ID, attribute = OnOff.attributes.OnOff.ID, minimum_interval = 1, maximum_interval = 300 },
    { cluster = Level.ID, attribute = Level.attributes.CurrentLevel.ID, minimum_interval = 1, maximum_interval = 300, reportable_change = 1 },
    { cluster = OccupancySensing.ID, attribute = OccupancySensing.attributes.Occupancy.ID, minimum_interval = 0, maximum_interval = 300 },
    { cluster = IlluminanceMeasurement.ID, attribute = IlluminanceMeasurement.attributes.MeasuredValue.ID, minimum_interval = 5, maximum_interval = 300, reportable_change = 100 },
    { cluster = ColorControl.ID, attribute = ColorControl.attributes.ColorTemperatureMireds.ID, minimum_interval = 1, maximum_interval = 300, reportable_change = 1 },
    { cluster = ColorControl.ID, attribute = ColorControl.attributes.CurrentHue.ID, minimum_interval = 1, maximum_interval = 300, reportable_change = 1 },
    { cluster = ColorControl.ID, attribute = ColorControl.attributes.CurrentSaturation.ID, minimum_interval = 1, maximum_interval = 300, reportable_change = 1 }
  }
}

local driver = ZigbeeDriver("ysrsai-light-pir-lux", light_pir_lux)
driver:run()
