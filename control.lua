
local function thing_is_in_list(thing, list_things)
  for _, thing_from_list in ipairs(list_things) do
    if (thing == thing_from_list)
    then
      return true
    end
  end
  return false
end


local _quickbar_cache = nil
local function set_quickbar_cache(event)
  _quickbar_cache = {}

  -- Factorio seems to have a hard limit of 10 quickbars.
  local player = game.players[event.player_index]
  for i = 1, 100 do
    local quickbar_item_prototype = player.get_quick_bar_slot(i)
    if (quickbar_item_prototype)
    then
      local quickbar_item_name = quickbar_item_prototype.name
      if (thing_is_in_list(quickbar_item_name, _quickbar_cache))
      then
        goto go_if_duplicate
      end

      table.insert(_quickbar_cache, quickbar_item_name)
      
      ::go_if_duplicate::
    end
  end 
end
local function get_quickbar_cache(event)
  if (not _quickbar_cache)
  then
    set_quickbar_cache(event)
  end

  return _quickbar_cache
end
script.on_event(defines.events.on_player_set_quick_bar_slot, function(event)
  set_quickbar_cache(event)
end)


local function ItemCanBePlaced(item_prototype)
  if (item_prototype.place_result) then return true end
  if (item_prototype.place_as_tile_result) then return true end
  
  -- Modules and Wires are good exceptions to include
  if (item_prototype.type == "module") then return true end
  local item_is_logic_wire = ((item_prototype.name == "red-wire") or (item_prototype.name == "green-wire"))
  if (item_is_logic_wire) then return true end

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
    for k, v in pairs(game.item_prototypes) do
      if (ItemCanBePlaced(v))
      then
        table.insert(_placeable_item_prototypes_sorted, k)
      end
    end
  end
  
  return _placeable_item_prototypes_sorted
end

local function get_hard_stop_index(inventory)
  local stop_filters = {"raw-fish", "deconstruction-planner"}
  -- Fish or Deco Planner indicates a hard stop point.
  -- >> This is to preserve the player-defined filters

  for i = 1, #inventory do
    local filter = inventory.get_filter(i)
    if (filter and thing_is_in_list(filter, stop_filters))
    then
      return i
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

  
  -- This index is where to stop setting filters automagically at.
  -- >> everything before it is free reign, everything after it
  -- ... is protected, even if filters are not set there.
  -- We return if no hard stop index is present, because
  -- ... otherwise the mod can run on a mature inventory 
  -- ... with filters (installed midgame), and would be rather
  -- ... destructive, which is obviously bad.
  -- THEREFORE, mod should not run when a safe area is not defined
  -- ... in the user's inventory.
  local hard_stop_index = get_hard_stop_index(inventory)
  if (not hard_stop_index) then return end


  -- https://lua-api.factorio.com/latest/classes/LuaInventory.html#get_contents
  local inventory_contents = inventory.get_contents()



  -- Hand slot doesn't get counted as inventory.
  -- >> Can just add it to the contents table
  -- LuaControl.cursor_stack == LuaItemStack (can be nil) == hand contents
  if (player.cursor_stack.valid_for_read)
  then
    local name = player.cursor_stack.name
    if (not inventory_contents[name])
    then
      inventory_contents[name] = 0
    end

    local count = player.cursor_stack.count
    inventory_contents[name] = inventory_contents[name] + count
  end



  -- I also don't want to set placeable filters for
  -- ... items which the player already set a filter for
  -- ... in their inventory.
  -- Loop through protected inventory area to discover
  -- ... player-set filters
  local player_defined_filters = {}
  for i = hard_stop_index + 1, #inventory do
    local filter = inventory.get_filter(i)
    if (filter and not thing_is_in_list(filter, player_defined_filters))
    then
      table.insert(player_defined_filters, filter)
    end
  end

  -- filter inventory contents to just get placeables

  -- By iterating over the sorted list, items should be set in
  -- ... the placeable table in the correct order.
  local quickbar_cache = get_quickbar_cache(event)
  local game_item_prototypes = game.item_prototypes
  local placeable_item_prototypes_sorted = get_placeable_item_prototypes_sorted()

  local filters_to_set = {}
  for _, item in ipairs(placeable_item_prototypes_sorted) do
    if (inventory_contents[item])
    then
      local item_is_in_excluded_lists = thing_is_in_list(item, quickbar_cache) or thing_is_in_list(item, player_defined_filters)

      if (not item_is_in_excluded_lists)
      then
        local slots_needed = math.ceil(inventory_contents[item] / game_item_prototypes[item].stack_size)

        for i = 1, slots_needed do
          table.insert(filters_to_set, item)
        end
      end
    end
  end

  
  -- Set Inventory Filters
  local slots_filtered = #filters_to_set
  local inventory_has_space_for_sorting = (inventory.count_empty_stacks() >= slots_filtered)

  -- If you can't sort appropriately, then clear any existing filters.
  -- >> This is so the mod is not a nuisance when dealing with a full inventory.
  if (not inventory_has_space_for_sorting)
  then
    for i = 1, hard_stop_index - 1 do
      inventory.set_filter(i, nil)
    end

    inventory.sort_and_merge()
    return
  end

  -- Set Filters for inventory that can be sorted after
  for i = 1, hard_stop_index - 1 do
    inventory.set_filter(i, filters_to_set[i])
  end

  -- Doing Custom Sort / Moving Items Into Filtered Slots (beacuse there is space for it)
  local empty_slot_indices = {}
  local empty_slot_iterator = slots_filtered + 1
  while ((#empty_slot_indices < slots_filtered) and (empty_slot_iterator <= #inventory)) do

    local filter = inventory.get_filter(empty_slot_iterator)
    if (not inventory[empty_slot_iterator].valid_for_read and not filter)
    then
      table.insert(empty_slot_indices, empty_slot_iterator)
    end

    empty_slot_iterator = empty_slot_iterator + 1
  end


  for i = 1, slots_filtered do
    inventory[i].swap_stack(inventory[empty_slot_indices[i]])
  end
  
  inventory.sort_and_merge()
  



  -- LuaInventory.sort_and_merge() isn't very smart with filtered slots.
  -- inventory.sort_and_merge()

  
  
  

  -- There is (almost definitely) a solution to this which only requires 1 empty
  -- ... slot to swap stacks into/between. The limitation that
  -- ... you can't put the wrong item in a filtered slot is tough.
  -- >> That solution will take a lot of brainpower. 
  -- ... Simplest solution is to require as much empty space as 
  -- ... there are filtered slots. Then throw each stack occupying
  -- ... a filtered spot into an empty one, then sort and merge as normal


  -- -- ==============================================
  -- for i = 1, slots_filtered do
  --   -- I want to put the correct item in this slot.
  --   -- ... if it is not already here.   

  --   local filter_i = inventory.get_filter(i)
  --   if (not (filter_i == inventory[i].name))
  --   then
  --     -- not in the right spot. need to shift things around.
  --     -- 1. Find where this item actually is in the inventory.
  --     -- 2. use the empty slot to swap the item locations

  --     for j = i + 1, #inventory do
  --       if (filter_i == (inventory[j].valid_for_read and inventory[j].name))
  --       then
  --         -- found it! time to swap
  --         local swap_success = inventory[i].swap_stack(inventory[j])
  --         local y_n = swap_success and "yes" or "no"
  --         game.print("Swap Attempt. Slot " .. i .. " [" .. inventory[i].name .. "]" .. " and Slot " .. j  .. " [" .. inventory[j].name .. "]" .. ". Result: " .. y_n .. ".")

  --         goto swap_item_slots_exit_early
  --       end
  --     end
  --     ::swap_item_slots_exit_early::

  --   end
  -- end
  -- inventory.sort_and_merge()
  -- -- ==============================================
end)