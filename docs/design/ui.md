# UI Design

The visual direction is a restrained future arena style:

- dark layered backgrounds,
- translucent panels,
- low-saturation blue/cyan/purple accents,
- compact HUD cards,
- readable combat-first typography.

Design tokens live in `scripts/ui/ui_tokens.gd`. Main menu and HUD are generated procedurally from scripts to avoid fragile scene nesting while keeping all scene entry points present.
