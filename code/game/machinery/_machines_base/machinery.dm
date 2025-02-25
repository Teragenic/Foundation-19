/*
Overview:
   Used to create objects that need a per step proc call.  Default definition of 'New()'
   stores a reference to src machine in global 'machines list'.  Default definition
   of 'Destroy' removes reference to src machine in global 'machines list'.

Class Variables:
   use_power (num)
	  current state of auto power use.
	  Possible Values:
		 0 -- no auto power use
		 1 -- machine is using power at its idle power level
		 2 -- machine is using power at its active power level

   active_power_usage (num)
	  Value for the amount of power to use when in active power mode

   idle_power_usage (num)
	  Value for the amount of power to use when in idle power mode

   power_channel (num)
	  What channel to draw from when drawing power for power mode
	  Possible Values:
		 EQUIP:1 -- Equipment Channel
		 LIGHT:2 -- Lighting Channel
		 ENVIRON:3 -- Environment Channel

   component_parts (list)
	  A list of component parts of machine used by frame based machines.

   panel_open (num)
	  Whether the panel is open

   uid (num)
	  Unique id of machine across all machines.

   gl_uid (global num)
	  Next uid value in sequence

   stat (bitflag)
	  Machine status bit flags.
	  Possible bit flags:
		 BROKEN:1 -- Machine is broken
		 NOPOWER:2 -- No power is being supplied to machine.
		 MAINT:8 -- machine is currently under going maintenance.
		 EMPED:16 -- temporary broken by EMP pulse

Class Procs:
   New()					 'game/machinery/machine.dm'

   Destroy()					 'game/machinery/machine.dm'

   powered(chan = EQUIP)		 'modules/power/power_usage.dm'
	  Checks to see if area that contains the object has power available for power
	  channel given in 'chan'.

   use_power_oneoff(amount, chan=power_channel)   'modules/power/power_usage.dm'
	  Deducts 'amount' from the power channel 'chan' of the area that contains the object.
	  This is not a continuous draw, but rather will be cleared after one APC update.

   power_change()			   'modules/power/power_usage.dm'
	  Called by the area that contains the object when ever that area under goes a
	  power state change (area runs out of power, or area channel is turned off).

   RefreshParts()			   'game/machinery/machine.dm'
	  Called to refresh the variables in the machine that are contributed to by parts
	  contained in the component_parts list. (example: glass and material amounts for
	  the autolathe)

	  Default definition does nothing.

   Process()				  'game/machinery/machine.dm'
	  Called by the 'master_controller' once per game tick for each machine that is listed in the 'machines' list.


	Compiled by Aygar
*/

/obj/machinery
	name = "machinery"
	icon = 'icons/obj/stationobjs.dmi'
	w_class = ITEM_SIZE_NO_CONTAINER
	layer = STRUCTURE_LAYER // Layer under items
	init_flags = INIT_MACHINERY_PROCESS_SELF

	var/stat = 0
	var/reason_broken = 0
	var/stat_immune = NOSCREEN | NOINPUT // The machine will never set stat to these flags.
	var/emagged = FALSE
	var/malf_upgraded = 0
	var/datum/wires/wires //wire datum, if any. If you place a type path, it will be autoinitialized.
	var/use_power = POWER_USE_IDLE
		//0 = dont run the auto
		//1 = run auto, use idle
		//2 = run auto, use active
	var/idle_power_usage = 0
	var/active_power_usage = 0
	var/power_channel = EQUIP //EQUIP, ENVIRON or LIGHT
	var/power_init_complete = FALSE // Helps with bookkeeping when initializing atoms. Don't modify.
	var/list/component_parts           //List of component instances. Expected type: /obj/item/stock_parts
	var/list/uncreated_component_parts = list(/obj/item/stock_parts/power/apc) //List of component paths which have delayed init. Indeces = number of components.
	var/list/maximum_component_parts = list(/obj/item/stock_parts = 10)         //null - no max. list(type part = number max).
	var/uid
	var/panel_open = 0
	var/global/gl_uid = 1
	var/interact_offline = 0 // Can the machine be interacted with while de-powered.
	var/clicksound			// sound played on succesful interface use by a carbon lifeform
	var/clickvol = 40		// sound played on succesful interface use
	var/next_clicksound = 0 // value to compare with world.time for whether to play clicksound according to CLICKSOUND_INTERVAL
	var/core_skill = SKILL_DEVICES //The skill used for skill checks for this machine (mostly so subtypes can use different skills).
	var/operator_skill      // Machines often do all operations on Process(). This caches the user's skill while the operations are running.
	var/base_type           // For mapped buildable types, set this to be the base type actually buildable.
	var/id_tag              // This generic variable is to be used by mappers to give related machines a string key. In principle used by radio stock parts.
	var/frame_type = /obj/machinery/constructable_frame/machine_frame/deconstruct // what is created when the machine is dismantled.

	var/list/processing_parts // Component parts queued for processing by the machine. Expected type: /obj/item/stock_parts
	var/processing_flags         // What is being processed
	var/silicon_restriction = FALSE // FALSE or one of the STATUS_* flags. If set, will force the given status flag if a silicon tries to access the machine.

	var/machine_name = null // The human-readable name of this machine, shown when examining circuit boards.
	var/machine_desc = null // A simple description of what this machine does, shown on examine for circuit boards.

/obj/machinery/Initialize(mapload, d=0, populate_parts = TRUE)
	. = ..()
	if(d)
		set_dir(d)
	if (init_flags & INIT_MACHINERY_PROCESS_ALL)
		START_PROCESSING_MACHINE(src, init_flags & INIT_MACHINERY_PROCESS_ALL)
	SSmachines.machinery += src // All machines should remain in this list, always.
	if(ispath(wires))
		wires = new wires(src)
	populate_parts(populate_parts)
	RefreshParts()
	power_change()

/obj/machinery/Destroy()
	if(istype(wires))
		QDEL_NULL(wires)
	SSmachines.machinery -= src
	QDEL_NULL_LIST(component_parts) // Further handling is done via destroyed events.
	STOP_PROCESSING_MACHINE(src, MACHINERY_PROCESS_ALL)
	. = ..()

/obj/machinery/proc/ProcessAll(wait)
	if(processing_flags & MACHINERY_PROCESS_COMPONENTS)
		for(var/thing in processing_parts)
			var/obj/item/stock_parts/part = thing
			if(part.machine_process(src) == PROCESS_KILL)
				part.stop_processing()

	if((processing_flags & MACHINERY_PROCESS_SELF) && Process(wait) == PROCESS_KILL)
		STOP_PROCESSING_MACHINE(src, MACHINERY_PROCESS_SELF)

/obj/machinery/Process()
	return PROCESS_KILL // Only process if you need to.

/obj/machinery/emp_act(severity)
	if(use_power && stat == 0)
		use_power_oneoff(7500/severity)

		var/obj/effect/overlay/pulse2 = new /obj/effect/overlay(loc)
		pulse2.icon = 'icons/effects/effects.dmi'
		pulse2.icon_state = "empdisable"
		pulse2.SetName("emp sparks")
		pulse2.anchored = TRUE
		pulse2.set_dir(pick(GLOB.cardinal))

		spawn(10)
			qdel(pulse2)
	..()

/obj/machinery/ex_act(severity)
	switch(severity)
		if(1.0)
			qdel(src)
		if(2.0)
			if (prob(50))
				qdel(src)
		if(3.0)
			if (prob(25))
				qdel(src)

/obj/machinery/proc/set_broken(new_state, cause = MACHINE_BROKEN_GENERIC)
	if(stat_immune & BROKEN)
		return FALSE
	if(!new_state == !(reason_broken & cause))
		return FALSE
	reason_broken ^= cause

	if(!reason_broken != !(stat & BROKEN))
		stat ^= BROKEN
		queue_icon_update()
		return TRUE

/obj/machinery/proc/set_noscreen(new_state)
	if(stat_immune & NOSCREEN)
		return FALSE
	if(!new_state != !(stat & NOSCREEN))// new state is different from old
		stat ^= NOSCREEN                // so flip it
		return TRUE

/obj/machinery/proc/set_noinput(new_state)
	if(stat_immune & NOINPUT)
		return FALSE
	if(!new_state != !(stat & NOINPUT))
		stat ^= NOINPUT
		return TRUE

/proc/is_operable(obj/machinery/M, mob/user)
	return istype(M) && M.operable()

/obj/machinery/proc/is_broken(additional_flags = 0)
	return (stat & (BROKEN|additional_flags))

/obj/machinery/proc/is_powered(additional_flags = 0)
	return !(stat & (NOPOWER|additional_flags))

/obj/machinery/proc/operable(additional_flags = 0)
	return !inoperable(additional_flags)

/obj/machinery/proc/inoperable(additional_flags = 0)
	return (stat & (NOPOWER|BROKEN|additional_flags))

/obj/machinery/CanUseTopic(mob/user)
	if(stat & BROKEN)
		return STATUS_CLOSE

	if(!interact_offline && (stat & NOPOWER))
		return STATUS_CLOSE

	if(user.direct_machine_interface(src))
		var/mob/living/silicon/silicon = user
		if (silicon_restriction && ismachinerestricted(silicon))
			if (silicon_restriction == STATUS_CLOSE)
				to_chat(user, SPAN_WARNING("Remote AI systems detected. Firewall protections forbid remote AI access."))
			return silicon_restriction

		return ..()

	if(stat & NOSCREEN)
		return STATUS_CLOSE

	if(stat & NOINPUT)
		return min(..(), STATUS_UPDATE)
	return ..()

/mob/proc/direct_machine_interface(obj/machinery/machine)
	return FALSE

/mob/living/silicon/direct_machine_interface(obj/machinery/machine)
	return TRUE

/mob/observer/ghost/direct_machine_interface(obj/machinery/machine)
	return TRUE

/obj/machinery/CanUseTopicPhysical(mob/user)
	if(stat & BROKEN)
		return STATUS_CLOSE

	return GLOB.physical_state.can_use_topic(nano_host(), user)

/obj/machinery/CouldUseTopic(mob/user)
	..()
	user.set_machine(src)

/obj/machinery/CouldNotUseTopic(mob/user)
	user.unset_machine()

/obj/machinery/Topic(href, href_list, datum/topic_state/state)
	if(href_list["mechanics_text"] && construct_state) // This is an OOC examine thing handled via Topic; specifically bypass all checks, but do nothing other than message to chat.
		var/list/info = construct_state.mechanics_info()
		if(info)
			to_chat(usr, jointext(info, "<br>"))
			return TOPIC_HANDLED

	. = ..()
	if(. == TOPIC_REFRESH)
		updateUsrDialog() // Update legacy UIs to the extent possible.

////////////////////////////////////////////////////////////////////////////////////////////

/obj/machinery/attack_ai(mob/user)
	if(CanUseTopic(user, DefaultTopicState()) > STATUS_CLOSE)
		return interface_interact(user)

/obj/machinery/attack_robot(mob/user)
	if((. = attack_hand(user))) // This will make a physical proximity check, and allow them to deal with components and such.
		return
	if(CanUseTopic(user, DefaultTopicState()) > STATUS_CLOSE)
		return interface_interact(user) // This may still work even if the physical checks fail.

// After a recent rework this should mostly be safe.
/obj/machinery/attack_ghost(mob/user)
	interface_interact(user)

// If you don't call parent in this proc, you must make all appropriate checks yourself.
// If you do, you must respect the return value.
/obj/machinery/attack_hand(mob/user)
	if((. = ..())) // Buckling, climbers; unlikely to return true.
		return
	if(MUTATION_FERAL in user.mutations)
		user.setClickCooldown(DEFAULT_ATTACK_COOLDOWN*2)
		attack_generic(user, 10, "smashes")
		return TRUE
	if(!CanPhysicallyInteract(user))
		return FALSE // The interactions below all assume physical access to the machine. If this is not the case, we let the machine take further action.
	if(!user.IsAdvancedToolUser())
		to_chat(user, SPAN_WARNING("You don't have the dexterity to do this!"))
		return TRUE
	if(ishuman(user))
		var/mob/living/carbon/human/H = user
		if(H.getBrainLoss() >= 55)
			visible_message(SPAN_WARNING("[H] stares cluelessly at \the [src]."))
			return TRUE
		else if(prob(H.getBrainLoss()))
			to_chat(user, SPAN_WARNING("You momentarily forget how to use \the [src]."))
			return TRUE
	if((. = component_attack_hand(user)))
		return
	if(wires && (. = wires.Interact(user)))
		return
	if((. = physical_attack_hand(user)))
		return
	if(CanUseTopic(user, DefaultTopicState()) > STATUS_CLOSE)
		return interface_interact(user)

// If you want to have interface interactions handled for you conveniently, use this.
// Return TRUE for handled.
// If you perform direct interactions in here, you are responsible for ensuring that full interactivity checks have been made (i.e CanInteract).
// The checks leading in to here only guarantee that the user should be able to view a UI.
/obj/machinery/proc/interface_interact(user)
	return FALSE

// If you want a physical interaction which happens after all relevant checks but preempts the UI interactions, do it here.
// Return TRUE for handled.
/obj/machinery/proc/physical_attack_hand(user)
	return FALSE

/obj/machinery/proc/RefreshParts()
	set_noinput(TRUE)
	set_noscreen(TRUE)
	for(var/thing in component_parts)
		var/obj/item/stock_parts/part = thing
		part.on_refresh(src)
	var/list/missing = missing_parts()
	set_broken(!!missing, MACHINE_BROKEN_NO_PARTS)

/obj/machinery/proc/state(msg)
	for(var/mob/O in hearers(src, null))
		O.show_message("[icon2html(src, O)] <span class = 'notice'>[msg]</span>", 2)

/obj/machinery/proc/ping(text=null)
	if (!text)
		text = "\The [src] pings."

	state(text, "blue")
	playsound(src.loc, 'sounds/machines/ping.ogg', 50, 0)
	show_sound_effect(src.loc, soundicon = SFX_ICON_SMALL)

/obj/machinery/proc/shock(mob/user, prb)
	if(inoperable())
		return 0
	if(!prob(prb))
		return 0
	var/datum/effect/effect/system/spark_spread/s = new /datum/effect/effect/system/spark_spread
	s.set_up(5, 1, src)
	s.start()
	if(electrocute_mob(user, get_area(src), src, 0.7))
		var/area/temp_area = get_area(src)
		if(temp_area)
			var/obj/machinery/power/apc/temp_apc = temp_area.get_apc()
			var/obj/machinery/power/terminal/terminal = temp_apc && temp_apc.terminal()

			if(terminal && terminal.powernet)
				terminal.powernet.trigger_warning()
		if(user.stunned)
			return 1
	return 0

/obj/machinery/proc/dismantle()
	playsound(loc, 'sounds/items/Crowbar.ogg', 50, 1)
	var/obj/item/stock_parts/circuitboard/circuit = get_component_of_type(/obj/item/stock_parts/circuitboard)
	if(circuit)
		circuit.deconstruct(src)
	if(ispath(frame_type, /obj/item/pipe))
		new frame_type(get_turf(src), src)
	else
		new frame_type(get_turf(src), dir)
	for(var/I in component_parts)
		uninstall_component(I, refresh_parts = FALSE)
	while(LAZYLEN(uncreated_component_parts))
		var/path = uncreated_component_parts[1]
		uninstall_component(path, refresh_parts = FALSE)
	for(var/obj/O in src)
		O.dropInto(loc)

	qdel(src)
	return 1

/obj/machinery/InsertedContents()
	return (contents - component_parts)

/datum/proc/apply_visual(mob/M)
	return

/datum/proc/remove_visual(mob/M)
	return

/obj/machinery/proc/malf_upgrade(mob/living/silicon/ai/user)
	return 0

/obj/machinery/CouldUseTopic(mob/user)
	..()
	if(clicksound && world.time > next_clicksound && istype(user, /mob/living/carbon))
		next_clicksound = world.time + CLICKSOUND_INTERVAL
		playsound(src, clicksound, clickvol)

/obj/machinery/proc/display_parts(mob/user)
	to_chat(user, SPAN_NOTICE("Following parts detected in the machine:"))
	for(var/obj/item/C in component_parts)
		to_chat(user, SPAN_NOTICE("	[C.name]"))
	for(var/path in uncreated_component_parts)
		var/obj/item/thing = path
		to_chat(user, SPAN_NOTICE("	[initial(thing.name)] ([uncreated_component_parts[path] || 1])"))

/obj/machinery/examine(mob/user)
	. = ..()
	if (panel_open)
		to_chat(user, "The service panel is open.")
	if(component_parts && hasHUD(user, HUD_SCIENCE))
		display_parts(user)
	if(stat & NOSCREEN)
		to_chat(user, "It is missing a screen, making it hard to interact with.")
	else if(stat & NOINPUT)
		to_chat(user, "It is missing any input device.")
	else if((stat & NOPOWER) && !interact_offline)
		to_chat(user, "It is not receiving power.")
	if(construct_state && construct_state.mechanics_info())
		to_chat(user, "It can be <a href='?src=\ref[src];mechanics_text=1'>manipulated</a> using tools.")
	var/list/missing = missing_parts()
	if(missing)
		var/list/parts = list()
		for(var/type in missing)
			var/obj/item/fake_thing = type
			parts += "[num2text(missing[type])] [initial(fake_thing.name)]"
		to_chat(user, "\The [src] is missing [english_list(parts)], rendering it inoperable.")
	if (machine_desc && (user.skill_check(SKILL_CONSTRUCTION, SKILL_BASIC) || isobserver(user)))
		to_chat(user, SPAN_NOTICE(machine_desc))

// This is really pretty crap and should be overridden for specific machines.
/obj/machinery/water_act(depth)
	..()
	if(!(stat & (NOPOWER|BROKEN)) && !waterproof && (depth > FLUID_DEEP))
		ex_act(3)

/obj/machinery/Move()
	. = ..()
	if(. && !CanFluidPass())
		fluid_update()

/obj/machinery/get_cell()
	var/obj/item/stock_parts/power/battery/battery = get_component_of_type(/obj/item/stock_parts/power/battery)
	if(battery)
		return battery.get_cell()

// Coarse - dismantles the machine
// Fine - randomly upgrades components of the machine via same proc
// Very fine - same as above, but has a chance to start small explosion
/obj/machinery/Conversion914(mode = MODE_ONE_TO_ONE, mob/user = usr)
	switch(mode)
		if(MODE_COARSE)
			dismantle()
			return src // Gets deleted in dismantle() anyway
		if(MODE_FINE)
			for(var/obj/item/stock_parts/S in component_parts)
				if(istype(S, /obj/item/stock_parts/circuitboard))
					continue
				if(prob(20))
					continue
				S.Conversion914(mode, user)
			playsound(src, 'sounds/items/rped.ogg', 50, TRUE)
			return src
		if(MODE_VERY_FINE)
			for(var/obj/item/stock_parts/S in component_parts)
				if(istype(S, /obj/item/stock_parts/circuitboard))
					continue
				if(prob(10))
					continue
				if(prob(3)) // The more parts you got - the more likely it is to explode
					explosion(get_turf(src), -1, prob(33), 5, 7, FALSE)
					return src
				S.Conversion914(mode, user)
			playsound(src, 'sounds/items/rped.ogg', 75, TRUE, 3)
			return src
	return ..()
