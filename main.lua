-- ============================================
-- DEPENDENCIES
-- ============================================
local unit_helper = require("common/utility/unit_helper")
local izi = require("common/izi_sdk")
local enums = require("common/enums")
local key_helper = require("common/utility/key_helper")
local control_panel_helper = require("common/utility/control_panel_helper")

local buffs = enums.buff_db

-- ============================================
-- CONSTANTS
-- ============================================
local TAG = "blaze_fire_mage_"

local CONSTANTS = {
    AOE_RANGE = 15.0,
    AOE_MIN_TARGETS = 2,
    FLAMESTRIKE_RADIUS = 8,
    FIREBLAST_COOLDOWN = 0.5,
    COMBUSTION_FIREBALL_THRESHOLD = 90,
    COMBUSTION_METEOR_TIME = 6,
    METEOR_ALTERNATIVE_CD = 15
}

local fireball_id = core.spell_book.is_spell_learned(431044) and 431044 or 133

local SPELLS = {
    COMBUSTION = izi.spell(190319),
    FIREBALL = izi.spell(fireball_id),
    FIREBLAST = izi.spell(108853),
    PYROBLAST = izi.spell(11366),
    SCORCH = izi.spell(2948),
    FLAMESTRIKE = izi.spell(2120),
    METEOR = izi.spell(153561)
}

local CUSTOMBUFFS = {
    PYROCLASM = 269651
}

-- ============================================
-- STATE TRACKING
-- ============================================
local state = {
    last_pyroclasm_stacks = 0,
    consumed_pyroclasm_stacks = 0,
    last_fireblast_time = 0
}

-- ============================================
-- MENU CONFIGURATION
-- ============================================
local menu = {
    root           = core.menu.tree_node(),
    enabled        = core.menu.checkbox(false, TAG .. "enabled"),
    toggle_key     = core.menu.keybind(7, false, TAG .. "toggle"),
    combustion_key = core.menu.keybind(7, false, TAG .. "combustion_key"),
}

-- ============================================
-- HELPER FUNCTIONS
-- ============================================

---@return boolean
local function rotation_enabled()
    return menu.enabled:get_state() and menu.toggle_key:get_toggle_state()
end

---@param target game_object
---@return boolean
local function is_aoe(target)
    local units_around_target = unit_helper:get_enemy_list_around(target:get_position(), CONSTANTS.AOE_RANGE)
    return #units_around_target >= CONSTANTS.AOE_MIN_TARGETS
end

---@param me game_object
---@return table
local function get_player_buffs(me)
    return {
        hot_streak = me:buff_up(buffs.HOT_STREAK),
        hyperthermia = me:buff_up(buffs.HYPERTHERMIA),
        heat_shimmer = me:buff_up(buffs.HEAT_SHIMMER),
        heating_up = me:buff_up(buffs.HEATING_UP),
        combustion = me:buff_up(buffs.COMBUSTION),
        combustion_remains = me:buff_remains(buffs.COMBUSTION)
    }
end

---@param target game_object
---@return boolean
local function is_valid_target(target)
    if not (target and target:is_valid()) then
        return false
    end
    if target:is_damage_immune(target.DMG.MAGICAL) then
        return false
    end
    if target:is_cc_weak() then
        return false
    end
    return true
end

---@param me game_object
---@return number
local function update_pyroclasm_stacks(me)
    local actual_stacks = me.get_buff_stacks(me, CUSTOMBUFFS.PYROCLASM) or 0
    
    if actual_stacks > state.last_pyroclasm_stacks or actual_stacks == 0 then
        state.consumed_pyroclasm_stacks = 0
    end
    state.last_pyroclasm_stacks = actual_stacks
    
    return math.max(0, actual_stacks - state.consumed_pyroclasm_stacks)
end

---@param player_buffs table
---@param combustion_cd number
---@return boolean
local function should_cast_meteor(player_buffs, combustion_cd)
    if player_buffs.combustion then
        local is_frostfire = core.spell_book.is_spell_learned(431044)
        if not is_frostfire or player_buffs.combustion_remains <= CONSTANTS.COMBUSTION_METEOR_TIME then
            return true
        end
        return false
    else
        return combustion_cd == 0 or combustion_cd > CONSTANTS.METEOR_ALTERNATIVE_CD
    end
end

-- ============================================
-- ROTATION LOGIC
-- ============================================

---@param target game_object
---@param player_buffs table
---@return boolean
local function execute_aoe_rotation(target, player_buffs)
    local is_flamestrike_instant = player_buffs.hot_streak or player_buffs.hyperthermia
    
    if is_flamestrike_instant then
        if SPELLS.FLAMESTRIKE:cast_safe(target, "AoE: Flamestrike", {
            use_prediction  = true,
            prediction_type = "MOST_HITS",
            geometry        = "CIRCLE",
            aoe_radius      = CONSTANTS.FLAMESTRIKE_RADIUS,
            min_hits        = CONSTANTS.AOE_MIN_TARGETS,
            cast_time       = 0,
            skip_moving     = true,
            check_los       = false,
        }) then
            return true
        end
    end
    return false
end

---@param target game_object
---@param me game_object
---@param player_buffs table
---@param combustion_toggle boolean
---@return boolean
local function execute_combustion_sequence(target, me, player_buffs, combustion_toggle)
    if not combustion_toggle then
        return false
    end
    
    if SPELLS.COMBUSTION:cooldown_remains() == 0 then
        local is_casting_fireball = me:is_casting() and me:casting_pct() > CONSTANTS.COMBUSTION_FIREBALL_THRESHOLD
        if is_casting_fireball then
            if SPELLS.COMBUSTION:cast_safe(me, "Cooldown: Combustion", {
                cast_time = 0,
                skip_moving = true,
                skip_casting = true
            }) then
                return true
            end
        else
            if SPELLS.FIREBALL:cast_safe(target, "Setup: Fireball for Combustion") then
                return true
            end
        end
    end
    return false
end

---@param target game_object
---@param player_buffs table
---@param combustion_cd number
---@return boolean
local function execute_meteor(target, player_buffs, combustion_cd)
    if SPELLS.METEOR:cooldown_remains() ~= 0 then
        return false
    end
    
    if not should_cast_meteor(player_buffs, combustion_cd) then
        return false
    end
    
    if SPELLS.METEOR:cast_safe(target, "Rotation: Meteor", {
        use_prediction  = true,
        prediction_type = "MOST_HITS",
        geometry        = "CIRCLE",
        aoe_radius      = CONSTANTS.FLAMESTRIKE_RADIUS,
        min_hits        = 1,
        cast_time       = 0,
        skip_moving     = true,
        check_los       = false,
    }) then
        return true
    end
    return false
end

---@param target game_object
---@param player_buffs table
---@return boolean
local function execute_pyroblast(target, player_buffs)
    if player_buffs.hot_streak or player_buffs.hyperthermia then
        if SPELLS.PYROBLAST:cast_safe(target, "Single Target: Pyroblast", {
            cast_time   = 0,
            skip_moving = true,
        }) then
            return true
        end
    end
    return false
end

---@param target game_object
---@param pyroclasm_stacks number
---@param player_buffs table
---@param aoe_active boolean
---@return boolean
local function execute_pyroclasm(target, pyroclasm_stacks, player_buffs, aoe_active)
    if pyroclasm_stacks == 0 or player_buffs.hyperthermia or player_buffs.combustion then
        return false
    end
    
    if not aoe_active then
        if SPELLS.PYROBLAST:cast_safe(target, "Single Target: Pyroblast (Pyroclasm Hardcast)") then
            state.consumed_pyroclasm_stacks = state.consumed_pyroclasm_stacks + 1
            return true
        end
    else
        if SPELLS.FLAMESTRIKE:cast_safe(target, "AoE: Flamestrike (Pyroclasm)", {
            use_prediction  = true,
            prediction_type = "MOST_HITS",
            geometry        = "CIRCLE",
            aoe_radius      = CONSTANTS.FLAMESTRIKE_RADIUS,
            min_hits        = CONSTANTS.AOE_MIN_TARGETS,
        }) then
            state.consumed_pyroclasm_stacks = state.consumed_pyroclasm_stacks + 1
            return true
        end
    end
    return false
end

---@param target game_object
---@param player_buffs table
---@param is_moving boolean
---@return boolean
local function execute_scorch(target, player_buffs, is_moving)
    -- Heat Shimmer Scorch
    if player_buffs.heat_shimmer and player_buffs.heating_up and not player_buffs.hyperthermia then
        if SPELLS.SCORCH:cast_safe(target, "Single Target: Scorch (Heat Shimmer)", {
            cast_time   = 0,
            skip_moving = true,
        }) then
            return true
        end
    end
    
    -- Moving Scorch
    if is_moving and not player_buffs.hot_streak and not player_buffs.hyperthermia then
        if SPELLS.SCORCH:cast_safe(target, "Single Target: Scorch (Moving)", {
            skip_moving = true,
        }) then
            return true
        end
    end
    return false
end

---@param target game_object
---@param player_buffs table
---@param current_time number
---@return boolean
local function execute_fireblast(target, player_buffs, current_time)
    if not player_buffs.heating_up or player_buffs.heat_shimmer or player_buffs.hyperthermia then
        return false
    end
    
    if (current_time - state.last_fireblast_time) <= CONSTANTS.FIREBLAST_COOLDOWN then
        return false
    end
    
    if SPELLS.FIREBLAST:cast_safe(target, "Single Target: Fire Blast", {
        skip_gcd     = true,
        skip_casting = true,
        cast_time    = 0,
        skip_moving  = true,
    }) then
        state.last_fireblast_time = current_time
        return true
    end
    return false
end

---@param target game_object
---@param me game_object
---@param player_buffs table
---@param combustion_toggle boolean
---@param is_moving boolean
---@param current_time number
---@param aoe_active boolean
---@return boolean
local function execute_target_rotation(target, me, player_buffs, combustion_toggle, is_moving, current_time, aoe_active)
    local pyroclasm_stacks = update_pyroclasm_stacks(me)
    local combustion_cd = SPELLS.COMBUSTION:cooldown_remains()
    
    -- AOE Priority
    if aoe_active then
        if execute_aoe_rotation(target, player_buffs) then
            return true
        end
    end
    
    -- Combustion Setup
    if execute_combustion_sequence(target, me, player_buffs, combustion_toggle) then
        return true
    end
    
    -- Meteor
    if execute_meteor(target, player_buffs, combustion_cd) then
        return true
    end
    
    -- Hot Streak Pyroblast
    if execute_pyroblast(target, player_buffs) then
        return true
    end
    
    -- Pyroclasm Hardcast
    if execute_pyroclasm(target, pyroclasm_stacks, player_buffs, aoe_active) then
        return true
    end
    
    -- Scorch (Heat Shimmer or Moving)
    if execute_scorch(target, player_buffs, is_moving) then
        return true
    end
    
    -- Fire Blast
    if execute_fireblast(target, player_buffs, current_time) then
        return true
    end
    
    -- Filler: Fireball
    if SPELLS.FIREBALL:cast_safe(target, "Single Target: Fireball") then
        return true
    end
    
    return false
end

-- ============================================
-- MENU RENDERING
-- ============================================

core.register_on_render_menu_callback(function()
    menu.root:render("Blaze - Fire Mage", function()
        menu.enabled:render("Enabled Plugin")

        if not menu.enabled:get_state() then
            return
        end

        menu.toggle_key:render("Toggle Rotation")
        menu.combustion_key:render("Combustion Keybind")
    end)
end)

-- ============================================
-- CONTROL PANEL
-- ============================================

core.register_on_render_control_panel_callback(function()
    local control_panel_elements = {}

    if not menu.enabled:get_state() then
        return control_panel_elements
    end

    control_panel_helper:insert_toggle(control_panel_elements,
        {
            name = string.format("[Blaze - Fire Mage] Enabled (%s)",
                key_helper:get_key_name(menu.toggle_key:get_key_code())
            ),
            keybind = menu.toggle_key,
        })

    control_panel_helper:insert_toggle(control_panel_elements,
        {
            name = string.format("[Blaze - Fire Mage] Combustion (%s)",
                key_helper:get_key_name(menu.combustion_key:get_key_code())
            ),
            keybind = menu.combustion_key,
        })

    return control_panel_elements
end)

-- ============================================
-- MAIN UPDATE LOOP
-- ============================================

core.register_on_update_callback(function()
    control_panel_helper:on_update(menu)

    if not rotation_enabled() then
        return
    end

    local me = izi.me()
    if not me then
        return
    end

    -- Cache frequently-used values
    local player_buffs = get_player_buffs(me)
    local is_moving = me:is_moving()
    local combustion_toggle = menu.combustion_key:get_toggle_state()
    local current_time = GetTime()
    local targets = izi.get_ts_targets()

    -- Process all valid targets
    for i = 1, #targets do
        local target = targets[i]

        if not is_valid_target(target) then
            goto continue
        end

        local aoe_active = is_aoe(target)

        -- Execute rotation for this target
        if execute_target_rotation(target, me, player_buffs, combustion_toggle, is_moving, current_time, aoe_active) then
            return
        end

        ::continue::
    end
end)
