local _fish_or_decon = "[item=raw-fish] / [item=deconstruction-planner]"
local _mod_usage_message_locale = {
  ["en"] = "[InventoryPlaceables] Set an inventory filter using " .. _fish_or_decon .. " to enable mod functions.",
}

local first_inventory_check_has_happened = false
local function no_hard_stop_filter_message(player)
  if (not first_inventory_check_has_happened)
  then
    first_inventory_check_has_happened = true
    local msg = _mod_usage_message_locale[player.locale]
    if (msg == nil) then msg = _mod_usage_message_locale["en"] end
    player.print(msg)
  end
end

-- ===================================

-- Had to pull these two bits of logic into their own functions,
-- ... because needing to check the table for first key every time gets lengthy
local function add_to_two_tier_lookup(table, first, second, val_or_true)
  if (not table[first]) then table[first] = {} end
  table[first][second] = (val_or_true or true)
end
local function check_two_tier_lookup(table, first, second, val_or_true)
  if (not table[first]) then return false end
  return table[first][second] == (val_or_true or true)
end
local function get_two_tier_lookup_value(table, first, second)
  if (not table[first]) then return nil end
  return table[first][second]
end


-- Even when the quality mod is disabled, items have "normal" quality.
-- > that is to say, it never seems to be "nil"
local function get_quality(proto_with_quality_field)
  local quality = proto_with_quality_field.quality
  return quality.name or quality
end


local _quickbar_cache = nil
local function set_quickbar_cache(player)
  _quickbar_cache = {}

  -- Factorio seems to have a hard limit of 10 quickbars.
  for i = 1, 100 do
    -- https://lua-api.factorio.com/latest/concepts/ItemFilter.html
    local quickbar_item_filter = player.get_quick_bar_slot(i)
    if (quickbar_item_filter)
    then
      add_to_two_tier_lookup(
        _quickbar_cache, quickbar_item_filter.name,
        get_quality(quickbar_item_filter)
      )
    end
  end
end
local function get_quickbar_cache(player)
  if (not _quickbar_cache)
  then
    set_quickbar_cache(player)
  end

  return _quickbar_cache
end
script.on_event(defines.events.on_player_set_quick_bar_slot, function(event)
  set_quickbar_cache(game.players[event.player_index])
end)


local function ItemCanBePlaced(item_prototype)
  if (item_prototype.place_result) then return true end
  if (item_prototype.place_as_tile_result) then return true end

  -- Modules are a good exception to include
  if (item_prototype.type == "module") then return true end

  -- Everything else, nope!
  return false
end


local function get_hard_stop_index(inventory)
  -- Fish or Deco Planner indicates a hard stop point.
  -- >> This is to preserve the player-defined filters
  local stop_filters = {
    ["raw-fish"] = true,
    ["deconstruction-planner"] = true
  }

  for i = 1, #inventory do
    local filter = inventory.get_filter(i)
    if (filter)
    then
      local filter_item = filter.name or filter
      if (stop_filters[filter_item])
      then
        return i
      end
    end
  end

  -- Being explicit about the index not being found is good.
  return nil
end

-- Main Logic
script.on_event(defines.events.on_gui_opened, function(event)
  -- https://lua-api.factorio.com/latest/defines.html#defines.gui_type
  local player_inventory_opened = (event.gui_type == 3)
  if (not player_inventory_opened) then return end

  -- LuaPlayer inherits LuaControl. Use that to get inventory.
  -- https://lua-api.factorio.com/latest/classes/LuaControl.html#get_main_inventory
  local player = game.players[event.player_index]
  local inventory = player.get_main_inventory()

  -- Relevant for 2.0 Remote View
  if (inventory == nil) then return end

  -- Mod should not set filters at/past this point. Protects player filters at bottom.
  -- Mod does not run if it is not found. Protects inventory filters when installed midgame.
  -- Will inform player how to use mod only once per load cycle
  local hard_stop_index = get_hard_stop_index(inventory)
  if (not hard_stop_index)
  then
    no_hard_stop_filter_message(player)
    return
  end

  -- Block player-set inventory filters
  -- > same steps as "set_quickbar_cache()"
  local player_defined_filters = {}
  for i = hard_stop_index + 1, #inventory do
    local filter = inventory.get_filter(i)
    if (filter)
    then
      add_to_two_tier_lookup(
        player_defined_filters, filter.name,
        get_quality(filter)
      )
    end
  end

  -- Get lists of things to not make filters for
  local local_quickbar_cache = get_quickbar_cache(player)
  local inventory_items_qual_stacks = {}

  -- inventory contents here is an array of https://lua-api.factorio.com/2.0.24/concepts/ItemWithQualityCounts.html
  local inventory_contents = inventory.get_contents()
  local PLAYER_MAX_FILTERS_PER_ITEM = player.mod_settings["InventoryPlaceables-max-slots-filtered-per-item"].value
  local total_filters_to_set = 0

  for _, item in ipairs(inventory_contents) do
    local name = item.name
    local quality = get_quality(item)
    local item_prototype = prototypes.item[name]

    local item_is_excluded = (
      check_two_tier_lookup(local_quickbar_cache, name, quality)
      or check_two_tier_lookup(player_defined_filters, name, quality)
      or not ItemCanBePlaced(item_prototype)
    )

    if (not item_is_excluded)
    then
      local stacks = math.min(PLAYER_MAX_FILTERS_PER_ITEM, math.ceil(item.count / item_prototype.stack_size))

      add_to_two_tier_lookup(
        inventory_items_qual_stacks,
        name,
        quality,
        stacks
      )

      total_filters_to_set = total_filters_to_set + stacks
    end
  end

  -- Return to normal inventory state when there's too many things to highlight.
  local inventory_has_space_for_sorting = total_filters_to_set < hard_stop_index
  if (not inventory_has_space_for_sorting)
  then
    -- Setting this to 0 will clear all mod-area filters in following loop.
    total_filters_to_set = 0
  else
    -- data structure setup for recording item positions
    local item_qual_locations = {}
    for name, qual_stacks in pairs(inventory_items_qual_stacks) do
      item_qual_locations[name] = {}
      for qual, _ in pairs(qual_stacks) do
        item_qual_locations[name][qual] = {}
      end
    end
    for i = 1, #inventory do
      if (inventory[i].valid_for_read)
      then
        local item_name = inventory[i].name
        local item_quality = get_quality(inventory[i])
        if (get_two_tier_lookup_value(item_qual_locations, item_name, item_quality))
        then
          table.insert(item_qual_locations[item_name][item_quality], i)
        end
      end
    end

    -- Now that data is constructed, iterate through the filters that need to be set.
    -- > just grab the first appropriate item from it's recorded place when doing so.
    local next_filter_index_to_set = 1
    for name, qual_stacks in pairs(inventory_items_qual_stacks) do
      for qual, stacks in pairs(qual_stacks) do
        local filter = { name = name, quality = qual }
        for i = 1, stacks do
          -- just shunt it out first? and then check after if the thing you moved was tracked elsewhere
          local swap_from = table.remove(item_qual_locations[name][qual])
          inventory.set_filter(next_filter_index_to_set, filter)
          inventory[swap_from].swap_stack(inventory[next_filter_index_to_set])

          -- now check if you need to keep track of the thing you moved
          if (inventory[swap_from].valid_for_read)
          then
            local swapped_name = inventory[swap_from].name
            local swapped_qual = get_quality(inventory[swap_from])
            local array = get_two_tier_lookup_value(item_qual_locations, swapped_name, swapped_qual)
            if (array)
            then
              for _, index in ipairs(array) do
                if (index == next_filter_index_to_set)
                then
                  array[i] = swap_from
                end
              end
            end
          end

          -- now safe to increment to next filter index
          next_filter_index_to_set = next_filter_index_to_set + 1
        end
      end
    end
  end

  -- clear filters from remaining pre-fish slots
  for i = total_filters_to_set + 1, hard_stop_index - 1 do
    inventory.set_filter(i, nil)
  end

  -- And apply normal sort to clean up everything else.
  inventory.sort_and_merge()
end)
