local unit_helper = require("common/utility/unit_helper")
local izi = require("common/izi_sdk")
local enums = require("common/enums")
local key_helper = require("common/utility/key_helper")
local control_panel_helper = require("common/utility/control_panel_helper")

local buffs = enums.buff_db

local SPELLS =
{
    COMBUSTION = izi.spell(190319),
    FIREBALL = izi.spell(133),      
    FIREBLAST = izi.spell(108853),  
    PYROBLAST = izi.spell(11366),   
    SCORCH = izi.spell(2948),       
    FLAMESTRIKE = izi.spell(2120),  
    METEOR = izi.spell(153561)      
}

local CUSTOMBUFFS =
{
    PYROCLASM = 269651
}

local last_pyroclasm_stacks = 0
local consumed_pyroclasm_stacks = 0
local last_fireblast_time = 0

local TAG = "blaze_fire_mage_"

local menu =
{
    root            = core.menu.tree_node(),
    enabled         = core.menu.checkbox(false, TAG .. "enabled"),
    toggle_key      = core.menu.keybind(7, false, TAG .. "toggle"),
    combustion_key  = core.menu.keybind(7, false, TAG .. "combustion_key"),
}

---@return boolean enabled
local function rotation_enabled()
    return menu.enabled:get_state() and menu.toggle_key:get_toggle_state()
end

---@param target game_object
---@return boolean
local function is_aoe(target)
    local units_around_target = unit_helper:get_enemy_list_around(target:get_position(), 15.0)
    return #units_around_target > 1
end

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

core.register_on_update_callback(function()
    control_panel_helper:on_update(menu)

    if not rotation_enabled() then
        return
    end

    local me = izi.me()
    if not me then
        return
    end

    --Get current Pyroclasm stacks dynamically (can be 0, 1, or 2)
    local actual_pyroclasm_stacks = me.get_buff_stacks(me, CUSTOMBUFFS.PYROCLASM) or 0
    
    --Reset consumed count only when stacks increase or buff expires (not when decreasing from consumption)
    if actual_pyroclasm_stacks > last_pyroclasm_stacks or actual_pyroclasm_stacks == 0 then
        consumed_pyroclasm_stacks = 0
    end
    last_pyroclasm_stacks = actual_pyroclasm_stacks
    
    local pyroclasm_stacks = math.max(0, actual_pyroclasm_stacks - consumed_pyroclasm_stacks)

    local has_hot_streak = me:buff_up(buffs.HOT_STREAK)
    local has_hyperthermia = me:buff_up(buffs.HYPERTHERMIA)
    local has_heat_shimmer = me:buff_up(buffs.HEAT_SHIMMER)
    local has_heating_up = me:buff_up(buffs.HEATING_UP)
    local has_combustion = me:buff_up(buffs.COMBUSTION)
    local is_moving = me:is_moving()
    local combustion_toggle = menu.combustion_key:get_toggle_state()

    local targets = izi.get_ts_targets()

    --Loop through all targets and run our logic on each one
    for i = 1, #targets do
        local target = targets[i]
        
        if not (target and target:is_valid()) then
            goto continue
        end

        if target:is_damage_immune(target.DMG.MAGICAL) then
            goto continue
        end

        if target:is_cc_weak() then
            goto continue
        end

        local aoe_active = is_aoe(target)

        -- [[AOE LOGIC]]
        if aoe_active then
            
            -- Meteor Logic (Highest Priority)
            local combustion_cd_remaining = SPELLS.COMBUSTION:cooldown_remains()
            local should_hold_meteor = combustion_cd_remaining > 0 and combustion_cd_remaining <= 10

            if not should_hold_meteor then
                if SPELLS.METEOR:cast_safe(target, "AoE: Meteor",
                        {
                            use_prediction  = true,
                            prediction_type = "MOST_HITS",
                            geometry        = "CIRCLE",
                            aoe_radius      = 8,
                            min_hits        = 2,
                            cast_time       = 0,
                            skip_moving     = true,
                            check_los       = false,
                        })
                then
                    return
                end
            end

            local is_flamestrike_instant = has_hot_streak or has_hyperthermia

            if is_flamestrike_instant then
                if SPELLS.FLAMESTRIKE:cast_safe(target, "AoE: Flamestrike",
                        {
                            use_prediction  = true,
                            prediction_type = "MOST_HITS",
                            geometry        = "CIRCLE",
                            aoe_radius      = 8,
                            min_hits        = 2,
                            cast_time       = 0,
                            skip_moving     = is_flamestrike_instant,
                            check_los       = false,
                        })
                then
                    return
                end
            end
        end

        --Combustion logic
        if combustion_toggle and SPELLS.COMBUSTION:cooldown_remains() == 0 then
            local is_casting_fireball = me:is_casting() and me:casting_pct() < 90
            if is_casting_fireball then
                if SPELLS.COMBUSTION:cast_safe(me, "Cooldown: Combustion", { cast_time = 0, skip_moving = true, skip_casting = true }) then
                    return
                end
            else
                if SPELLS.FIREBALL:cast_safe(target, "Setup: Fireball for Combustion") then
                    return
                end
            end
        end
        
        --[[SINGLE TARGET LOGIC]]

        -- Pyroblast logic (Hot Streak)
        if has_hot_streak or has_hyperthermia then
            if SPELLS.PYROBLAST:cast_safe(target, "Single Target: Pyroblast",
                    {
                        cast_time   = 0,
                        skip_moving = true,
                    })
            then
                return
            end
        end

        -- Pyroclasm Hardcast Pyroblast logic
        if pyroclasm_stacks > 0 and not has_hyperthermia and not has_combustion then
            if not aoe_active then
                if SPELLS.PYROBLAST:cast_safe(target, "Single Target: Pyroblast (Pyroclasm Hardcast)") then
                    --Track consumed stack to prevent double-casting before buff updates
                    consumed_pyroclasm_stacks = consumed_pyroclasm_stacks + 1
                    return
                end
            else
                if SPELLS.FLAMESTRIKE:cast_safe(target, "AoE: Flamestrike (Pyroclasm)",
                        {
                            use_prediction  = true,
                            prediction_type = "MOST_HITS",
                            geometry        = "CIRCLE",
                            aoe_radius      = 8,
                            min_hits        = 2,
                        })
                then
                    --Track consumed stack to prevent double-casting before buff updates
                    consumed_pyroclasm_stacks = consumed_pyroclasm_stacks + 1
                    return
                end
            end
        end

        -- Scorch Logic (Heat Shimmer)
        if has_heat_shimmer and has_heating_up and not has_hyperthermia then
            if SPELLS.SCORCH:cast_safe(target, "Single Target: Scorch (Heat Shimmer)",
                    {
                        cast_time   = 0,
                        skip_moving = true,
                    })
            then
                return
            end
        end

        -- Scorch Logic (Moving)
        if is_moving and not has_hot_streak and not has_hyperthermia then
            if SPELLS.SCORCH:cast_safe(target, "Single Target: Scorch (Moving)",
                    {
                        skip_moving = true,
                    })
            then
                return
            end
        end

        -- Fire Blast Logic
        if has_heating_up and not has_heat_shimmer and not has_hyperthermia and (GetTime() - last_fireblast_time > 0.5) then
            if SPELLS.FIREBLAST:cast_safe(target, "Single Target: Fire Blast",
                    {
                        skip_gcd     = true,
                        skip_casting = true,
                        cast_time    = 0,
                        skip_moving  = true,
                    })
            then
                last_fireblast_time = GetTime()
                return
            end
        end

        if SPELLS.FIREBALL:cast_safe(target, "Single Target: Fireball") then
            return
        end

        ::continue::
    end
end)
