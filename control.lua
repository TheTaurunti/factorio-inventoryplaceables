local _fish_or_decon = "[item=raw-fish] / [item=deconstruction-planner]"
local _mod_usage_message_locale = {
  ["en"] = "[InventoryPlaceables] Set an inventory filter using " .. _fish_or_decon .. " to enable mod functions.",
}

local first_inventory_check_has_happened = false
local function no_hard_stop_filter_message(player)
  local msg = _mod_usage_message_locale[player.locale]
  if (msg == nil) then msg = _mod_usage_message_locale["en"] end
  player.print(msg)
  player.print({ "mod-name.InventoryPlaceables" })
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


-- Just need to compile this information once
local _placeable_item_prototypes_sorted = nil
local function get_placeable_item_prototypes_sorted()
  if (_placeable_item_prototypes_sorted == nil)
  then
    _placeable_item_prototypes_sorted = {}
    -- k == name, v == prototype
    for k, v in pairs(prototypes.item) do
      if (ItemCanBePlaced(v))
      then
        table.insert(_placeable_item_prototypes_sorted, v)
      end
    end
  end

  return _placeable_item_prototypes_sorted
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
    if (not first_inventory_check_has_happened)
    then
      first_inventory_check_has_happened = true
      no_hard_stop_filter_message(player)
    end
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

  -- put together a quick reference table
  local inventory_items_qual_data = {}

  -- inventory contents here is an array of https://lua-api.factorio.com/2.0.24/concepts/ItemWithQualityCounts.html
  local inventory_contents = inventory.get_contents()
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
      add_to_two_tier_lookup(
        inventory_items_qual_data,
        name,
        quality,
        {
          stacks = math.ceil(item.count / item_prototype.stack_size),

          -- these two used while swapping items
          start_index = nil,
          filters_set = 0
        }
      )
    end
  end

  -- local lua_inventory_content_example = {
  --   -- type: ItemCountWithQuality
  --   name = "",
  --   count = 0,   -- uint
  --   quality = {} -- QualityID, which is either a string or a:
  --   -- https://lua-api.factorio.com/latest/classes/LuaQualityPrototype.html
  -- }


  -- By iterating over the sorted list, items should be set in
  -- ... the placeable table in the correct order.
  local placeable_item_prototypes = get_placeable_item_prototypes_sorted()
  local PLAYER_MAX_FILTERS_PER_ITEM = player.mod_settings["InventoryPlaceables-max-slots-filtered-per-item"].value

  -- Final step uses this: highlights placeables using filters.
  local total_filters_to_set = 0
  local next_start_filter_index = 1

  -- The outer loop (placeable prototypes) is just to maintain the default sorting order that factorio uses.
  for _, item in ipairs(placeable_item_prototypes) do
    -- Only working with items that are actually in the inventory
    if (inventory_items_qual_data[item.name])
    then
      -- add data for each quality level permutation of the item
      for quality, data in pairs(inventory_items_qual_data[item.name]) do
        data.start_index = next_start_filter_index

        local slots_needed = math.min(PLAYER_MAX_FILTERS_PER_ITEM, data.stacks)

        next_start_filter_index = next_start_filter_index + slots_needed
        total_filters_to_set = total_filters_to_set + slots_needed
      end
    end
  end

  -- ================================   -- ================================
  -- HERE: Time to smartify things. Move items BEFORE setting fitlers.
  -- ================================   -- ================================

  -- Return to normal inventory state when there's too many things to highlight.
  local inventory_has_space_for_sorting = total_filters_to_set < hard_stop_index
  if (not inventory_has_space_for_sorting)
  then
    -- Setting this to 0 will clear all mod-area filters in following loop.
    total_filters_to_set = 0
  else
    -- Iterate through inventory slots, moving items / setting filters as needed.
    -- > Don't need special logic to exit early or exclude slots. Cases such as that...
    -- ... are handled implicitly based on data collected thus far.
    local inventory_slots_already_swapped_into = {}
    for i = 1, #inventory do
      local swapped_here = inventory_slots_already_swapped_into[i]
      local read_valid = inventory[i].valid_for_read
      if (not swapped_here and read_valid)
      then
        -- https://lua-api.factorio.com/2.0.24/classes/LuaInventory.html#index_operator
        -- use field of return val: https://lua-api.factorio.com/2.0.24/classes/LuaItemStack.html
        local item_stack = inventory[i]
        local item_quality = get_quality(item_stack)

        -- Nil value means the item doesn't need filters or swaps into correct place.
        local swap_filter_data = get_two_tier_lookup_value(inventory_items_qual_data, item_stack.name, item_quality)
        if (swap_filter_data)
        then
          -- find target index
          local target_index = swap_filter_data.start_index + swap_filter_data.filters_set
          swap_filter_data.filters_set = swap_filter_data.filters_set + 1

          inventory.set_filter(target_index, { name = item_stack.name, quality = item_quality })
          inventory_slots_already_swapped_into[target_index] = true

          -- Handles the swap itself, if needed.
          if (target_index == i)
          then
            -- ???
          else
            -- Prevents errors if trying to swap target/source item into previously-filtered slots.
            inventory.set_filter(i, nil)
            inventory[i].swap_stack(inventory[target_index])

            -- will need to check this slot again, something new is here.
            i = i - 1
          end
        end
      else
        if (i < hard_stop_index)
        then
          player.print("skipped" ..
            i .. "|| swapped: " .. tostring(swapped_here) .. ", readValid: " .. tostring(read_valid))
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

  -- ================================   -- ================================

  -- Testing needed: item in hand slot? what happens when assigning there? swapping there?

  -- ================================   -- ================================
end)
