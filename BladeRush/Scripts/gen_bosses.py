#!/usr/bin/env python3
"""Generates Data/bosses.json for BLADE RUSH.

Every boss is hand-specified below (name, title, lore, look, weapon, phases, signature,
weaknesses, dialogue). Attack lists are composed from the shared library in
Data/attacks.json using per-weapon-family pools, tier scaling and a per-boss seed, then
tuned per boss. Edit the specs and re-run:  python3 Scripts/gen_bosses.py
The resulting JSON is the source of truth the game reads (and hot-reloads)."""
import json, random, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

FAMILY = {
    # weapon type -> attack family
    "shortsword": "blade", "machete": "blade", "falchion": "blade", "cutlass": "blade", "rapier": "duelist",
    "sword_cane": "duelist", "frost_rapier": "duelist", "estoc": "duelist", "katana": "blade",
    "longsword": "shield", "arming_sword": "shield",
    "hand_axe": "blunt", "club": "blunt", "mace": "blunt", "boarding_axe": "blunt", "war_pick": "heavy",
    "greatsword": "heavy", "warhammer": "heavy", "maul": "heavy", "giant_cleaver": "heavy", "molten_greatblade": "heavy", "zweihander": "heavy",
    "halberd": "pole", "naginata": "pole", "glaive": "pole", "bardiche": "pole", "guandao": "pole", "spear": "pole",
    "storm_spear": "pole", "harpoon": "pole", "lance": "lance", "bo_staff": "pole", "reaper_scythe": "scythe",
    "tonfa": "dual", "hook_sword": "dual", "saber": "dual", "kama": "dual", "katar": "dual", "shadow_blade": "dual",
    "rapier_dagger": "dual", "dagger": "dual",
    "three_section_staff": "chain", "meteor_hammer": "chain", "anchor_chain": "chainheavy", "flail": "chain",
    "chain_whip": "chain", "kusarigama": "chain", "urumi": "chain",
    "war_fan": "fan",
}

POOLS = {
    "blade":  ["sweep_h", "sweep_hb", "overhead", "diagonal", "rising", "quick_jab", "thrust", "double_slash", "combo3", "combo4",
               "delayed_overhead", "feint_thrust", "low_sweep", "lunge", "spin", "retreat_slash", "combo5", "grab", "delayed_sweep", "combo6"],
    "duelist":["quick_jab", "thrust", "step_thrust", "sweep_hb", "diagonal", "lunge", "combo4", "feint_thrust", "delayed_sweep", "retreat_slash",
               "double_slash", "combo5", "rising", "delayed_overhead", "low_sweep", "combo6", "combo8"],
    "shield": ["sweep_h", "overhead", "thrust", "shield_bash", "bash_combo", "double_slash", "combo3", "diagonal", "delayed_overhead",
               "lunge", "low_sweep", "combo4", "feint_thrust", "charge", "combo5"],
    "blunt":  ["sweep_h", "overhead", "diagonal", "heavy_cleave", "combo3", "delayed_overhead", "low_sweep", "burst_slam", "leap_slam",
               "sweep_hb", "grab", "double_slash", "spin", "feint_sweep", "combo4"],
    "heavy":  ["heavy_cleave", "heavy_sweep", "heavy_combo", "burst_slam", "leap_slam", "spin", "delayed_overhead", "low_sweep",
               "whirlwind", "charge", "execution", "overhead", "rising", "feint_sweep", "combo3"],
    "pole":   ["pole_sweep", "pole_thrust", "pole_triple", "pole_vault", "spin", "low_sweep", "lunge", "delayed_overhead", "overhead",
               "whirlwind", "feint_thrust", "rising", "combo3", "grab", "retreat_slash"],
    "lance":  ["pole_thrust", "pole_triple", "charge", "lunge", "pole_sweep", "delayed_overhead", "low_sweep", "leap_slam", "burst_slam",
               "spin", "feint_thrust", "execution"],
    "scythe": ["pole_sweep", "sweep_hb", "low_sweep", "whirlwind", "grab", "delayed_sweep", "spin", "pole_vault", "combo4", "rising",
               "feint_sweep", "execution", "lunge"],
    "dual":   ["flurry", "cross_slash", "twin_spin", "double_slash", "combo4", "quick_jab", "lunge", "delayed_sweep", "low_sweep",
               "step_thrust", "retreat_slash", "grab", "combo5", "feint_thrust", "combo6"],
    "chain":  ["chain_lash", "chain_thrust", "chain_sweep", "chain_orbit", "chain_combo", "chain_grab", "sweep_h", "overhead",
               "delayed_overhead", "quick_jab", "retreat_slash", "spin"],
    "chainheavy": ["chain_lash", "chain_thrust", "chain_sweep", "chain_orbit", "chain_combo", "chain_grab", "burst_slam", "heavy_cleave",
                   "leap_slam", "heavy_sweep", "execution"],
    "fan":    ["sweep_h", "sweep_hb", "twin_spin", "quick_jab", "diagonal", "delayed_sweep", "combo4", "rising", "spin", "feint_sweep",
               "whirlwind", "burst_slam", "combo5"],
}

# Tutorial-tier restrictions: each early boss teaches a telegraph.
TUTORIAL = {
    "gorrik":     ["sweep_h", "overhead", "diagonal", "thrust", "double_slash", "quick_jab", "sweep_hb", "rising"],
    "mother_hatchet": ["sweep_h", "overhead", "low_sweep", "diagonal", "sweep_hb", "double_slash", "rising", "feint_sweep"],
    "brute_dunmore":  ["sweep_h", "overhead", "heavy_cleave", "delayed_overhead", "diagonal", "burst_slam", "sweep_hb", "leap_slam", "delayed_overhead"],
    "sella":      ["sweep_h", "sweep_hb", "combo3", "diagonal", "quick_jab", "double_slash", "combo4", "thrust", "lunge"],
}

def boss(id, name, title, tier, weapon, lore, desc, visual, phases, signature, weaknesses, weakTo, intro, death,
         extra_weapons=None, stats=None, attacks=None, weapon_look=None):
    return dict(id=id, name=name, title=title, tier=tier, weapon=weapon, lore=lore, desc=desc, visual=visual, phases=phases,
                signature=signature, weaknesses=weaknesses, weakTo=weakTo, intro=intro, death=death,
                extra_weapons=extra_weapons or [], stats=stats or {}, attacks=attacks, weapon_look=weapon_look or {})

def V(**kw):
    """Visual block helper: body sub-dict via b_ prefixed keys, colors via c_ prefix."""
    body, colors, vis = {}, {}, {}
    for k, v in kw.items():
        if k.startswith("b_"): body[k[2:]] = v
        elif k.startswith("c_"): colors[k[2:]] = v
        else: vis[k] = v
    if body: vis["body"] = body
    if colors: vis["colors"] = colors
    return vis

def P(*phases):
    """(threshold, name, line, lighting, extras)"""
    out = []
    for p in phases:
        d = {"threshold": p[0], "name": p[1], "line": p[2], "lighting": p[3]}
        if len(p) > 4: d.update(p[4])
        out.append(d)
    return out

B = []
# ---------------------------------------------------------------- Tier 1: The Outcast Yard (rusted blades)
B.append(boss("gorrik", "Gorrik the Castoff", "Rust-Eaten Deserter", 1, "shortsword",
    "He fled three wars and kept the one blade that never failed to rust.",
    "Gaunt deserter in a torn gambeson, bald and stubbled, shortsword pitted with rust.",
    V(outfit="rags", chest="leather", helmet="none", hair="none", beard="stubble", arms="wraps", legs="wraps", skirt="tattered", extras=["belt"],
      c_primary="#5a4a3a", c_secondary="#4a3a2a", c_leather="#3a2a1a", skin="#b88a6a", wear=0.7, rust=0.6, armorMaterial="rustIron", b_height=1.78, b_bulk=0.95),
    P((1.0, "Desperate", "", ""), (0.5, "Cornered Rat", "No more running... not from you.", "red", {"speed": 1.1, "aggression": 1.2})),
    ("Rust Cascade", "combo3", {"telegraph": "gold"}),
    ["Slow, readable white-flash swings: ideal for learning perfect parries", "Long recovery after his overhead"],
    {"posture": 1.2}, "Another one come to take my blade? Take it, then.", "It never... failed me.",
    weapon_look={"metal": "#7a6a5a", "rust": 0.8}))
B.append(boss("mother_hatchet", "Mother Hatchet", "Widow of the Woodpile", 1, "hand_axe",
    "She split kindling for forty winters, then split the men who burned her home.",
    "Hunched widow in a patched hood and apron-kilt, wild grey hair, a notched hand axe.",
    V(outfit="tunic", helmet="hood", hair="wild", arms="sleeves", legs="pants", skirt="kilt", extras=["belt", "pouches"],
      c_primary="#4a4238", c_secondary="#6a3a2a", c_hair="#8a8a86", skin="#c49a80", wear=0.6, b_height=1.66, b_hunch=12),
    P((1.0, "Woodcutter", "", ""), (0.5, "Hearthfire", "My hearth is ash. Yours will be too.", "red", {"speed": 1.12, "element": "fire", "glow": 0.6})),
    ("Kindling Sweep", "low_sweep", {"damage": 1.2}),
    ["Her red-glow ground sweeps must be dodged, never parried", "Vulnerable after missed chops"],
    {"heavy": 1.2}, "Mind the woodpile, stranger.", "The fire's... gone out.",
    weapon_look={"metal": "#6a5a4a", "rust": 0.6, "handle": "#5a3a1a"}))
B.append(boss("brute_dunmore", "Brute Dunmore", "The Yard's Cudgel", 1, "club",
    "Too big for the army, too dim for the gallows; the yard made him its king.",
    "Hulking bare-chested bruiser with a pot belly, fur mantle, and a nail-studded club.",
    V(outfit="bare", helmet="none", hair="mohawk", beard="full", arms="wraps", legs="pants", skirt="loincloth", extras=["fur_collar", "belt"],
      c_primary="#3a3028", c_hair="#2a1a10", skin="#a87a5a", b_height=2.25, b_bulk=1.45, b_belly=0.8, b_muscle=0.9, wear=0.5),
    P((1.0, "Lumbering", "", ""), (0.5, "Rampage", "DUNMORE SMASH THE LITTLE ONE!", "red", {"speed": 1.08, "aggression": 1.3})),
    ("Drunken Hammerfall", "delayed_overhead", {"damage": 1.3}),
    ["Purple-shimmer delays: wait for the swing, then parry", "Posture breaks quickly when parried"],
    {"posture": 1.35}, "HAH! A snack wandered in.", "Dunmore... sleepy...",
    stats={"radius": 0.62, "poise": 45}, weapon_look={"scale": 1.3}))
B.append(boss("sella", "Sella Cane-Cutter", "Machete of the Reeds", 1, "machete",
    "She cut a path through the marsh reeds and never stopped cutting.",
    "Lean marsh-runner in a red bandana and sash, wrapped forearms, broad machete.",
    V(outfit="tunic", helmet="bandana", hair="ponytail", arms="wraps", legs="wraps", extras=["sash", "belt"],
      c_primary="#4a5a3a", c_secondary="#9a2a1a", skin="#8a6048", b_height=1.72, b_bulk=0.9, wear=0.4),
    P((1.0, "Reed Runner", "", ""), (0.5, "Harvest", "The reeds are thick with the ones who tried.", "red", {"speed": 1.15})),
    ("Reed Harvest", "combo4", {"damage": 1.1}),
    ["Her gold-flash combo enders open a big punish window when perfectly parried", "Light posture"],
    {"bleed": 1.3}, "Stay out of the reeds.", "Should've... stayed...",
    weapon_look={"metal": "#8a8a82", "rust": 0.3}))
B.append(boss("warden_ossic", "Warden Ossic", "Keeper of the Outcasts", 1, "falchion",
    "The yard's jailer in rusted plate, who decided the outcasts were his to cull.",
    "Armored jailer in rust-pitted plate, sallet helm, tattered cloak, heavy falchion.",
    V(outfit="armor", chest="plate", pauldrons="round", helmet="sallet", arms="gauntlets", legs="greaves", skirt="tassets", cape="tattered",
      c_primary="#4a3a30", c_secondary="#5a2a20", c_metal="#7a6a60", armorMaterial="rustIron", rust=0.7, wear=0.6, b_height=1.92, b_bulk=1.15),
    P((1.0, "Warden", "", ""), (0.5, "Iron Verdict", "The yard's sentence is always the same.", "red", {"speed": 1.12, "glow": 0.4})),
    ("Warden's Verdict", "combo5", {"damage": 1.1, "telegraph": "gold"}),
    ["Mixes every telegraph: read the color, then choose parry or dodge", "Heavy armor recovers posture slowly"],
    {"posture": 1.1, "heavy": 1.15}, "Another outcast. Kneel.", "The yard... is yours...",
    weapon_look={"metal": "#7a6a5a", "rust": 0.6}))

# ---------------------------------------------------------------- Tier 2: The Iron Garrison
B.append(boss("halvard", "Sergeant Halvard", "Shield of the Seventh Gate", 2, "longsword",
    "Thirty years at the Seventh Gate; not one enemy passed. He intends to keep it that way.",
    "Veteran sergeant in a steel breastplate and kite shield, great helm, crimson tabard.",
    V(outfit="armor", chest="plate", pauldrons="layered", helmet="great", arms="gauntlets", legs="greaves", skirt="tassets", cape="short",
      c_primary="#6a1a1a", c_secondary="#7a1818", c_metal="#9a9ca4", c_trim="#b89a4a", b_height=1.9, b_bulk=1.15),
    P((1.0, "Hold the Line", "", ""), (0.5, "Last Gate", "The Seventh Gate does not fall!", "red", {"speed": 1.1})),
    ("Gatebreaker", "bash_combo", {"damage": 1.2, "posture": 1.2}),
    ["Shield bashes are fast but low damage", "Opens up after his charge"],
    {"posture": 1.0, "heavy": 1.2}, "Halt. None pass the Seventh Gate.", "The gate... falls...", stats={"deflect": 0.2}))
B.append(boss("brisa", "Pikewarden Brisa", "The Halberd Wall", 2, "halberd",
    "She drilled a thousand recruits until they moved as one halberd. Now she is the wall.",
    "Tall pikewarden in scale armor and a crested helm, long halberd, disciplined stance.",
    V(outfit="armor", chest="scale", pauldrons="round", helmet="crested", arms="bracers", legs="greaves", skirt="tassets",
      c_primary="#2a3a5a", c_secondary="#6a1a1a", c_metal="#8a8c94", b_height=1.95),
    P((1.0, "Drill Form", "", ""), (0.5, "Phalanx", "Form up! ...Ah. I'm the only one left.", "dark", {"speed": 1.12})),
    ("Wall of Points", "pole_triple", {"damage": 1.2, "telegraph": "gold"}),
    ["Long reach: stay close to crowd the halberd", "Vaulting crash leaves her open on landing"],
    {"posture": 1.15}, "Present arms. You'll not get close.", "Break... ranks...", stats={"deflect": 0.15}))
B.append(boss("orwen", "Brother Orwen", "Iron Chaplain", 2, "mace",
    "He blesses the garrison each dawn and breaks heretics' bones each dusk.",
    "Burly war-priest in a chain hauberk and cowl, prayer beads, flanged mace glowing faintly.",
    V(outfit="robe", chest="chain", helmet="cowl", arms="bracers", legs="boots", skirt="robe", extras=["beads", "belt"],
      c_primary="#3a3440", c_secondary="#e0d8c8", c_metal="#8a8a90", b_height=1.88, b_bulk=1.3, b_belly=0.3, runes=0.3, c_glow="#ffd070"),
    P((1.0, "Sermon", "", ""), (0.5, "Holy Wrath", "Let the iron sing its hymn!", "red", {"speed": 1.08, "element": "holy", "glow": 1.0})),
    ("Hymn of Iron", "burst_slam", {"damage": 1.2, "element": "holy"}),
    ["Slow mace swings: parry them for heavy posture damage", "Holy bursts are short range: back off after the slam"],
    {"posture": 1.2}, "Kneel, and be absolved.", "Forgive... me...", weapon_look={"glow": "#ffd070", "glowStrength": 0.3}))
B.append(boss("vessik", "Captain Vessik", "Pick of the Breach", 2, "war_pick",
    "He opened the castle breach with this pick and still hears the stones scream.",
    "Siege captain in a brigandine and kettle helm, grimy bandolier, massive war pick.",
    V(outfit="armor", chest="brigandine", pauldrons="round", helmet="kabuto", arms="gauntlets", legs="greaves", skirt="tassets", extras=["bandolier"],
      c_primary="#3a2a1a", c_secondary="#5a4a2a", c_metal="#6a6a6e", b_height=1.85, b_bulk=1.2),
    P((1.0, "Siege", "", ""), (0.5, "Breach", "Every wall has a weak point. Even you.", "red", {"speed": 1.1})),
    ("Breach Strike", "execution", {"damage": 1.1}),
    ["War pick grabs hook you: dodge the red glow", "Very slow recovery after a whiff"],
    {"posture": 1.1, "heavy": 1.2}, "I've cracked thicker walls than you.", "The breach... closes...", stats={"poise": 40}))
B.append(boss("aurel_vane", "Commander Aurel Vane", "The Unbroken Line", 2, "arming_sword",
    "Never lost a duel, never lost a battle, never lost his composure. Until today.",
    "Immaculate commander in gilded plate, winged pauldrons, blue cape, sword and buckler.",
    V(outfit="armor", chest="plate", pauldrons="wings", helmet="circlet", hair="short", arms="gauntlets", legs="greaves", skirt="tassets", cape="long",
      c_primary="#1a2a5a", c_secondary="#2a3a8a", c_metal="#c0c4cc", c_trim="#d8b060", c_hair="#c8b890", b_height=1.9),
    P((1.0, "Composed", "", ""), (0.5, "Unbroken", "Impressive. Now I fight in earnest.", "dark", {"speed": 1.15, "glow": 0.5, "aggression": 1.2})),
    ("Unbroken Line", "combo5", {"damage": 1.15, "telegraph": "gold"}),
    ["Deflects idle attacks: bait his combo, then punish", "Buckler bashes deal big posture: parry them"],
    {"posture": 1.0}, "Face me with honor.", "The line... breaks.", stats={"deflect": 0.3}))

# ---------------------------------------------------------------- Tier 3: The Crimson Monastery
B.append(boss("shen_wu", "Acolyte Shen Wu", "The Turning Staff", 3, "bo_staff",
    "The youngest acolyte ever to master the Turning Staff, and the fastest to anger.",
    "Young monk in saffron gi and wide hakama, topknot, twirling bo staff.",
    V(outfit="gi", helmet="none", hair="topknot", arms="short", legs="hakama", extras=["sash", "beads"],
      c_primary="#c87a1a", c_secondary="#6a1a10", skin="#c89a78", b_height=1.72, b_bulk=0.9),
    P((1.0, "Kata", "", ""), (0.5, "Whirling Crane", "The staff turns. So does the world.", "red", {"speed": 1.15})),
    ("Thousand Turns", "whirlwind", {"damage": 1.0}),
    ["Staff strikes are light: parry chains build his posture fast", "Whirlwind is red: dodge through it"],
    {"posture": 1.2}, "Master says I'm not ready. Let's prove him wrong.", "Master... was right...",
    weapon_look={"handle": "#6a3a1a"}))
B.append(boss("lian", "Sister Lian", "Coiled Serpent of Three Rivers", 3, "three_section_staff",
    "Her three-section staff flows like the three rivers she swore to guard.",
    "Serene nun in a crimson veil and robe, three-section staff linked by chains.",
    V(outfit="robe", helmet="veil", arms="bell", legs="hakama", skirt="robe", extras=["sash"],
      c_primary="#8a1a1a", c_secondary="#e0c080", skin="#d0a888", b_height=1.7),
    P((1.0, "Flowing", "", ""), (0.5, "Flood", "The rivers rise.", "red", {"speed": 1.12, "element": "water"})),
    ("Three Rivers", "chain_combo", {"damage": 1.1}),
    ["Chain strikes reach far but recover slowly", "Stay close: she has few close-range answers"],
    {"posture": 1.1}, "Be still, like water.", "The rivers... run dry..."))
B.append(boss("kaede", "Abbess Kaede", "Crimson Crescent", 3, "naginata",
    "The abbess who turned a monastery of prayer into a monastery of war.",
    "Stern abbess in lacquered red armor over robes, straw hat, curved naginata.",
    V(outfit="robe", chest="cuirass", pauldrons="layered", helmet="strawhat", arms="bracers", legs="hakama", skirt="robe",
      c_primary="#7a1010", c_secondary="#3a1010", armorMaterial="lacquer", b_height=1.8),
    P((1.0, "Crescent", "", ""), (0.5, "Blood Moon", "The crescent is full. Bleed for it.", "red", {"speed": 1.15, "glow": 0.5}),),
    ("Crimson Crescent", "pole_sweep", {"damage": 1.3, "telegraph": "gold", "aoe": 0}),
    ["Wide sweeps: dodge inward, not away", "Delayed overheads are her favorite trap"],
    {"posture": 1.0}, "You desecrate holy ground.", "Forgive... this monastery...", stats={"deflect": 0.2}))
B.append(boss("tou_rook", "Master Tou Rook", "Twin Bastions", 3, "tonfa",
    "Two tonfa, two fortresses. He has never been touched in a spar.",
    "Stocky monk with a shaved head and long beard, bare arms wrapped, twin tonfa.",
    V(outfit="gi", helmet="none", hair="none", beard="long", arms="wraps", legs="hakama", extras=["sash", "beads"],
      c_primary="#e0d0b0", c_secondary="#8a2a1a", c_hair="#e0e0e0", skin="#b08060", b_height=1.75, b_bulk=1.25, b_muscle=0.9),
    P((1.0, "Bastion", "", ""), (0.5, "Avalanche Palms", "Now the fortress attacks.", "red", {"speed": 1.15, "aggression": 1.3})),
    ("Twin Bastion Flurry", "flurry", {"damage": 1.2}),
    ["Deflects often: use heavy attacks to force openings", "Low posture regen when pressured"],
    {"heavy": 1.3}, "Strike me, if you can.", "A... fine... spar...", stats={"deflect": 0.35}))
B.append(boss("yul_han", "Grandmaster Yul-Han", "Falling Star", 3, "meteor_hammer",
    "The grandmaster's meteor hammer has fallen on nine generations of challengers.",
    "Ancient grandmaster in flowing crimson robes, long white hair and beard, meteor hammer on a rope.",
    V(outfit="robe", helmet="none", hair="long", beard="long", arms="bell", legs="hakama", skirt="robe", extras=["beads"],
      c_primary="#6a0a0a", c_secondary="#d8b060", c_hair="#e8e8e8", skin="#c09070", b_height=1.76, b_hunch=6, runes=0.5, c_glow="#ff6a3a"),
    P((1.0, "Stillness", "", ""), (0.66, "Orbit", "The star circles.", "red", {"speed": 1.1}),
      (0.33, "Falling Star", "And now it falls.", "red", {"speed": 1.2, "element": "fire", "glow": 1.0})),
    ("Falling Star", "chain_combo", {"damage": 1.3, "telegraph": "gold"}),
    ["Orbit attacks are red: dodge outward", "Rope attacks recover slowly: close the gap"],
    {"posture": 1.0}, "Nine generations. You will be the tenth.", "The star... sets...", weapon_look={"glow": "#ff6a3a", "glowStrength": 0.4}))

# ---------------------------------------------------------------- Tier 4: The Drowned Harbor
B.append(boss("mirelle", "Salt-Jack Mirelle", "Cutlass of the Lost Tide", 4, "cutlass",
    "Her ship sank; her crew drowned; her cutlass never let go of her hand.",
    "Swashbuckler in a long coat and tricorn, eyepatch, bandolier, curved cutlass.",
    V(outfit="coat", helmet="tricorn", hair="long", arms="sleeves", legs="boots", skirt="coat", extras=["bandolier", "belt", "eyepatch"],
      c_primary="#1a2a3a", c_secondary="#6a1a1a", c_hair="#3a1a10", skin="#c09070", b_height=1.76),
    P((1.0, "Swagger", "", ""), (0.5, "Riptide", "The tide takes everything eventually.", "storm", {"speed": 1.15, "element": "water"})),
    ("Riptide Flourish", "combo5", {"damage": 1.1, "telegraph": "gold"}),
    ["Feints constantly: watch for purple", "Light armor: bleed works wonders"],
    {"bleed": 1.3}, "Welcome aboard, landlubber.", "Tell the tide... I'm coming home..."))
B.append(boss("grull", "Boarsman Grull", "The Boarding Axe", 4, "boarding_axe",
    "First over every rail, first into every fight, last to ever leave.",
    "Barrel-chested raider in rusted mail, horned bandana, tusks of bone, spiked boarding axe.",
    V(outfit="rags", chest="chain", pauldrons="fur", helmet="bandana", beard="braided", arms="bracers", legs="boots", extras=["tusks", "belt", "skulls"],
      c_primary="#3a2a1a", c_secondary="#5a1a10", c_hair="#8a3a10", skin="#b07a5a", b_height=2.0, b_bulk=1.35, b_belly=0.4, rust=0.4),
    P((1.0, "Boarding", "", ""), (0.5, "Blood in the Water", "SMELL THAT? THAT'S YOU!", "red", {"speed": 1.12, "aggression": 1.4})),
    ("Rail Breaker", "leap_slam", {"damage": 1.2, "aoe": 2.2}),
    ["Relentless pressure: parry the string, punish the gold ender", "His grab is red: dodge sideways"],
    {"posture": 1.1}, "FRESH MEAT ON DECK!", "Grull... sinks...", stats={"radius": 0.55, "poise": 45}))
B.append(boss("brannoc", "Anchorlord Brannoc", "Drowned Colossus", 4, "anchor_chain",
    "Chained to his ship's anchor as punishment, he dragged it up from the seabed himself.",
    "Towering drowned giant, barnacled skin, chains across the chest, swinging an anchor on a chain.",
    V(outfit="bare", pauldrons="bone", helmet="none", hair="wild", beard="full", arms="wraps", legs="wraps", skirt="loincloth", extras=["chains"],
      c_primary="#2a3a3a", c_hair="#1a3a3a", skin="#6a8a86", b_height=2.9, b_bulk=1.5, b_muscle=1.0, eyeGlow=0.6, c_glow="#6affd8"),
    P((1.0, "Dredge", "", ""), (0.5, "Undertow", "THE SEA... TAKES... ALL.", "storm", {"speed": 1.1, "element": "water", "glow": 0.8})),
    ("Undertow", "chain_orbit", {"damage": 1.3}),
    ["Enormous reach but very slow anchor recovery", "Get inside the chain's arc"],
    {"heavy": 1.2, "posture": 0.9}, "...drowned... like me...", "...the deep... calls...",
    stats={"radius": 0.8, "poise": 70}, weapon_look={"scale": 1.3}))
B.append(boss("widow_nettle", "Widow Nettle", "Harpooner of the Deep", 4, "harpoon",
    "She harpooned the leviathan that ate her husband, then the crew that fled from it.",
    "Grim harpooner in an oilskin coat and hood, rope coils, barbed harpoon held in both hands.",
    V(outfit="coat", helmet="hood", arms="sleeves", legs="boots", skirt="coat", extras=["belt", "pouches", "lantern"],
      c_primary="#2a2a22", c_secondary="#6a5a3a", skin="#b08a70", b_height=1.8),
    P((1.0, "Hunter", "", ""), (0.5, "Leviathan's Wake", "I've gutted bigger things than you.", "storm", {"speed": 1.15})),
    ("Leviathan Hook", "grab", {"damage": 1.2}),
    ["Barbed hook grabs are red", "Her thrusts are straight: sidestep dodges beat them"],
    {"bleed": 1.2}, "Something's stirring in the water.", "The deep... has me...", stats={"deflect": 0.15}))
B.append(boss("varga", "Captain Hollow-Eye Varga", "Twin Hooks of the Maelstrom", 4, "hook_sword",
    "The maelstrom took his eye and his ship; he took its fury.",
    "Pirate captain in a battered greatcoat and tricorn, ghostly glowing eye, twin hook swords.",
    V(outfit="coat", chest="leather", helmet="tricorn", hair="long", beard="braided", arms="sleeves", legs="boots", skirt="coat", cape="short",
      extras=["bandolier", "belt"], c_primary="#1a1a2a", c_secondary="#3a0a1a", c_hair="#1a1a1a", skin="#a88070", eyeGlow=0.8, c_glow="#6affd8",
      b_height=1.86),
    P((1.0, "Storm Captain", "", ""), (0.66, "Maelstrom", "All hands to the storm!", "storm", {"speed": 1.1, "element": "water"}),
      (0.33, "Eye of the Storm", "I see you now. With the eye the sea took.", "storm", {"speed": 1.2, "glow": 1.0, "aggression": 1.3})),
    ("Maelstrom", "twin_spin", {"damage": 1.2}),
    ["Hook grabs are red", "Cross slashes are gold enders: perfect parry for a big opening"],
    {"posture": 1.0}, "Welcome to the eye of the storm.", "Take the helm... storm-born...", stats={"deflect": 0.2},
    weapon_look={"glow": "#6affd8", "glowStrength": 0.3}))

# ---------------------------------------------------------------- Tier 5: The Ashen Forge
B.append(boss("ulgra", "Forgemaster Ulgra", "Hammer of the Deep Anvil", 5, "warhammer",
    "She forged the garrison's blades and now tests them against their wielders.",
    "Massive smith in a scorched leather apron and brigandine, soot-black skin, glowing runed warhammer.",
    V(outfit="armor", chest="brigandine", pauldrons="round", helmet="none", hair="topknot", arms="gauntlets", legs="boots", skirt="kilt",
      extras=["belt", "pouches"], c_primary="#2a1a14", c_secondary="#3a2a20", c_leather="#2a1a10", skin="#5a3a2a", b_height=2.2, b_bulk=1.4, b_muscle=1.0,
      runes=0.5, c_glow="#ff6a20"),
    P((1.0, "Tempering", "", ""), (0.5, "White Heat", "The metal is ready. Are you?", "fire", {"speed": 1.1, "element": "fire", "glow": 1.0})),
    ("Deep Anvil", "burst_slam", {"damage": 1.3, "element": "fire", "aoe": 3.0}),
    ["Every slam bursts: step back after the impact", "Posture breaks with repeated perfect parries"],
    {"posture": 1.2}, "Let's see what you're made of.", "Good... steel...", stats={"radius": 0.6, "poise": 60},
    weapon_look={"glow": "#ff6a20", "glowStrength": 0.6, "element": "fire"}))
B.append(boss("tharos", "Kiln-Born Tharos", "Molten Heart", 5, "molten_greatblade",
    "Born in the kiln's heart, his blood runs with liquid iron.",
    "Obsidian-skinned brute with lava veins, horned helm, fur collar, a jagged molten greatblade.",
    V(outfit="armor", chest="plate", pauldrons="spiked", helmet="horned", arms="gauntlets", legs="greaves", skirt="tassets", extras=["fur_collar"],
      c_primary="#1a1010", c_metal="#2a2226", armorMaterial="obsidian", skin="#2a1a1a", eyeGlow=1.0, runes=1.0, c_glow="#ff4a10",
      b_height=2.3, b_bulk=1.35),
    P((1.0, "Smolder", "", ""), (0.66, "Eruption", "THE KILN OVERFLOWS!", "fire", {"speed": 1.1, "element": "fire", "glow": 1.2}),
      (0.33, "Molten Heart", "Burn with me!", "fire", {"speed": 1.2, "glow": 2.0, "aggression": 1.3})),
    ("Molten Cataclysm", "heavy_combo", {"damage": 1.3, "element": "fire", "aoe": 3.0}),
    ["Fire bursts after every heavy impact", "Charge is red: dodge to the side, not back"],
    {"posture": 1.0, "heavy": 1.2}, "Stoke the kiln.", "The fire... cools...", stats={"radius": 0.65, "poise": 70},
    weapon_look={"glow": "#ff4a10", "glowStrength": 1.0, "element": "fire"}))
B.append(boss("ezzo", "Chainbrand Ezzo", "Flail of Cinders", 5, "flail",
    "A furnace-slave who broke his chains and forged them into a weapon.",
    "Scarred ex-slave with branded skin, broken shackles, chained flail of glowing cinders.",
    V(outfit="bare", pauldrons="none", helmet="mask", hair="none", arms="wraps", legs="wraps", skirt="loincloth", extras=["chains", "belt"],
      c_primary="#2a1a14", c_metal="#4a4040", skin="#8a5a3a", b_height=1.9, b_bulk=1.15, b_muscle=1.0, eyeGlow=0.5, c_glow="#ff7a30"),
    P((1.0, "Shackled", "", ""), (0.5, "Unchained", "No more chains! Only fire!", "fire", {"speed": 1.15, "element": "fire", "glow": 0.8})),
    ("Cinder Storm", "chain_orbit", {"damage": 1.2, "element": "fire"}),
    ["Flail swings are wide but telegraphed", "Close range shuts down his chain"],
    {"posture": 1.15}, "Chains... I know chains.", "Free... at last...", weapon_look={"glow": "#ff7a30", "glowStrength": 0.5, "element": "fire"}))
B.append(boss("morrow", "The Slag Giant Morrow", "Maul of Ruin", 5, "maul",
    "A giant who fell into the slag pits and climbed out harder than stone.",
    "Colossal slag-crusted giant with a skull helm and a building-sized maul.",
    V(outfit="bare", pauldrons="large", helmet="skull", hair="none", arms="gauntlets", legs="greaves", skirt="loincloth", extras=["chains", "spikes"],
      c_primary="#2a2420", c_metal="#3a3432", armorMaterial="dark", skin="#4a3a32", eyeGlow=0.8, c_glow="#ff5a20", b_height=3.3, b_bulk=1.55, b_belly=0.5),
    P((1.0, "Tremor", "", ""), (0.5, "Collapse", "RUIN... EVERYTHING...", "fire", {"speed": 1.1, "element": "fire", "glow": 0.8})),
    ("Maul of Ruin", "execution", {"damage": 1.2, "aoe": 3.2}),
    ["Colossally slow: every swing is a punish window", "Leaping slams shake the arena: dodge late"],
    {"heavy": 1.3, "posture": 0.85}, "...small... thing...", "...ruin... rests...", stats={"radius": 0.95, "poise": 110}, weapon_look={"scale": 1.5}))
B.append(boss("gaunt", "Butcher-Smith Gaunt", "Giant Cleaver", 5, "giant_cleaver",
    "He smiths by day and butchers by night; the cleaver never needs sharpening.",
    "Gaunt, towering butcher in a bloodied leather apron and hood, massive cleaver.",
    V(outfit="tunic", chest="leather", helmet="hood", arms="sleeves", legs="boots", skirt="kilt", extras=["belt", "skulls", "pouches"],
      c_primary="#3a1a14", c_secondary="#6a1010", skin="#9a7a6a", b_height=2.4, b_bulk=1.0, b_hunch=15),
    P((1.0, "Carving", "", ""), (0.5, "Slaughter", "Meat is meat.", "red", {"speed": 1.2, "aggression": 1.3})),
    ("Butcher's Block", "heavy_combo", {"damage": 1.25, "telegraph": "gold"}),
    ["Cleaver grabs are red and deadly", "Very long recovery after his execution stroke"],
    {"bleed": 1.2, "posture": 1.0}, "Fresh cut.", "Closed... for business...", stats={"radius": 0.6, "poise": 55}, weapon_look={"scale": 1.2}))

# ---------------------------------------------------------------- Tier 6: The Frost Citadel
B.append(boss("edric", "Sir Edric Hoarfrost", "Zweihander of the Long Winter", 6, "zweihander",
    "Knight of a winter that never ended; his oath froze with him.",
    "Frost-rimed knight in pale plate and great helm, icicle cape, long zweihander.",
    V(outfit="armor", chest="plate", pauldrons="large", helmet="great", arms="gauntlets", legs="greaves", skirt="tassets", cape="long",
      c_primary="#8aa0b8", c_secondary="#c0d8f0", c_metal="#b8c8d8", frost=0.8, eyeGlow=0.7, c_glow="#8ad8ff", b_height=2.05, b_bulk=1.15),
    P((1.0, "Vigil", "", ""), (0.5, "Long Winter", "The winter does not end. Neither do I.", "frost", {"speed": 1.12, "element": "ice", "glow": 1.0})),
    ("Long Winter", "combo5", {"damage": 1.2, "element": "ice", "aoe": 1.8}),
    ["Wide zweihander arcs: dodge in, not away", "Deflects often in phase one"],
    {"posture": 1.0}, "Another pilgrim frozen in the pass.", "Spring... at last...", stats={"deflect": 0.3},
    weapon_look={"metal": "#c8d8e8", "glow": "#8ad8ff", "glowStrength": 0.4, "element": "ice"}))
B.append(boss("solveig", "Glaive-Knight Solveig", "Blizzard's Arc", 6, "glaive",
    "She dances through blizzards; the snow falls around her blade and never on it.",
    "Graceful knight in blue scale armor and winged helm, white fur cloak, broad glaive.",
    V(outfit="armor", chest="scale", pauldrons="fur", helmet="crested", arms="bracers", legs="greaves", skirt="tassets", cape="long",
      c_primary="#2a4a7a", c_secondary="#e8f0ff", c_metal="#a8b8c8", frost=0.5, b_height=1.88),
    P((1.0, "Snowfall", "", ""), (0.5, "Blizzard", "Lose yourself in the white.", "frost", {"speed": 1.15, "element": "ice"})),
    ("Blizzard's Arc", "whirlwind", {"damage": 1.2, "element": "ice"}),
    ["Spinning arcs are red: dodge through", "Glaive thrusts are straightforward to parry"],
    {"posture": 1.1}, "The storm is beautiful, isn't it?", "The snow... settles...", stats={"deflect": 0.25}))
B.append(boss("isolde", "Lady Isolde Rime", "The Frost Rapier", 6, "frost_rapier",
    "The citadel's fencing mistress, whose blade grows colder with each lesson.",
    "Elegant duelist in a white coat with frost-lace, pale hair, an ice-crystal rapier.",
    V(outfit="coat", chest="cuirass", helmet="circlet", hair="ponytail", arms="sleeves", legs="boots", skirt="coat", cape="short",
      c_primary="#e8f0f8", c_secondary="#7ab0e0", c_hair="#f0f4ff", skin="#e0d0d0", frost=0.6, eyeGlow=0.5, c_glow="#9ae0ff", b_height=1.74),
    P((1.0, "Lesson", "", ""), (0.5, "Absolute Zero", "Lesson two. Stillness.", "frost", {"speed": 1.2, "element": "ice", "glow": 1.0})),
    ("Rime Lunge", "lunge", {"damage": 1.3, "element": "ice", "telegraph": "gold"}),
    ["Precise, fast thrusts: learn her rhythm", "Feints often; watch for purple"],
    {"bleed": 1.2, "posture": 1.1}, "En garde.", "A worthy... pupil...", stats={"deflect": 0.35},
    weapon_look={"glow": "#9ae0ff", "glowStrength": 1.0, "element": "ice"}))
B.append(boss("harrow", "Lancer Harrow", "Charge of the Avalanche", 6, "lance",
    "His charge once broke an army. His horse fell long ago; he still charges.",
    "Heavy cavalry knight without a horse, frosted plate, vamplate lance, tattered banner cape.",
    V(outfit="armor", chest="plate", pauldrons="layered", helmet="sallet", arms="gauntlets", legs="greaves", skirt="tassets", cape="tattered",
      c_primary="#5a6a80", c_secondary="#3a4a6a", c_metal="#9aa8b8", frost=0.6, b_height=2.0, b_bulk=1.2),
    P((1.0, "Rider", "", ""), (0.5, "Avalanche", "CHARGE!", "frost", {"speed": 1.15, "element": "ice", "aggression": 1.3})),
    ("Avalanche Charge", "charge", {"damage": 1.3, "element": "ice"}),
    ["Arena charges are red: dodge sideways at the last moment", "Terrible close-range defense"],
    {"heavy": 1.2}, "Lower your blade and I'll ride around you.", "The horse... waits...", stats={"poise": 50}))
B.append(boss("kjell", "Frost Warden Kjell", "Bardiche of the Glacier Gate", 6, "bardiche",
    "The gate's last warden; his bardiche has cleaved glaciers.",
    "Huge bearded warden in fur and frosted mail, horned helm, crescent-bladed bardiche.",
    V(outfit="armor", chest="chain", pauldrons="fur", helmet="horned", beard="braided", arms="gauntlets", legs="boots", skirt="kilt", cape="long",
      c_primary="#3a3a44", c_secondary="#6a5a4a", c_hair="#d0d8e0", skin="#c0a090", frost=0.7, b_height=2.2, b_bulk=1.35),
    P((1.0, "Gatekeeper", "", ""), (0.66, "Glacier", "The glacier moves.", "frost", {"speed": 1.1, "element": "ice"}),
      (0.33, "Calving", "And the glacier breaks!", "frost", {"speed": 1.2, "glow": 1.0, "aggression": 1.3})),
    ("Glacier Cleave", "execution", {"damage": 1.2, "element": "ice", "aoe": 2.6}),
    ["Enormous posture damage when blocking: parry, don't block", "Slow to turn: circle him"],
    {"posture": 0.9, "heavy": 1.2}, "The gate is closed.", "The gate... opens...", stats={"radius": 0.6, "poise": 70},
    weapon_look={"element": "ice", "glow": "#8ad8ff", "glowStrength": 0.3}))

# ---------------------------------------------------------------- Tier 7: The Hollow Court
B.append(boss("lysander", "Viscount Lysander Pale", "The First Riposte", 7, "rapier",
    "The court's first duelist; he has never attacked first, and never needed to.",
    "Pale aristocrat in a black brocade coat and lace, powdered hair, needle-thin rapier.",
    V(outfit="coat", chest="none", helmet="none", hair="ponytail", arms="sleeves", legs="boots", skirt="coat", cape="short",
      c_primary="#1a1420", c_secondary="#d8d0c8", c_hair="#e0e0e8", skin="#e8d8d0", b_height=1.8, b_bulk=0.85),
    P((1.0, "Etiquette", "", ""), (0.5, "Riposte", "Enough manners.", "dark", {"speed": 1.2, "aggression": 1.4})),
    ("First Riposte", "combo6", {"damage": 1.1, "telegraph": "gold"}),
    ["Deflects idle attacks constantly: parry-bait him", "His combos are long but light"],
    {"bleed": 1.3, "posture": 1.2}, "Shall we dance?", "How... uncouth...", stats={"deflect": 0.45}))
B.append(boss("corvina", "Madame Corvina", "Dual Sabers of the Masquerade", 7, "saber",
    "Hostess of the eternal masquerade; no guest has ever left.",
    "Masked noblewoman in a crimson ballgown-coat, feathered collar, twin sabers.",
    V(outfit="robe", helmet="mask", hair="long", arms="sleeves", legs="boots", skirt="long", extras=["fur_collar"],
      c_primary="#6a0a1a", c_secondary="#1a0a10", c_metal="#d8c8a0", c_hair="#1a0a0a", skin="#e8d0c8", b_height=1.76, b_bulk=0.9),
    P((1.0, "Waltz", "", ""), (0.5, "Masquerade", "Remove your mask. Oh — it's your face.", "red", {"speed": 1.2})),
    ("Masquerade Waltz", "twin_spin", {"damage": 1.2, "telegraph": "gold"}),
    ["Two-blade strings: stay patient and parry each hit", "Spin attacks leave her dizzy"],
    {"bleed": 1.2}, "Welcome to my masquerade.", "The music... stops...", stats={"deflect": 0.3}))
B.append(boss("ambrose", "Lord Ambrose Thorne", "The Sword Cane", 7, "sword_cane",
    "A gentleman never draws his blade in public. The court is not public.",
    "Elderly lord in a top-coat and circlet, walking cane that hides a slender sword.",
    V(outfit="coat", helmet="circlet", hair="short", beard="full", arms="sleeves", legs="boots", skirt="coat",
      c_primary="#2a1a2a", c_secondary="#5a4a3a", c_hair="#d8d8d8", skin="#d8b8a8", b_height=1.8, b_hunch=10),
    P((1.0, "Gentleman", "", ""), (0.5, "Thorn", "My patience, like my cane, has limits.", "dark", {"speed": 1.2, "aggression": 1.3})),
    ("Thorn's Courtesy", "feint_thrust", {"damage": 1.4, "telegraph": "gold"}),
    ["Master of feints: purple shimmer means wait", "Fragile posture once you break his rhythm"],
    {"posture": 1.3}, "Mind your manners.", "Most... improper...", stats={"deflect": 0.4}))
B.append(boss("veyra", "Countess Veyra", "Blade and Parry", 7, "rapier_dagger",
    "She wrote the court's fencing manual in the blood of its critics.",
    "Sharp-featured countess in a dark doublet and cape, rapier in one hand, parrying dagger in the other.",
    V(outfit="coat", chest="cuirass", helmet="none", hair="ponytail", arms="sleeves", legs="boots", skirt="coat", cape="short",
      c_primary="#2a0a2a", c_secondary="#8a6a2a", c_hair="#3a1a0a", skin="#e0c0b0", b_height=1.78),
    P((1.0, "Chapter One", "", ""), (0.66, "Chapter Two", "Page two: the counterattack.", "dark", {"speed": 1.1}),
      (0.33, "Final Chapter", "The last page is always red.", "red", {"speed": 1.2, "aggression": 1.4})),
    ("Manual of Blood", "combo8", {"damage": 1.1, "telegraph": "gold"}),
    ["Parrying dagger deflects often", "Her eight-hit cascade ends with a gold-flash slam"],
    {"bleed": 1.2}, "Chapter one: introductions.", "The... end...", stats={"deflect": 0.45}))
B.append(boss("malachar", "Duke Malachar", "Estoc of the Empty Throne", 7, "estoc",
    "Champion of the Hollow King, who guards a throne that no one has sat on in a century.",
    "Hollow-eyed duke in ornate gilded plate and a spiked crown, violet cape, long estoc.",
    V(outfit="armor", chest="plate", pauldrons="wings", helmet="crown", arms="gauntlets", legs="greaves", skirt="tassets", cape="long",
      c_primary="#2a1a3a", c_secondary="#5a2a8a", c_metal="#c8b070", armorMaterial="gold", eyeGlow=1.0, c_glow="#b07aff", b_height=2.0),
    P((1.0, "Court", "", ""), (0.5, "Hollow King's Will", "The throne demands a sacrifice.", "dark", {"speed": 1.15, "element": "shadow", "glow": 1.0})),
    ("Empty Throne", "execution", {"damage": 1.2, "element": "shadow", "aoe": 2.2}),
    ["Two-handed estoc thrusts are long-range but linear", "Shadow bursts follow his execution"],
    {"posture": 1.0}, "Kneel before the empty throne.", "The throne... stays empty...", stats={"deflect": 0.3},
    weapon_look={"glow": "#b07aff", "glowStrength": 0.4, "element": "shadow"}))

# ---------------------------------------------------------------- Tier 8: The Storm Peaks
B.append(boss("aiko", "Windcaller Aiko", "War Fan of the Gale", 8, "war_fan",
    "She opens her fan and the wind obeys; she closes it and the wind cuts.",
    "Agile storm priestess in layered blue robes, straw hat, iron war fan crackling with sparks.",
    V(outfit="robe", helmet="strawhat", hair="long", arms="bell", legs="hakama", skirt="robe", extras=["sash", "beads"],
      c_primary="#1a2a5a", c_secondary="#e0e8ff", c_hair="#101010", skin="#e0c0a0", b_height=1.7, eyeGlow=0.4, c_glow="#9ac8ff"),
    P((1.0, "Breeze", "", ""), (0.5, "Gale", "Feel the wind turn against you.", "storm", {"speed": 1.2, "element": "lightning", "glow": 1.0})),
    ("Gale Dance", "whirlwind", {"damage": 1.1, "element": "lightning"}),
    ["Fan slashes are quick but light", "Lightning bursts are short range: stay mobile"],
    {"bleed": 1.2, "posture": 1.1}, "The wind brought you here. It will carry you away.", "The wind... stills...", stats={"deflect": 0.3},
    weapon_look={"glow": "#9ac8ff", "glowStrength": 0.5, "element": "lightning"}))
B.append(boss("tesra", "Coilwhip Tesra", "Chain Whip of the Stormfront", 8, "chain_whip",
    "Her whip cracks like thunder because it is thunder.",
    "Wild-haired stormrider in leather and fur, lightning scars, segmented chain whip.",
    V(outfit="tunic", chest="leather", pauldrons="fur", helmet="none", hair="wild", arms="bracers", legs="boots", skirt="tattered", extras=["belt"],
      c_primary="#2a2a3a", c_secondary="#4a4a7a", c_hair="#e0e8ff", skin="#c8a888", b_height=1.78, eyeGlow=0.7, c_glow="#8ab8ff"),
    P((1.0, "Crackle", "", ""), (0.5, "Thunderhead", "HERE COMES THE STORM!", "storm", {"speed": 1.2, "element": "lightning", "glow": 1.0})),
    ("Thunderlash", "chain_combo", {"damage": 1.2, "element": "lightning"}),
    ["Whip reach is long: close in after each lash", "Snares are red"],
    {"posture": 1.1}, "Hear that? That's your heartbeat, running.", "The storm... passes...",
    weapon_look={"glow": "#8ab8ff", "glowStrength": 0.6, "element": "lightning"}))
B.append(boss("saito", "Reaper Saito", "Twin Kama of the Lightning Harvest", 8, "kama",
    "A farmer who harvested rice with lightning-struck sickles, then harvested bandits.",
    "Wiry farmer-warrior with a straw hat and cloth wraps, twin kama sickles sparking.",
    V(outfit="gi", helmet="strawhat", hair="short", arms="wraps", legs="wraps", extras=["sash"],
      c_primary="#4a4a2a", c_secondary="#2a2a1a", skin="#b08060", b_height=1.72, b_bulk=0.9),
    P((1.0, "Harvest", "", ""), (0.5, "Lightning Harvest", "The storm brings the harvest.", "storm", {"speed": 1.22, "element": "lightning", "glow": 0.8})),
    ("Lightning Harvest", "flurry", {"damage": 1.2, "element": "lightning"}),
    ["Hook grabs with the kama: dodge the red", "Relentless flurries: perfect parry the gold ender"],
    {"bleed": 1.3}, "The rice is ripe.", "A good... harvest...", stats={"deflect": 0.25}, weapon_look={"glow": "#aaccff", "glowStrength": 0.3, "element": "lightning"}))
B.append(boss("oda", "Stormspear Oda", "Spear of the Ninth Thunder", 8, "storm_spear",
    "Struck by lightning nine times; he stopped counting and started aiming.",
    "Towering spearman in thunder-blue lacquered armor, kabuto with crescent crest, storm spear.",
    V(outfit="armor", chest="cuirass", pauldrons="layered", helmet="kabuto", arms="gauntlets", legs="hakama", skirt="tassets", cape="short",
      c_primary="#1a2a6a", c_secondary="#e0e8ff", armorMaterial="lacquer", eyeGlow=0.6, c_glow="#9ac8ff", b_height=2.05),
    P((1.0, "Rumble", "", ""), (0.66, "Ninth Strike", "Nine times it struck me.", "storm", {"speed": 1.12, "element": "lightning"}),
      (0.33, "Thunderlord", "Now I strike back!", "storm", {"speed": 1.2, "glow": 1.4, "aggression": 1.3})),
    ("Ninth Thunder", "pole_vault", {"damage": 1.3, "element": "lightning", "aoe": 2.6}),
    ["Vaulting crashes burst with lightning", "Triple thrusts end in a gold flash"],
    {"posture": 1.0}, "The sky is on my side.", "The sky... falls silent...", stats={"deflect": 0.25},
    weapon_look={"glow": "#9ac8ff", "glowStrength": 0.8, "element": "lightning"}))
B.append(boss("guan_lei", "General Guan Lei", "Thunder Lord's Guandao", 8, "guandao",
    "The storm general who never lost a battle under a clouded sky.",
    "Imposing general in heavy lamellar armor and flowing beard, red sash, massive guandao.",
    V(outfit="armor", chest="scale", pauldrons="large", helmet="crested", beard="long", arms="gauntlets", legs="greaves", skirt="tassets", cape="long",
      c_primary="#6a0a0a", c_secondary="#2a2a2a", c_metal="#8a7a5a", c_hair="#1a1a1a", skin="#b88a68", b_height=2.15, b_bulk=1.3),
    P((1.0, "General", "", ""), (0.66, "Stormfront", "The front advances.", "storm", {"speed": 1.12, "element": "lightning"}),
      (0.33, "Thunder Lord", "BOW TO THE STORM!", "storm", {"speed": 1.2, "glow": 1.2, "aggression": 1.3})),
    ("Thunder Lord's Judgment", "heavy_combo", {"damage": 1.3, "element": "lightning", "aoe": 2.6}),
    ["Sweeping guandao arcs: stay inside his reach", "Every third-phase slam bursts with lightning"],
    {"posture": 1.0, "heavy": 1.15}, "A soldier without an army? Brave. Foolish.", "The storm... breaks...",
    stats={"radius": 0.55, "poise": 60, "deflect": 0.2}, weapon_look={"glow": "#9ac8ff", "glowStrength": 0.3, "element": "lightning"}))

# ---------------------------------------------------------------- Tier 9: The Eclipse Sanctum
B.append(boss("nyx", "Nyx of the Hidden Claw", "Dual Katars", 9, "katar",
    "The sanctum's first assassin; nobody has seen her face and lived.",
    "Masked assassin in black wrappings and a cowl, violet eyes, twin punching katars.",
    V(outfit="tunic", chest="leather", helmet="cowl", arms="wraps", legs="wraps", skirt="tattered", cape="scarf", extras=["belt"],
      c_primary="#141018", c_secondary="#3a1a5a", skin="#c8a898", eyeGlow=1.0, c_glow="#b07aff", b_height=1.7, b_bulk=0.85),
    P((1.0, "Shadow", "", ""), (0.66, "Umbra", "You can't parry what you can't see.", "void", {"speed": 1.15, "element": "shadow"}),
      (0.33, "Totality", "The eclipse is complete.", "void", {"speed": 1.25, "glow": 1.0, "aggression": 1.4})),
    ("Hidden Claw", "flurry", {"damage": 1.3, "element": "shadow"}),
    ["Blindingly fast flurries: parry rhythmically", "Very low health and posture"],
    {"bleed": 1.3, "posture": 1.2}, "...", "...seen...", stats={"deflect": 0.3}, weapon_look={"glow": "#b07aff", "glowStrength": 0.4, "element": "shadow"}))
B.append(boss("mordaine", "The Pale Reaper Mordaine", "Reaper Scythe", 9, "reaper_scythe",
    "The sanctum's executioner. His scythe reaps souls; his hood hides none.",
    "Skeletal reaper in tattered black robes and skull mask, glowing violet eyes, long scythe.",
    V(outfit="robe", helmet="skull", arms="bell", legs="wraps", skirt="tattered", cape="tattered", extras=["chains"],
      c_primary="#0e0c12", c_secondary="#2a1a3a", skin="#d8d0c8", eyeGlow=1.2, c_glow="#9a6aff", b_height=2.2, b_bulk=0.8),
    P((1.0, "Toll", "", ""), (0.66, "Harvest", "The harvest has begun.", "void", {"speed": 1.12, "element": "shadow"}),
      (0.33, "Final Toll", "All things end.", "void", {"speed": 1.2, "glow": 1.4})),
    ("Final Toll", "whirlwind", {"damage": 1.3, "element": "shadow"}),
    ["Scythe hooks grab: dodge the red", "Wide sweeps: dodge through, toward him"],
    {"posture": 1.0, "heavy": 1.2}, "Your name is written.", "...even death... ends...", stats={"radius": 0.5, "deflect": 0.2},
    weapon_look={"glow": "#9a6aff", "glowStrength": 0.8, "element": "shadow"}))
B.append(boss("kiri", "Shade-Weaver Kiri", "Kusarigama of the Veil", 9, "kusarigama",
    "She weaves shadows with her chain; the veil between worlds is her loom.",
    "Veiled shinobi in dark layered cloth, long ponytail, kusarigama trailing violet light.",
    V(outfit="gi", helmet="mask", hair="ponytail", arms="wraps", legs="hakama", cape="scarf", extras=["sash", "belt"],
      c_primary="#1a1422", c_secondary="#5a2a7a", c_hair="#0a0a0a", skin="#d8b8a8", eyeGlow=0.8, c_glow="#c07aff", b_height=1.72),
    P((1.0, "Veil", "", ""), (0.5, "Loom of Shadows", "The veil tears.", "void", {"speed": 1.2, "element": "shadow", "glow": 1.0})),
    ("Veil Snare", "chain_grab", {"damage": 1.3, "element": "shadow"}),
    ["Mirrors your own chain tricks", "Chain snares are red"],
    {"posture": 1.1}, "The veil is thin tonight.", "Through... the veil...", stats={"deflect": 0.3}, weapon_look={"glow": "#c07aff", "glowStrength": 0.6, "element": "shadow"}))
B.append(boss("saryn", "Urumi Dancer Saryn", "The Whip-Sword", 9, "urumi",
    "Her dance is a prayer; her urumi is the amen.",
    "Graceful dancer in flowing purple silks and golden circlet, a coiled urumi whip-sword.",
    V(outfit="robe", helmet="circlet", hair="braid", arms="bell", legs="hakama", skirt="long", extras=["sash", "beads"],
      c_primary="#4a1a5a", c_secondary="#d8b060", c_hair="#1a0a0a", skin="#b88a6a", b_height=1.74, eyeGlow=0.6, c_glow="#d0a0ff"),
    P((1.0, "Prayer", "", ""), (0.66, "Ecstasy", "Dance with me.", "void", {"speed": 1.15, "element": "shadow"}),
      (0.33, "Amen", "The dance must end.", "void", {"speed": 1.25, "glow": 1.2})),
    ("Ribbon of Knives", "chain_orbit", {"damage": 1.2, "element": "shadow"}),
    ["The urumi's reach varies: watch the coil", "Orbit spins are red"],
    {"bleed": 1.3}, "Will you dance?", "The music... fades...", weapon_look={"glow": "#d0a0ff", "glowStrength": 0.5, "element": "shadow"}))
B.append(boss("vesper", "Vesper", "The Eclipse Twin-Blade", 9, "shadow_blade",
    "High assassin of the sanctum; each blade was forged from half of an eclipse.",
    "Tall assassin in black plate and a flowing cape, halo of dark fire, twin curved shadow blades.",
    V(outfit="armor", chest="plate", pauldrons="spiked", helmet="cowl", arms="gauntlets", legs="greaves", skirt="tattered", cape="long", extras=["halo"],
      c_primary="#0e0a14", c_secondary="#3a1a5a", c_metal="#2a2632", armorMaterial="obsidian", eyeGlow=1.2, runes=0.8, c_glow="#9a5aff", b_height=1.9),
    P((1.0, "Penumbra", "", ""), (0.66, "Umbra", "Half the sun is gone.", "void", {"speed": 1.12, "element": "shadow", "glow": 1.0}),
      (0.33, "Eclipse", "Now, darkness.", "void", {"speed": 1.25, "glow": 2.0, "aggression": 1.4})),
    ("Eclipse Cross", "cross_slash", {"damage": 1.4, "element": "shadow", "aoe": 2.2, "telegraph": "gold"}),
    ["Long twin-blade strings: parry each hit, punish the gold", "Shadow bursts follow cross slashes"],
    {"posture": 1.0}, "The sun sets on you.", "...dawn...", stats={"deflect": 0.35}, weapon_look={"glow": "#9a5aff", "glowStrength": 0.8, "element": "shadow"}))

# ---------------------------------------------------------------- Tier 10: The Throne of Blades (weapon switchers)
B.append(boss("aldric", "Aldric the Unyielding", "Champion of Iron", 10, "longsword",
    "Every garrison sergeant learns his name first. He wields every weapon they ever carried.",
    "Legendary knight in blackened plate with golden trim, great helm, crimson cape.",
    V(outfit="armor", chest="plate", pauldrons="large", helmet="great", arms="gauntlets", legs="greaves", skirt="tassets", cape="long",
      c_primary="#3a0a0a", c_secondary="#8a1010", c_metal="#3a3a40", c_trim="#d8b060", armorMaterial="dark", runes=0.5, c_glow="#ffb040", b_height=2.05, b_bulk=1.2),
    P((1.0, "Sword and Shield", "", "", {"weapon": 0}), (0.66, "Zweihander", "Enough defense.", "red", {"weapon": 1, "speed": 1.1}),
      (0.33, "Halberd", "The last line is mine.", "red", {"weapon": 2, "speed": 1.2, "glow": 1.0})),
    ("Iron Arsenal", "swap_combo", {"damage": 1.3}),
    ["Each phase changes weapon: re-read his reach", "Arsenal Shift strings swap weapons mid-combo"],
    {"posture": 1.0}, "I have held every blade. Now I hold you.", "Iron... yields...",
    extra_weapons=[{"type": "zweihander", "metal": "#3a3a40", "glow": "#ffb040", "glowStrength": 0.3}, {"type": "halberd", "metal": "#3a3a40"}],
    stats={"deflect": 0.35}))
B.append(boss("mei_xiang", "Mei Xiang the Ninefold", "Champion of the Monastery", 10, "naginata",
    "She mastered nine monastery weapons before her twentieth year and has not stopped since.",
    "Legendary monk-warrior in crimson and gold robes over armor, crowned hair, weapons at her back.",
    V(outfit="robe", chest="cuirass", pauldrons="layered", helmet="circlet", hair="topknot", arms="bell", legs="hakama", skirt="robe", cape="scarf",
      c_primary="#8a0a0a", c_secondary="#d8b060", armorMaterial="gold", c_hair="#101010", b_height=1.78),
    P((1.0, "Crescent Form", "", "", {"weapon": 0}), (0.66, "River Form", "The river flows.", "red", {"weapon": 1, "speed": 1.12}),
      (0.33, "Bastion Form", "The mountain stands.", "red", {"weapon": 2, "speed": 1.2, "glow": 1.0})),
    ("Ninefold Path", "swap_combo", {"damage": 1.25}),
    ["Switches naginata, three-section staff and tonfa", "Deflects constantly in Bastion Form"],
    {"posture": 1.05}, "Nine paths. All lead to me.", "The tenth path... is yours...",
    extra_weapons=[{"type": "three_section_staff"}, {"type": "tonfa"}], stats={"deflect": 0.4}))
B.append(boss("karsk", "Karsk Ironjaw", "Champion of the Forge", 10, "warhammer",
    "The forge's champion, whose iron jaw was welded on after a giant bit off the first one.",
    "Monstrous smith-giant with an iron jaw, molten runes, leather and plate, weapons ablaze.",
    V(outfit="armor", chest="brigandine", pauldrons="spiked", helmet="mask", beard="none", arms="gauntlets", legs="greaves", skirt="kilt", extras=["chains", "spikes", "belt"],
      c_primary="#2a1410", c_metal="#3a3230", armorMaterial="dark", skin="#6a4030", eyeGlow=1.0, runes=1.0, c_glow="#ff5a10", b_height=2.6, b_bulk=1.5),
    P((1.0, "Anvil", "", "", {"weapon": 0}), (0.66, "Cleaver", "Carve!", "fire", {"weapon": 1, "speed": 1.1, "element": "fire"}),
      (0.33, "Cinder Flail", "BURN IT ALL!", "fire", {"weapon": 2, "speed": 1.2, "glow": 1.5})),
    ("Forgefire Arsenal", "swap_combo", {"damage": 1.35, "element": "fire", "aoe": 2.4}),
    ["Every weapon bursts with fire in later phases", "Huge but slow: dodge late, punish hard"],
    {"posture": 0.9, "heavy": 1.2}, "Fresh ore for the forge.", "The forge... goes cold...",
    extra_weapons=[{"type": "giant_cleaver", "glow": "#ff5a10", "glowStrength": 0.4, "element": "fire"},
                   {"type": "flail", "glow": "#ff5a10", "glowStrength": 0.6, "element": "fire"}],
    stats={"radius": 0.7, "poise": 90}, weapon_look={"scale": 1.2, "glow": "#ff5a10", "glowStrength": 0.3, "element": "fire"}))
B.append(boss("nocturne", "Lady Nocturne", "Champion of the Court", 10, "rapier_dagger",
    "The Hollow Court's undefeated champion, who fences with the court's three finest blades.",
    "Regal duelist in a black and silver gown-coat, silver circlet, dark veil, weapons at her hip.",
    V(outfit="coat", chest="cuirass", helmet="veil", hair="long", arms="sleeves", legs="boots", skirt="long", cape="long",
      c_primary="#0a0a12", c_secondary="#b8b8c8", c_metal="#d8d8e8", armorMaterial="metal", c_hair="#e8e8f0", eyeGlow=0.8, c_glow="#d0c0ff", b_height=1.82),
    P((1.0, "Rapier and Dagger", "", "", {"weapon": 0}), (0.66, "Twin Sabers", "Let's make this interesting.", "dark", {"weapon": 1, "speed": 1.15}),
      (0.33, "Estoc", "The final form of courtesy.", "red", {"weapon": 2, "speed": 1.2, "glow": 1.0, "element": "shadow"})),
    ("Nocturne", "swap_combo", {"damage": 1.3}),
    ["Deflects nearly everything: parry her strings instead", "Estoc phase adds shadow bursts"],
    {"bleed": 1.2}, "The court is in session.", "Court... adjourned...",
    extra_weapons=[{"type": "saber", "metal": "#d8d8e8"}, {"type": "estoc", "glow": "#d0c0ff", "glowStrength": 0.4, "element": "shadow"}],
    stats={"deflect": 0.5}))
B.append(boss("ravel", "Ravel the Last Storm", "Champion of the Peaks", 10, "storm_spear",
    "The last of the storm-knights; he carries every weapon the peaks ever forged.",
    "Storm-knight in silver-blue plate crackling with lightning, winged helm, tattered stormcloak.",
    V(outfit="armor", chest="plate", pauldrons="wings", helmet="crested", arms="gauntlets", legs="greaves", skirt="tassets", cape="tattered",
      c_primary="#1a2a5a", c_secondary="#e0e8ff", c_metal="#a8b8d8", eyeGlow=1.0, runes=1.0, c_glow="#8ac8ff", b_height=2.0),
    P((1.0, "Stormspear", "", "", {"weapon": 0}), (0.66, "Coilwhip", "Crack!", "storm", {"weapon": 1, "speed": 1.12, "element": "lightning"}),
      (0.33, "Guandao", "The last storm breaks!", "storm", {"weapon": 2, "speed": 1.22, "glow": 1.5})),
    ("Last Storm", "swap_combo", {"damage": 1.35, "element": "lightning", "aoe": 2.4}),
    ["Phase two whip has enormous reach", "Lightning bursts on every swapped strike"],
    {"posture": 1.0}, "Every storm ends. Not this one.", "Clear... skies...",
    extra_weapons=[{"type": "chain_whip", "glow": "#8ac8ff", "glowStrength": 0.6, "element": "lightning"},
                   {"type": "guandao", "glow": "#8ac8ff", "glowStrength": 0.6, "element": "lightning"}],
    stats={"deflect": 0.35}, weapon_look={"glow": "#8ac8ff", "glowStrength": 0.8, "element": "lightning"}))

# ---------------------------------------------------------------- Final boss
B.append(boss("sovereign", "The Blade Sovereign", "Master of the Five Blades", 11, "katana",
    "The first to walk the Blade Rush, and the last to ever finish it. It remembers every fighter it has ever faced — including you.",
    "A tall armored figure in obsidian and gold, crowned helm, halo, flowing cape; five weapons orbit its will.",
    V(outfit="armor", chest="plate", pauldrons="wings", helmet="crown", arms="gauntlets", legs="greaves", skirt="tassets", cape="long", extras=["halo"],
      c_primary="#0a0a10", c_secondary="#d8b060", c_metal="#1a1a22", c_trim="#ffd070", armorMaterial="obsidian", eyeGlow=1.4, runes=1.2,
      c_glow="#ffd070", b_height=2.1, b_bulk=1.1),
    P((1.0, "Katana and Greatsword", "", "", {"weapon": 0}),
      (0.75, "Daggers and Spear", "You fight well. You fight like me.", "void", {"weapon": 2, "speed": 1.08, "glow": 0.8}),
      (0.5, "Kusarigama", "Every blade you carry, I carried first.", "red", {"weapon": 4, "speed": 1.14, "glow": 1.2, "element": "shadow"}),
      (0.25, "Sovereign", "Then take the throne from me.", "dark", {"weapon": 0, "speed": 1.22, "glow": 2.0, "aggression": 1.4, "element": "holy"})),
    ("Five Blade Requiem", "swap_combo", {"damage": 1.4, "aoe": 2.4}),
    ["Mirrors your abilities: Iaido counters punish mindless attacks", "Each phase changes its weapon set: re-learn its reach",
     "Earthsplitter and Vaulting strikes burst on landing: dodge late"],
    {"posture": 1.0}, "At last. A worthy heir.", "The rush... ends... with you.",
    extra_weapons=[{"type": "greatsword", "metal": "#2a2a32", "glow": "#ffd070", "glowStrength": 0.4},
                   {"type": "dagger", "metal": "#2a2a32", "glow": "#ffd070", "glowStrength": 0.4},
                   {"type": "spear", "metal": "#2a2a32", "glow": "#ffd070", "glowStrength": 0.4},
                   {"type": "kusarigama", "metal": "#2a2a32", "glow": "#ffd070", "glowStrength": 0.6}],
    stats={"deflect": 0.4, "radius": 0.5},
    weapon_look={"metal": "#2a2a32", "glow": "#ffd070", "glowStrength": 0.5}))

TIERS = [
    (1, "The Outcast Yard", "Rusted blades", "outcast_yard"),
    (2, "The Iron Garrison", "Disciplined soldiers", "iron_garrison"),
    (3, "The Crimson Monastery", "Warrior monks", "crimson_monastery"),
    (4, "The Drowned Harbor", "Pirates and sea raiders", "drowned_harbor"),
    (5, "The Ashen Forge", "Smiths and giants", "ashen_forge"),
    (6, "The Frost Citadel", "Ice knights", "frost_citadel"),
    (7, "The Hollow Court", "Noble duelists", "hollow_court"),
    (8, "The Storm Peaks", "Lightning-touched warriors", "storm_peaks"),
    (9, "The Eclipse Sanctum", "Shadow assassins", "eclipse_sanctum"),
    (10, "The Throne of Blades", "Legendary champions", "throne_of_blades"),
]

GAUNTLETS = [
    ("gauntlet_shield_spear", "Gauntlet I: Shield and Spear", "Sergeant Halvard & Pikewarden Brisa", ["halvard", "brisa"], "iron_garrison"),
    ("gauntlet_deep_chains", "Gauntlet II: Chains of the Deep Forge", "Anchorlord Brannoc & Chainbrand Ezzo", ["brannoc", "ezzo"], "ashen_forge"),
    ("gauntlet_eclipse_twins", "Gauntlet III: The Eclipse Twins", "Nyx & Vesper", ["nyx", "vesper"], "eclipse_sanctum"),
]

ARENA_BY_TIER = {t[0]: t[3] for t in TIERS}
ARENA_BY_TIER[11] = "sovereign_void"

ATTACK_NAME_WORDS = {
    1: ["Rust", "Scrap", "Mud", "Gutter", "Ragged"], 2: ["Iron", "Garrison", "Drill", "Rampart", "Vanguard"],
    3: ["Crimson", "Temple", "Lotus", "Ember", "Prayer"], 4: ["Brine", "Tidal", "Gale", "Barnacle", "Wreck"],
    5: ["Cinder", "Slag", "Molten", "Anvil", "Ash"], 6: ["Rime", "Glacial", "Frost", "Winter", "Hoarfrost"],
    7: ["Gilded", "Courtly", "Velvet", "Masque", "Hollow"], 8: ["Thunder", "Storm", "Squall", "Lightning", "Tempest"],
    9: ["Umbral", "Eclipse", "Veiled", "Nightfall", "Void"], 10: ["Sovereign", "Legend", "Throne", "Champion", "Blood"],
    11: ["Requiem", "Sovereign", "Final", "Five-Blade", "Crowned"],
}

def attack_name(tpl, tier, rng):
    base = {"sweep_h": "Sweep", "sweep_hb": "Backhand", "overhead": "Cleave", "diagonal": "Slash", "rising": "Rising Cut",
            "quick_jab": "Jab", "thrust": "Thrust", "lunge": "Lunge", "spin": "Spiral", "leap_slam": "Leaping Crash",
            "low_sweep": "Ankle Reaper", "delayed_overhead": "Patient Cleave", "delayed_sweep": "Hesitation Cut",
            "feint_thrust": "False Thrust", "feint_sweep": "False Overhead", "double_slash": "Twin Cut", "combo3": "Triple Rite",
            "combo4": "Four Verses", "combo5": "Onslaught", "combo6": "Tempest String", "combo8": "Cascade", "grab": "Hook and Crush",
            "shield_bash": "Shield Bash", "bash_combo": "Bash and Pierce", "charge": "Charge", "whirlwind": "Whirlwind",
            "burst_slam": "Burst", "retreat_slash": "Parting Cut", "step_thrust": "Side-Step Thrust", "flurry": "Flurry",
            "cross_slash": "Cross", "twin_spin": "Twin Spiral", "pole_sweep": "Pole Sweep", "pole_thrust": "Long Thrust",
            "pole_triple": "Triple Point", "pole_vault": "Vaulting Crash", "chain_lash": "Chain Lash", "chain_thrust": "Chain Strike",
            "chain_sweep": "Floor Sweep", "chain_orbit": "Orbit", "chain_grab": "Snare", "chain_combo": "Chain Barrage",
            "heavy_cleave": "Crushing Cleave", "heavy_sweep": "Earthshaker", "heavy_combo": "Titan String", "swap_combo": "Arsenal Shift",
            "swap_back": "Return Blade", "execution": "Execution"}[tpl]
    return f"{rng.choice(ATTACK_NAME_WORDS[tier])} {base}"

SOVEREIGN_ATTACKS = [
    # (name, template, extras) - slots: 0 katana, 1 greatsword, 2 daggers, 3 spear, 4 kusarigama
    ("Sovereign Draw", "mirror_iaido", {"swapTo": 0}),
    ("Katana Rite", "combo4", {"swapTo": 0}),
    ("Crescent Edge", "sweep_h", {"swapTo": 0}),
    ("Greatsword Descent", "heavy_cleave", {"swapTo": 1}),
    ("Mirrored Earthsplitter", "leap_slam", {"swapTo": 1, "aoe": 3.0, "damage": 1.1}),
    ("Mirrored Blood Dance", "mirror_blood_dance", {"swapTo": 2, "minPhase": 2}),
    ("Twin Spiral", "twin_spin", {"swapTo": 2, "minPhase": 2}),
    ("Mirrored Vault", "pole_vault", {"swapTo": 3, "minPhase": 2}),
    ("Spear Triad", "pole_triple", {"swapTo": 3, "minPhase": 2}),
    ("Mirrored Chain Pull", "chain_grab", {"swapTo": 4, "minPhase": 3}),
    ("Chain Orbit", "chain_orbit", {"swapTo": 4, "minPhase": 3}),
    ("Chain Barrage", "chain_combo", {"swapTo": 4, "minPhase": 3}),
    ("Return Blade", "swap_back", {"minPhase": 4}),
    ("Crowned Execution", "execution", {"swapTo": 1, "minPhase": 4, "aoe": 2.6}),
    ("Sovereign Onslaught", "combo8", {"swapTo": 0, "minPhase": 4}),
]

def build_attacks(b, rng):
    if b["id"] == "sovereign":
        out = []
        for (name, tpl, extra) in SOVEREIGN_ATTACKS:
            ref = {"use": tpl, "name": name}
            ref.update(extra)
            out.append(ref)
        out.append({"use": "combo6", "name": "Heir's Trial (Hard)", "hardOnly": True, "swapTo": 0, "damage": 1.1})
        sig_name, sig_tpl, sig_mod = b["signature"]
        sig = {"use": sig_tpl, "name": sig_name, "signature": True, "weight": 1.4, "cooldown": 7, "minPhase": 2}
        sig.update(sig_mod)
        out.append(sig)
        return out
    fam = FAMILY[b["weapon"]]
    tier = b["tier"]
    if b["id"] in TUTORIAL:
        pool = TUTORIAL[b["id"]]
    else:
        pool = list(POOLS[fam])
        if tier <= 1:
            pool = [p for p in pool if p not in ("combo6", "combo8", "whirlwind", "execution", "charge", "grab", "chain_grab")]
        elif tier <= 3:
            pool = [p for p in pool if p not in ("combo8",)]
    count = min(15, max(8, 8 + (tier - 1) // 2 + rng.randint(0, 2)))
    if b["id"] == "sovereign":
        count = 15
    chosen = []
    for p in pool:
        if len(chosen) >= count: break
        chosen.append(p)
    while len(chosen) < count:
        chosen.append(rng.choice(pool))
    # Weapon swappers get swap attacks; tier 10 & final.
    if b["extra_weapons"]:
        chosen = [c for c in chosen if c not in ("swap_combo",)][:count - 2] + ["swap_combo", "swap_back"]
    out = []
    used_names = set()
    for i, tpl in enumerate(chosen):
        name = attack_name(tpl, min(tier, 11), rng)
        while name in used_names:
            name = attack_name(tpl, min(tier, 11), rng)
        used_names.add(name)
        ref = {"use": tpl, "name": name}
        # Later attacks unlock in later phases (bosses grow their movesets).
        nphases = len(b["phases"])
        if i >= count - 2 and nphases >= 2 and tpl not in ("swap_combo", "swap_back"):
            ref["minPhase"] = 2
        if i == count - 1 and nphases >= 3 and tpl not in ("swap_combo", "swap_back"):
            ref["minPhase"] = 3
        out.append(ref)
    # Hard mode exclusives.
    hard = rng.choice([t for t in POOLS[fam] if t not in chosen] or POOLS[fam])
    out.append({"use": hard, "name": attack_name(hard, min(tier, 11), rng) + " (Hard)", "hardOnly": True, "damage": 1.1})
    # Signature move.
    sig_name, sig_tpl, sig_mod = b["signature"]
    sig = {"use": sig_tpl, "name": sig_name, "signature": True, "weight": 1.4, "cooldown": 7}
    sig.update(sig_mod)
    out.append(sig)
    return out

def stats_for(b):
    t = b["tier"]
    s = {
        "health": 360 + 70 * (t - 1), "posture": 90 + 14 * (t - 1), "damage": round(0.82 + 0.052 * (t - 1), 3),
        "speed": round(0.86 + 0.035 * (t - 1), 3), "moveSpeed": round(3.0 + 0.1 * t, 2), "aggression": round(0.78 + 0.06 * (t - 1), 3),
        "postureRegen": round(0.9 + 0.04 * t, 3), "poise": 25 + 5 * t, "deflect": round(0.04 + 0.025 * (t - 1), 3), "radius": 0.45,
    }
    if t >= 11:
        s.update({"health": 1500, "posture": 240, "damage": 1.42, "speed": 1.2, "aggression": 1.45, "deflect": 0.4})
    h = b["visual"].get("body", {}).get("height", 1.8)
    if h > 2.3:
        s["health"] = int(s["health"] * (1 + (h - 2.3) * 0.35))
        s["speed"] = round(s["speed"] * 0.92, 3)
        s["moveSpeed"] = round(s["moveSpeed"] * 0.85, 2)
    s.update(b["stats"])
    return s

def main():
    rng_master = random.Random(1337)
    bosses_out = []
    for b in B:
        rng = random.Random(b["id"])
        weapon = {"type": b["weapon"]}
        weapon.update(b["weapon_look"])
        h = b["visual"].get("body", {}).get("height", 1.8)
        if h > 2.25 and "scale" not in weapon:
            weapon["scale"] = round(min(1.5, h / 1.9), 2)
        weapons = [weapon] + [dict(w) for w in b["extra_weapons"]]
        entry = {
            "id": b["id"], "name": b["name"], "title": b["title"], "tier": b["tier"], "lore": b["lore"], "description": b["desc"],
            "visual": b["visual"], "weapons": weapons, "stats": stats_for(b), "attacks": build_attacks(b, rng),
            "phases": b["phases"], "signature": b["signature"][0], "weaknesses": b["weaknesses"], "weakTo": b["weakTo"],
            "intro": b["intro"], "death": b["death"], "arena": ARENA_BY_TIER[b["tier"]],
        }
        bosses_out.append(entry)
    encounters = []
    tiers = []
    for (idx, name, sub, arena) in TIERS:
        ids = [b["id"] for b in B if b["tier"] == idx]
        encs = []
        for bid in ids:
            bb = next(x for x in B if x["id"] == bid)
            encounters.append({"id": bid, "name": bb["name"], "title": bb["title"], "kind": "boss", "bosses": [bid], "arena": arena, "tier": idx})
            encs.append(bid)
        tiers.append({"index": idx, "name": name, "subtitle": sub, "arena": arena, "encounters": encs})
    g_encs = []
    for (gid, gname, gtitle, bids, arena) in GAUNTLETS:
        encounters.append({"id": gid, "name": gname, "title": gtitle, "kind": "gauntlet", "bosses": bids, "arena": arena, "tier": 11})
        g_encs.append(gid)
    tiers.append({"index": 11, "name": "The Gauntlets", "subtitle": "Two at once", "arena": "iron_garrison", "encounters": g_encs})
    encounters.append({"id": "sovereign", "name": "The Blade Sovereign", "title": "Master of the Five Blades", "kind": "final",
                       "bosses": ["sovereign"], "arena": "sovereign_void", "tier": 12})
    tiers.append({"index": 12, "name": "The Sovereign's Void", "subtitle": "The final duel", "arena": "sovereign_void", "encounters": ["sovereign"]})
    out = {"bosses": bosses_out, "encounters": encounters, "tiers": tiers}
    path = os.path.join(ROOT, "Data", "bosses.json")
    with open(path, "w") as f:
        f.write("// BLADE RUSH — boss roster (generated by Scripts/gen_bosses.py, safe to hand-edit).\n")
        json.dump(out, f, indent=1)
    n_attacks = sum(len(b["attacks"]) for b in bosses_out)
    print(f"wrote {path}: {len(bosses_out)} bosses, {len(encounters)} encounters, {n_attacks} attack entries")

if __name__ == "__main__":
    main()
