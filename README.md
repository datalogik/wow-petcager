# Pet Cager

A Retail World of Warcraft addon for reviewing and caging tradeable battle-pet duplicates.

## Usage

Type `/pc` or `/petcager` to open the window.

1. Choose qualities, level range, families, sources, keep count and minimum owned count. Search matches custom or species names.
2. Click **Scan Pets** (or press Enter in Search).
3. Review the list, hover for stats/source information, and uncheck pets you want to retain.
4. Click **Cage N Selected**. Only that selection is processed.
5. **Stop**, Escape, closing the window, or entering combat stops further requests. A cage request already sent cannot be recalled.

## Selection and protection

- Favorites, active battle-team pets, and pets Blizzard marks non-tradeable are always kept.
- Custom-named pets are protected by default; uncheck **Keep custom-named pets** to include them.
- Protected copies count toward **Keep per species**. Additional copies are reserved by highest level, then highest quality, before sale filters apply.
- **Min owned** controls eligibility at the start of a batch; **Keep per species** is the minimum retained during caging. Setting Keep to zero permits caging the last unprotected copy.
- Changing filters requires another scan before caging.
- The collection is checked again before starting. Bag space and protection are checked before each request.
- Only general-purpose bag slots count as space for cages.
- A pet counts as caged after its journal entry disappears. Cage failure or a five-second confirmation timeout ends the batch.
- A completed batch never automatically selects or cages more pets. Scan again to review another batch.

## Interface improvements in 2.1

A wider, screen-clamped window separates filters, list, and actions. Pet names have more room; empty results explain how to broaden the search. Sort headers indicate direction, and the cage button displays its selected count. Numeric inputs display their clamped values. Sources use Blizzard's localized labels and include additional sources exposed by the client.

Normal scans use `C_PetJournal.GetOwnedPetIDs` without changing the journal search or filters. When source filtering is needed, the addon temporarily uses Blizzard's source classification and restores the journal's search, collected/favorites, type, and source filters.

## API review

Checked against Blizzard's live UI/API source mirror on October 12, 2026. These APIs are currently exposed; this does not imply they were all newly introduced in the latest patch.

Implemented from the [Pet Journal API](https://github.com/Gethe/wow-ui-source/blob/live/Interface/AddOns/Blizzard_APIDocumentationGenerated/PetJournalInfoDocumentation.lua): owned-ID enumeration, structured pet information, loadout protection, and cage-failure handling. The addon requires the current Retail versions of `GetOwnedPetIDs` and `GetPetInfoTableByPetID`; unsupported clients show an explanatory message.

Potential follow-ups:

- **Appearance-aware keep rules:** `GetNumDisplays`, `GetDisplayIDByIndex`, `PetUsesRandomDisplay`, and each pet's `displayID` could support an appearance preview and policies for fixed appearances. Random-display species need special handling; display IDs alone should not be treated as permanent unique variants.
- **Auction-price preview:** the [Auction House API](https://github.com/Gethe/wow-ui-source/blob/live/Interface/AddOns/Blizzard_APIDocumentationGenerated/AuctionHouseDocumentation.lua) exposes species-aware item keys and item search results. A future UI could query and compare listings while the AH is available, respecting its throttling and asynchronous results. This is not an always-available price feed or a promise of unattended posting.
- **Ability preview:** `GetPetAbilityListTable` and `GetPetAbilityInfo` can show abilities alongside the existing health, power, and speed tooltip.

## Validation

Run `luajit tests/petcager_test.lua` from the addon directory. The mocked-client regression suite covers keep ordering, protected pets, deselection, failed and timed-out requests, stop/restart timer isolation, specialized bags, source-filter restoration, and closing the window.

In-game verification remains necessary: `/reload`, open `/pc`, check layout at your UI scale, compare the scan to your journal, cage one low-value duplicate, and check Stop and source-filter restoration. The tests cannot validate Blizzard's live server timing, protected-action behavior, fonts, or rendering.

## Installation

Copy `PetCager` into your `World of Warcraft/_retail_/Interface/AddOns/` directory.

## License

[MIT](LICENSE).
