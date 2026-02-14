# Pet Cager

A World of Warcraft addon that cages tradeable battle pets in batches for auction house selling.

## Features

- Scans your pet journal for duplicate, tradeable pets
- Filter by quality, level range, pet family, and source
- Configure how many copies of each species to keep
- Set a minimum owned threshold before pets become eligible
- Sortable columns: name, level, owned count, quality, family
- Select/deselect individual pets or use bulk select
- Batch caging with progress display
- Automatic re-scan and multi-pass caging until all eligible pets are processed
- Bag space validation before caging

## Usage

Type `/pc` or `/petcager` to open the Pet Cager window.

1. Adjust filters at the top of the window (quality, level range, families, sources, keep count, min owned)
2. Click **Scan Pets** to find eligible pets
3. Review the list and deselect any pets you want to keep
4. Click **Cage Selected** to start caging
5. Use **Stop** to cancel at any time

## Installation

Copy the `PetCager` folder into your `World of Warcraft/_retail_/Interface/AddOns/` directory.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
