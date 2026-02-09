--Import libraries
local unit_helper = require("common/utility/unit_helper")
local izi = require("common/izi_sdk")
local enums = require("common/enums")
local key_helper = require("common/utility/key_helper")
local control_panel_helper = require("common/utility/control_panel_helper")

--Lets create our own variable for buffs as we will typically access buff enums frequently
local buffs = enums.buff_db

--Constants
local AOE_RADIUS = 10 --The distance to scan around the target for AoE check

--Create a table containing all of our spells
local SPELLS =
{
    COMBUSTION = izi.spell(190319), --Create our izi_spell object for combustion
    FIREBALL = izi.spell(133),      --Create our izi_spell object for fireball
    FIREBLAST = izi.spell(108853),  --Create our izi_spell object for fire blast
    PYROBLAST = izi.spell(11366),   --Create our izi_spell object for pyroblast
    SCORCH = izi.spell(2948),       --Create our izi_spell object for scorch
    FLAMESTRIKE = izi.spell(2120),  --Create our izi_spell object for flamestrike
    METEOR = izi.spell(153561)      --Create our izi_spell object for meteor
}

local CUSTOMBUFFS =
{
    PYROCLASM = 269651
}

--Pyroclasm tracking to prevent double-casting before buff updates
local last_pyroclasm_stacks = 0
local consumed_pyroclasm_stacks = 0

--Settings prefix so we do not conflict with other plugins
local TAG = "izi_fire_mage_example_"

--Create our menu elements
local menu =
{
    --The tree for our menu elements
    root            = core.menu.tree_node(),

    --The global plugin enabled toggle
    enabled         = core.menu.checkbox(false, TAG .. "enabled"),

    --Hotkey to toggle the rotation on and off
    -- 7 "Undefined"
    -- 999 "Unbinded" but functional on control panel (allows people to click it without key bound)
    toggle_key      = core.menu.keybind(7, false, TAG .. "toggle"),

    combustion_key  = core.menu.keybind(7, false, TAG .. "combustion_key"),
}

--Checks to see if the plugin AND rotation is enabled
---@return boolean enabled
local function rotation_enabled()
    --We use get_toggle_state instead of get_state for the hotkey
    --because otherwise it will only be true if the key is held
    return menu.enabled:get_state() and menu.toggle_key:get_toggle_state()
end

---@param target game_object
---@return boolean
local function is_aoe(target)
    -- in range add the spell radius, in this case it's aprox 15 I suppose (didn't test)
    local units_around_target = unit_helper:get_enemy_list_around(target:get_position(), 15.0)
    return #units_around_target > 1
end

--Register Callbacks
--Our menu render callback
core.register_on_render_menu_callback(function()
    --Draw our menu tree and the children inside it
    menu.root:render("Blaze - Fire Mage", function()
        --Draw our plugin enabled checkbox
        menu.enabled:render("Enabled Plugin")

        --No need to render the rest of our items if we have the plugin disabled entirely
        if not menu.enabled:get_state() then
            return
        end

        --Draw our toggle rotation hotkey
        menu.toggle_key:render("Toggle Rotation")

        --Draw our combustion keybind
        menu.combustion_key:render("Combustion Keybind")
    end)
end)

--Our control panel render callback
core.register_on_render_control_panel_callback(function()
    --Create our control_panel_elements
    local control_panel_elements = {}

    --Check that the plugin is enabled
    if not menu.enabled:get_state() then
        --We return the empty table because there is no reason to draw anything
        --in the control panel if the plugin is not enabled
        return control_panel_elements
    end

    --Insert our rotation toggle into the control panel
    control_panel_helper:insert_toggle(control_panel_elements,
        {
            --Name is the name of the toggle in the control panel
            --We format it to display the current keybind
            name = string.format("[Blaze - Fire Mage] Enabled (%s)",
                key_helper:get_key_name(menu.toggle_key:get_key_code())
            ),
            --The menu element for the hotkey
            keybind = menu.toggle_key,
        })

    --Insert our combustion keybind toggle into the control panel
    control_panel_helper:insert_toggle(control_panel_elements,
        {
            name = string.format("[Blaze - Fire Mage] Combustion (%s)",
                key_helper:get_key_name(menu.combustion_key:get_key_code())
            ),
            keybind = menu.combustion_key,
        })

    return control_panel_elements --Return our elements to tell the control panel what to draw
end)

--Our main loop, this is executed every game tick
core.register_on_update_callback(function()
    --Fire control_panel_helper update to keep our control panel updated
    control_panel_helper:on_update(menu)

    --Rotation is not toggled no need to execute the rotation logic
    if not rotation_enabled() then
        return
    end

    --Get the local player
    local me = izi.me()

    --If the local player is nil (not in the world, etc), we will abort execution
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
    
    --Calculate available stacks (actual stacks minus what we've already consumed)
    local pyroclasm_stacks = math.max(0, actual_pyroclasm_stacks - consumed_pyroclasm_stacks)

    --Grab the targets from the target selector
    local targets = izi.get_ts_targets()

    --Loop through all targets and run our logic on each one
    --We do this because targets[1] will always be the best target
    --But in case we can't cast anything on the primary target it will fall back to the next target
    for i = 1, #targets do
        local target = targets[i]
        --Check if the target is valid otherwise skip it
        if not (target and target.is_valid and target:is_valid()) then
            goto continue
        end

        --If the target is immune to magical damage, skip it
        if target:is_damage_immune(target.DMG.MAGICAL) then
            goto continue
        end

        --If the target is in a CC that breaks from damage, skip it
        if target:is_cc_weak() then
            goto continue
        end

        --Get number of enemies that are within splash range (radius + bounding) of the target in AOE_RADIUS
        --If you need more advanced logic and need access the enemies
        --you can use get_enemies_in_splash_range_count instead
        --local total_enemies_around_target = target:get_enemies_in_splash_range_count(AOE_RADIUS)

        -- [[AOE LOGIC]]

        if is_aoe(target) then
            --Meteor Logic - Highest priority AOE spell (cast on cooldown, but sync with Combustion)
            --Check Combustion cooldown to decide if we should hold Meteor
            local combustion_cd_remaining = SPELLS.COMBUSTION:cooldown_remains()
            local should_hold_meteor = combustion_cd_remaining > 0 and combustion_cd_remaining <= 10

            --Cast Meteor if we shouldn't hold it (either Combustion is ready or more than 10s away)
            if not should_hold_meteor then
                if SPELLS.METEOR:cast_safe(target, "AoE: Meteor",
                        {
                            --Use spell prediction for ground targeting
                            use_prediction  = true,
                            --Target the position with most hits
                            prediction_type = "MOST_HITS",
                            --Meteor is a circle AoE
                            geometry        = "CIRCLE",
                            --Meteor has an 8 yard radius (same as flamestrike)
                            aoe_radius      = 8,
                            --Minimum 2 targets for AoE value
                            min_hits        = 2,
                            --Cast time is instant
                            cast_time       = 0,
                            --Can cast while moving
                            skip_moving     = true,
                            --Ensure we have LoS
                            check_los       = false,
                        })
                then
                    --We have queued / casted a spell we should now return
                    --to rerun the logic to get the next priority spell
                    return
                end
            end

            --Check if flamestrike is instant by getting if the player has hot streak or hyperthermia buff
            local is_flamestrike_instant = me:buff_up(buffs.HOT_STREAK) or me:buff_up(buffs.HYPERTHERMIA)

            --Only cast flamestrike when it is instant
            if is_flamestrike_instant then
                --Cast flamestrike at the most hits location
                if SPELLS.FLAMESTRIKE:cast_safe(target, "AoE: Flamestrike",
                        {
                            --Spell prediction is used by default for ground spells
                            --I am manually setting options to show that you can tweak the default behavior
                            --IZI should have default prediction options for most AoE spells, however,
                            --to get the most of your class you should tweak these values to fit your usage
                            --Use spell prediction (Default: True)
                            use_prediction  = true,
                            --Spell prediction type
                            prediction_type = "MOST_HITS",
                            --Geometry type (shape of the ground spell)
                            geometry        = "CIRCLE",
                            --Radius of the circle
                            aoe_radius      = 8,
                            --Minimum number of hits required for the spell to be cast
                            --(You could make this more advanced and calculate a min % of total enemies)
                            min_hits        = 2,
                            --Cast time is instant if we have hot streak otherwise izi will look it up
                            cast_time       = is_flamestrike_instant and 0 or nil,
                            --Cast while moving if we have hot streak up
                            skip_moving     = is_flamestrike_instant,
                            --Ensure we have LoS
                            --(changing to false as at the time of writing this it was not working)
                            check_los       = false,
                        })
                then
                    --We have queued / casted a spell we should now return
                    --to rerun the logic to get the next priority spell
                    return
                end
            end

            --...Add more AoE logic
            --(above and below flamestrike depending on order / priority of your class rotation)
        end

        --Combustion logic - cast when keybind is toggled and spell is ready
        if menu.combustion_key:get_toggle_state() then
            if SPELLS.COMBUSTION:cast_safe(me, "Cooldown: Combustion", { cast_time = 0, skip_moving = true }) then
                return
            end
        end
        
        --[[SINGLE TARGET LOGIC]]

        -- Pyroblast logic
        --Check if we have the hot streak buff for a free instant cast pyroblast
        --If we do, cast pyroblast
        if me:buff_up(buffs.HOT_STREAK) or me:buff_up(buffs.HYPERTHERMIA) then
            if SPELLS.PYROBLAST:cast_safe(target, "Single Target: Pyroblast",
                    {
                        --Cast time is instant with hot streak
                        cast_time   = 0,
                        --Skip moving check because it is instant
                        skip_moving = true,
                    })
            then
                --We have queued / casted a spell we should now return
                --to rerun the logic to get the next priority spell
                return
            end
        end

        -- Scorch Logic with the Heat Shimmer bufffire blast will generate our next hot streak
        if me:buff_up(buffs.HEAT_SHIMMER) and me:buff_up(buffs.HEATING_UP) and not me:buff_up(buffs.HYPERTHERMIA) then
            if SPELLS.SCORCH:cast_safe(target, "Single Target: Scorch (Heat Shimmer)",
                    {
                        --Cast time is instant with heat shimmer
                        cast_time   = 0,
                        --Skip moving check because it is instant
                        skip_moving = true,
                    })
            then
                --We have queued / casted a spell we should now return
                --to rerun the logic to get the next priority spell
                return
            end
        end

        -- Scorch when moving logic
        if me:is_moving() and not me:buff_up(buffs.HOT_STREAK) and not me:buff_up(buffs.HYPERTHERMIA) then
            if SPELLS.SCORCH:cast_safe(target, "Single Target: Scorch (Moving)",
                    {
                        --Cast while moving
                        skip_moving = true,
                    })
            then
                --We have queued / casted a spell we should now return
                --to rerun the logic to get the next priority spell
                return
            end
        end

        -- Fire Blast logic - checked first so it can be cast while casting other spells
        if me:buff_up(buffs.HEATING_UP) and not me:buff_up(buffs.HEAT_SHIMMER) and not me:buff_up(buffs.HYPERTHERMIA) then
            if SPELLS.FIREBLAST:cast_safe(target, "Single Target: Fire Blast",
                    {
                        skip_gcd     = true,
                        -- cast while another spell is being cast (for the heating up proc while casting fireball)
                        skip_casting = true,
                        --Cast time is instant with heating up
                        cast_time    = 0,
                        --Skip moving check because it is instant
                        skip_moving  = true,
                    })
            then
                --We have queued / casted a spell we should now return
                --to rerun the logic to get the next priority spell
                return
            end
        end

        -- Pyroclasm Hardcast Pyroblast logic
        --Check if we have Pyroclasm stacks for a guaranteed critical strike hardcast pyroblast
        --Pyroclasm can have up to 2 stacks, so we cast once per stack
        --Only cast when not in Hyperthermia or Combustion (save for Hot Streak procs during those windows)
        if pyroclasm_stacks > 0 and not me:buff_up(buffs.HYPERTHERMIA) and not me:buff_up(buffs.COMBUSTION) then
            if not is_aoe(target) then
                if SPELLS.PYROBLAST:cast_safe(target, "Single Target: Pyroblast (Pyroclasm Hardcast)") then
                    --Track consumed stack to prevent double-casting before buff updates
                    consumed_pyroclasm_stacks = consumed_pyroclasm_stacks + 1
                    --We have queued / casted a spell we should now return
                    --to rerun the logic to get the next priority spell
                    return
                end
            else
                --If we have pyroclasm but we are in an AoE situation we want to use it on flamestrike for maximum value
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

        --Cast fireball
        if SPELLS.FIREBALL:cast_safe(target, "Single Target: Fireball") then
            --We have queued / casted a spell we should now return
            --to rerun the logic to get the next priority spell
            return
        end

        --...Add more single target logic
        --(above and below fireball depending on order / priority of your class rotation)

        --Define our continue label for continuing to the next target
        ::continue::
    end
end)
