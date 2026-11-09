# Design prompt: RV32 Booth-MAC Core project page

**Role.** You are the design lead at a small studio that does product pages for chip design teams. Redesign the existing single-file page `rv32_booth_mac.html` so that it feels like a polished silicon project page. Keep every number, section and interaction it has now.

**Subject and audience.** The subject is a student hardware project: a radix-4 Booth multiply-accumulate unit inside a 5-stage RISC-V core, taken from Verilog through simulation, Yosys synthesis and ECP5 place-and-route. The readers are instructors, recruiters and other engineers. They skim the numbers first, then explore the floorplan. The page's one job is to make the work look as rigorous as it is.

**Direction: "die shot meets datasheet."** The floorplan is the hero object, treated the way a chip photographer treats a die: dark, precise, slightly luminous. Everything around it reads like a well-set datasheet: quiet, tabular, exact. Put the boldness in the floorplan and keep the rest restrained.

**Palette.**
- **Ground:** a wafer-dark blue-black, not neutral grey, with one slightly lifted panel tone and hairline rules.
- **Accent:** copper, as in metal routing, for links, active states and the routing glow. Use pale bond-pad gold sparingly for the critical path and key figures.
- **Block colours:** retune them into one family, so they read as layers of the same material rather than five unrelated hues:
  - amber for the Booth multiplier
  - cyan for MAC stage 2
  - sage for the pipeline
  - lilac for the register file
  - coral for DSP
- **Semantic colours:** pass and info have their own colours, separate from the accent.

**Type.**
- An optical-size serif for headlines, with an italic for one or two accent words.
- A condensed sans in tracked uppercase for labels and layer names.
- A monospace with tabular figures for every number, unit and coordinate.
- A clear type scale, with running text near 65 characters per line.

**Layout.**
- A 12-column grid, max width about 1200 px.
- The **hero** opens with the title and lead set over a wide crop of the die render.
- **Below the hero,** a datasheet-style spec table with hairline dividers and units set in a lighter weight.
- **Architecture** gets a real SVG pipeline diagram: the five stages IF→WB with pipeline-register bars, and the MAC unit drawn spanning EX and MEM. The stage order is real information here, so numbering it is fine. Do not number anything else.

**Floorplan viewer**, styled like a microscope or EDA layout viewer:
- corner registration ticks;
- a scale bar in tiles;
- a live X/Y coordinate readout;
- a mini-map inset of the whole die with a viewport rectangle;
- a layer panel in the style of KLayout, with a swatch, name, cell count and a visibility toggle per block.

Highlighting a block hatches or brightens it while the rest drops to a dim, desaturated tone. Tiles get a subtle bevel or inner highlight, like metal fill. Keep the open-zoomed-on-the-design behaviour, the hover tooltips, pinch, and Ctrl/⌘ + scroll zoom.

**Data.**
- Performance becomes a proper bar chart: one scale, a labelled axis, cycles-per-tap annotations, and the MAC bars in copper.
- Verification becomes a sign-off table with status pills.
- The build notes are a two-column editorial block, each with one pull figure (for example "28.9 ns", "−7,109 gates", "79 %").

**Motion.** Use one orchestrated moment. On load, the tiles fab in row by row over about 600 ms and the critical path then draws itself. Everything else is still. Respect `prefers-reduced-motion` by showing the final state immediately.

**Avoid.**
- Cream with terracotta.
- Acid-green on black.
- Purple gradients.
- Inter or Space Grotesk.
- Emoji.
- Everything centred.
- A rounded shadow card around every block.
- Decorative 01/02/03 numbering.

**Constraints.**
- One HTML file.
- Google Fonts only.
- No external images; the die render is drawn on canvas from the embedded data.
- Works at 400 px phone width with no horizontal page scroll.
- Visible keyboard focus.
- A single committed dark look, with `color-scheme: dark`.

**Done when:**
- Every current number and interaction still works.
- The floorplan reads as the centrepiece at first glance.
- Nothing overlaps or clips at phone or desktop width.
