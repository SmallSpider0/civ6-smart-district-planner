# Smart District Planner: install and use

The Chinese guide ([install-and-test.md](install-and-test.md) in the repository, `INSTALL_AND_USE.md` in the download) has more detail and the acceptance checklist. What the planner does, how close its plans come to the true optimum and its speed are on the [overview page](https://smallspider0.github.io/civ6-smart-district-planner/en/); what other district planners plan is in the README's [similar mods](../README.md#similar-mods).

## One planner per game

Do not enable Smart District Planner together with Auto Map Tacks Planner, Empire Planner or another mod that plans map tacks. They each simulate, create and delete map tacks, so two planners in one game spoil each other's plans.

## Requirements

- Civilization VI with the base game, Rise and Fall, or Gathering Storm rules. The mod detects the rules when a game starts.
- [Detailed Map Tacks](https://steamcommunity.com/sharedfiles/filedetails/?id=2428969051) (DMT) from the Steam Workshop, subscribed and enabled. The planner uses it for every placement rule and adjacency bonus.
- Tested on the macOS version 1.0.12.54 (Aspyr) with all three rulesets: every automated test, real mouse clicks and late-game saves. On Windows the co-developer has tested it by hand twice; the full acceptance checklist has not been run there yet.

## Install

1. Subscribe to [Smart District Planner](https://steamcommunity.com/sharedfiles/filedetails/?id=3824473635) and Detailed Map Tacks on the Steam Workshop.
2. Without the Workshop: download `SmartDistrictPlanner-<version>.zip` from the [releases page](https://github.com/SmallSpider0/civ6-smart-district-planner/releases/latest) and copy the `SmartDistrictPlanner` folder in it into the game's Mods folder (Detailed Map Tacks is still needed from the Workshop):
   - Windows: `Documents\My Games\Sid Meier's Civilization VI\Mods\`
   - macOS: `~/Library/Application Support/Sid Meier's Civilization VI/Sid Meier's Civilization VI/Mods/`

   You should end up with `Mods/SmartDistrictPlanner/SmartDistrictPlanner.modinfo`. To update, delete the old folder first. Keep only one copy: with one in Mods and one from the Workshop, the game loads only one of them, not necessarily the newer one or the one you enabled in Additional Content. When you switch to the Workshop, delete this folder.
3. Start the game, open **Additional Content** from the main menu and enable both **Detailed Map Tacks** and **Smart District Planner**. In a mod group you created yourself, new mods start disabled. Restart the game after enabling or updating mods.

## Open the panel

In a game, a hexagon button appears at the end of the toolbar at the upper left of the screen (its tooltip shows "Smart District Planner" and the version). Click it to open the panel; click it again or press Esc to close it. **Shift+L** also opens and closes it; you can change the key in **Options → Key Bindings**, under "Smart District Planner".

The panel has three tabs: **One city**, **City sites** and **Several cities**. The panel follows the game's language (English or Chinese).

- The window is as tall as the screen allows: shorter on a low screen, taller on a tall one, and the result list takes the difference.
- **View map**, at the upper left of the window, hides the window and keeps the plan previewed on the map; click **Back to planner** or press Esc to return.
- Each tab keeps its switches, weights, Effort and whether its settings are hidden in the save, so a loaded game opens as you left it. Nothing is sent to other players. The Must, Pool and Off states of districts are not kept.

## One city

1. **City**: the city selected on the map, otherwise your capital. Pick another one in the dropdown. Select another of your cities on the map and open the panel again, and the panel opens on the One city tab with that city; with no city selected, or the same one as last time, it opens on the tab you closed it on (neither happens while a plan is being computed in the background).
2. **Districts**, in two grids. Click a cell to change its state:
   - **Specialty districts**: Pool → Must → Off. Must is always placed, Off never. Pool districts are picked only when the district count is higher than the number of Must ones. Districts limited to one per empire (Government Plaza, Diplomatic Quarter) are Must or Off.
   - **Other districts** (Aqueduct, Dam, Canal, Neighborhood…): Auto → Must → Off. Auto exists for the Aqueduct and the Dam: an Aqueduct is added when the city lacks fresh water, a Dam (Gathering Storm) when 3 or more free Floodplains tiles lie within its 3 rings. The solver chooses their tiles.
   - Districts the city has built, and districts at the empire limit, are dimmed with the reason.
3. **Districts** (the number next to the city): how many specialty districts to plan, Must ones included; 3 by default (or the number of Must ones when there are more), so Solve right away picks from the pool. When it is higher than the number of Must ones, the rest are picked from the pool and you get three plans with different districts. Your specialty district slots for the current population are shown below it; going over only shows a warning.
4. **Settings line**: under the district grids, one line sums up the settings (such as "Settings: Balanced · 1 wonders", or "Balanced (changed)" once you change a weight); the wonders, good places, weights and switches below it can be hidden. They hide after each solve; click the line to show or hide them.
   **Wonders**: pick them from **Add a wonder**; each chosen wonder shows as a tag, and clicking the tag removes it. A wonder that needs a district next to it (the Colosseum needs an Entertainment Complex) gets one when the city has none (built, tacked for it, Must or added by itself): the district's cell says **Wonder**, Solve plans it as if it were Must, and its row says "(next to Colosseum)". It counts toward **Districts**. Set the district to Off and it is not added: the wonder is left out and the reason names the district. Remove the wonder and the cell is as before. Two wonders needing the same district get one. A Government Plaza already in another city cannot be added; the reason says which city it is in.
5. **Good places**: pick a district to see every tile it can go on, shaded on the map by the bonus it would get there alone.
6. **Weights (0–3)**, each click 0.5. The **Preset** dropdown beside the title sets the weights and switches: Balanced (all 1), Science (Science 1.5), Culture (Culture 3), Religion (Faith 3), Half Gold and Faith (Gold and Faith 0.5); once you change one it reads "(changed)", and **Reset** brings the preset back. Science, Culture, Faith, Gold and Production (default 1). **Tiles** (default 1) weighs what the tiles the districts take would have given; 0 leaves it out. A tile counts what it gives with its best improvement (a Mine on Hills, a Farm on flat land); chopping and harvesting are done before building, so they are not a loss, and the plan says "clear or harvest the tile first". Tile yields are weighed by fixed numbers, not by the yield weights: Food and Production 1, Science and Culture 5/6, Faith 1/2, Gold 1/4 (1 Production = 4 Gold = 2 Faith), and the same for the one-time yields of chopping and harvesting. **Dist.** (default 0) keeps districts close to the City Center; **Hous.** (default 1) scores the Housing of Neighborhoods and Preserves, which depends on their tile's Appeal; in each city, each Housing up to the population its planned districts need counts 1, each one after it half the one before. **Reach** (default 0) works as on the Several cities tab; on this tab your other cities and every City Center tack are the cities to cover.
7. **Switches** (hover each for details): **Allow chop** allows districts on Woods, Rainforest and Marsh; **Replace** treats this mod's earlier tacks for the city as gone and replaces them when you place the new ones (undo brings them back; tacks you placed or edited yourself are never touched); **Reminders** puts a "Don't chop" tack on Woods and Rainforest that the plan's adjacency depends on; **Keep apart** keeps a Harbor and a Commercial Hub in different cities, so the Lighthouse (in the base game, the Harbor itself) still gives its +1 Trade Route capacity.
8. **Effort**: Fast, Standard (default) or Thorough. The expected time is shown next to it; hover over each for its measured time and quality on the offline benchmark. Long computations run over several frames: you can keep playing or close the panel, and the button at the upper left gets a mark when the plan is ready.
9. **Solve** (greyed out while there is nothing to plan: no Must district, Districts at 0 and no wonder). A new result or another plan brings the city to the right of the panel. The plans are a row of buttons; hover one for the districts it picked, click it to preview it on the map; click a row with a tile to move the camera there. Each row gives a district's tile and bonus, and what to do first: expand or buy the tile, swap it from another of your cities (with the **Swap tiles** switch on, off by default: Swap in Manage Citizens, for a tile next to the city's territory with no district or wonder and not next to the other City Center; its tooltip gives the measured gain and cost), research a technology, or clear or harvest it; hover it for DMT's breakdown. **Improve** searches one more round and never makes the plan worse.
10. **Place tacks** puts a tack with the district's icon on every tile of the plan; DMT shows the same bonuses on them. **Undo tacks** removes the last batch, as often as you like, also after loading a save.

## City sites

1. **New cities** (1–6) and **Max distance** (4–15, 5 by default: how many tiles a new city may be from one of your cities, a City Center map tack or another new city, counted between the City Centers; new cities usually land at exactly this distance). Both are kept in the save like the weights.
2. A weight preset (Balanced, Growth first, Districts first), or set each weight (each click 0.5); like the One city tab's settings, they hide under one line after each solve. A site's tile yields are weighed by the fixed numbers of the One city tab's **Tiles** column, times this tab's weight for the same yield (Growth first's Food 2 doubles Food tiles). Housing scores a site's Housing from water (plus the Granary, and the Lighthouse and Seaport when the plan has a Harbor): each Housing up to the population the planned districts need counts 1, each one after it half the one before.
3. Tick the **districts each site is scored with**. **Per site** (default 3) is how many of them each site is scored with when you tick more.
4. **Solve**: up to three plans. Click one to preview its sites' 3 rings on the map and move the camera to its first site; click it again for the next site, and after the last, the first. Click a site row to move the camera to that site. While you **View map**, **Next site** is beside **Back to planner**. Hover a site row for its water, its distances to your nearest city or site tack and to the other sites, the Luxury and Strategic resources it gets, its features and the districts it picked.
5. **Place site tacks**: a City Center tack on each site, numbered after your cities. These tacks are what the Several cities tab plans.

Only revealed tiles are considered; a tile whose 3 rings are mostly unrevealed is not a candidate.

## Several cities

1. **Cities**: your cities and City Center tacks (sites not founded yet) as chips, three a row, five rows shown, more scroll. Tacks come first, then cities by number. Click a chip to switch it on or off; the ones on are highlighted.
   - By default the city selected on the map when the panel opens is the center, otherwise your capital: it is on, then, nearest first, the cities and tacks within 7 tiles of one already on, 4 at most. Select another city and open the panel again, and the center moves and your own choices go back to the default (not while a plan is being computed in the background).
   - Up to 8 by hand; when 8 are on the others are dimmed until you switch one off. **Clear all** and **Default** sit to the right of the title.
   - A city left out counts as a fixed neighbor (its districts and tacks count, but stay as they are); a tack left out gets no districts and is not counted as a new city, but stays on the map.
   - The more cities, the longer the wait; hover over the title for measured waits and how much more adjacency planning together gives.
2. **Districts for**: one list shared by every city, or a list for one city. **Apply a template** fills a list by yield (Science city, Production city…) from your civilization's adjacency rules; it keeps the number per city. The number per city (3 by default) works as on the One city tab. A district limited to one per empire (Government Plaza, Diplomatic Quarter) that is Must in the shared list goes to the first city of the list; the others are marked "empire limit reached" and take a Pool district instead. To put it in another city, make it Must in that city's own list only. With the shared list a city skips what it has built or already has a tack of (the tacks this mod placed for it, and tacks on its own tiles or on unowned tiles nearest to it); a skipped tack is listed as "this city already has a map tack for it".
3. Wonders, weights (with **Tiles**), switches and Effort as on the One city tab. A wonder that needs a district none of the cities has (built, tacked or Must in its list) gets one in the first city of the list that can take it; a line under the wonder tags says so, and after Solve which city got it. To choose the city, give it a list of its own with the district set to Must. The shared list is not changed; set the district to Off there and it is not added. **Reach** (default 0) moves districts with a regional effect, such as the Industrial Zone, to where they cover more of your cities; picking from the pool counts it too. A district's row says how many cities it newly covers (cities a built or tacked district of the same type covers already do not count).
4. **Solve**, preview a plan (the text under each district icon starts with its city's number), **Place tacks**; tacks are named with their city's number. **Undo tacks** works as on the One city tab.

## Rules worth knowing

- Map tacks already on the map are fixed: the planner never uses their tiles, and their bonuses count.
- To plan a city again, undo its tacks or tick **Replace**.
- On tiles a city owns, the game's own list of valid tiles is checked as well, so tiles the game refuses (such as a Canal that does not connect water) never enter a plan.
- Tiles next to a City Center tack that is not a city yet, and that nobody owns, are left to that planned city: it takes them when it is founded, so no other city plans a district there.
- The same game state and the same settings always give the same plan.

## Known limitations

- The Several cities tab has no switch to forbid removing features: there, districts may always go on Woods, Rainforest and Marsh.
- The Several cities and City sites tabs list their plans only when the whole computation has finished.
- City site scores are estimates: tile yields, resources and district potential are judged from what is revealed now; the districts are planned exactly in the Several cities step.
- Each kind of district is planned once; for several Neighborhoods, solve more than once.
- Picking from the pool compares only adjacency (plus land loss, reach and distance cost when they are on); the yields of a district's buildings are not counted.
- Reminder tacks are only for Woods and Rainforest next to the planned districts, not next to districts that already exist.
- Unrevealed tiles are left out: DMT cannot read their terrain.
- Multiplayer has not been tested; the tacks use the game's default visibility.
- Appeal starts from the game's current values (civilization, governor, policy and wonder modifiers included) plus what the plan's districts, wonders and removed features or improvements change; improvements built later outside the plan are not in the model. A Preserve's yields on nearby tiles assume those tiles stay unimproved; a Preserve that is only a tack counts its Housing only.

The overview page lists a few more, with measurements: [known limitations](https://smallspider0.github.io/civ6-smart-district-planner/en/#limits).

## Troubleshooting

- **The mod list shows `LOC_SDP_MOD_NAME`**: the mod is not enabled yet, or the game has not been restarted since.
- **No button or panel**: Detailed Map Tacks must be enabled too; restart the game after enabling mods.
- **The panel does not show up**: another popup, such as a Historic Moment, is open; the planner waits until it is closed.
- **"no valid tile in range"**: no tile within the city's 3 rings fits that district's rules. For example, a Harbor needs a Coast tile; unrevealed tiles and other civilizations' tiles are not considered.
- **Reporting a problem**: open an issue on [GitHub](https://github.com/SmallSpider0/civ6-smart-district-planner/issues) with the version, the ruleset, the other mods you use and how to reproduce it. On Windows, the lines of `%LOCALAPPDATA%\Firaxis Games\Sid Meier's Civilization VI\Logs\Lua.log` around the error help most: search it for `Runtime Error`, then for `SDP_` (the log may need `-log` in the game's launch options in Steam). The macOS version does not write `Lua.log`.
