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
local function set_quickbar_cache(player)
	_quickbar_cache = {}

	-- Factorio seems to have a hard limit of 10 quickbars.
	for i = 1, 100 do
		local quickbar_item_prototype = player.get_quick_bar_slot(i)
		if (
					quickbar_item_prototype
					and not thing_is_in_list(quickbar_item_prototype.name, _quickbar_cache)
				)
		then
			table.insert(_quickbar_cache, quickbar_item_prototype.name)
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
				table.insert(_placeable_item_prototypes_sorted, k)
			end
		end
	end

	return _placeable_item_prototypes_sorted
end

local function get_hard_stop_index(inventory)
	local stop_filters = { "raw-fish", "deconstruction-planner" }
	-- Fish or Deco Planner indicates a hard stop point.
	-- >> This is to preserve the player-defined filters

	for i = 1, #inventory do
		local filter = inventory.get_filter(i)
		if (filter)
		then
			local filter_item = filter.name or filter
			if (thing_is_in_list(filter_item, stop_filters))
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

	-- inventory contents here is an array of https://lua-api.factorio.com/latest/concepts/ItemCountWithQuality.html
	local inventory_contents = inventory.get_contents()


	-- put together a quick reference table
	local items_in_inventory = {}
	for _, content in ipairs(inventory_contents) do
		if (not items_in_inventory[content.name])
		then
			items_in_inventory[content.name] = {}
		end

		table.insert(items_in_inventory[content.name], { count = content.count, quality = content.quality })
	end



	local lua_inventory_content_example = {
		-- type: ItemCountWIthQuality
		name = "",
		count = 0, -- uint
		quality = {} -- QualityID, which is either a string or a:
		-- https://lua-api.factorio.com/latest/classes/LuaQualityPrototype.html
	}


	-- I also don't want to set placeable filters for
	-- ... items which the player already set a filter for
	-- ... in their inventory.
	-- Loop through protected inventory area to discover
	-- ... player-set filters
	-- https://lua-api.factorio.com/latest/concepts/ItemFilter.html
	-- these include quality notation
	local player_defined_filters = {}
	for i = hard_stop_index + 1, #inventory do
		local filter = inventory.get_filter(i)
		-- going to be quality-agnostic with player defined filters.
		-- >> it's much easier for me and probably not worth the effort.
		if (filter and not thing_is_in_list(filter.name, player_defined_filters))
		then
			table.insert(player_defined_filters, filter.name)
		end
	end

	-- filter inventory contents to just get placeables

	-- By iterating over the sorted list, items should be set in
	-- ... the placeable table in the correct order.
	local quickbar_cache = get_quickbar_cache(player)
	local game_item_prototypes = prototypes.item
	local placeable_item_prototype_names = get_placeable_item_prototypes_sorted()
	local PLAYER_MAX_FILTERS_PER_ITEM = player.mod_settings["InventoryPlaceables-max-slots-filtered-per-item"].value

	local filters_to_set = {}
	for _, item in ipairs(placeable_item_prototype_names) do
		if (items_in_inventory[item])
		then
			local item_is_in_excluded_lists = thing_is_in_list(item, quickbar_cache) or
					thing_is_in_list(item, player_defined_filters)

			if (not item_is_in_excluded_lists)
			then
				local stack_size = game_item_prototypes[item].stack_size

				-- This step makes sure all quality versions are accounted for
				for _, count_and_quality in ipairs(items_in_inventory[item]) do
					local filter = { name = item, quality = count_and_quality.quality }
					local slots_needed = math.min(PLAYER_MAX_FILTERS_PER_ITEM, math.ceil(count_and_quality.count / stack_size))
					for i = 1, slots_needed do
						table.insert(filters_to_set, filter)
					end
				end
			end
		end
	end


	-- Set Inventory Filters
	local slots_filtered = #filters_to_set
	local inventory_has_space_for_sorting = (inventory.count_empty_stacks() >= slots_filtered)

	-- CLEARING FILTERS WHEN YOU CAN'T SORT
	if (not inventory_has_space_for_sorting)
	then
		for i = 1, hard_stop_index - 1 do
			inventory.set_filter(i, nil)
		end

		inventory.sort_and_merge()
		return
	end

	-- SETTING FILTERS
	for i = 1, hard_stop_index - 1 do
		inventory.set_filter(i, filters_to_set[i])
	end

	-- Iterate through all filtered slots:
	-- >> look for pairs of mismatched item/filters that can be swapped.
	-- >> If no swap, note the item and location (to be moved around later)


	-- Object for future use, to model and manage logical side of custom sort.
	-- local inventory_object = {
	-- 	mismatched_filters = {
	-- 		[1] = { filter = "", item = "" }
	-- 	}
	-- }

	-- Moving items out of filtered slots to the empty slots, so that sort_and_merge can work properly
	local empty_slot_indices = {}
	local empty_slot_iterator = slots_filtered + 1
	while ((#empty_slot_indices < slots_filtered) and (empty_slot_iterator <= #inventory)) do
		local filter = inventory.get_filter(empty_slot_iterator)
		local slot_is_empty_and_unfiltered = not (filter or inventory[empty_slot_iterator].valid_for_read)
		if (slot_is_empty_and_unfiltered)
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
