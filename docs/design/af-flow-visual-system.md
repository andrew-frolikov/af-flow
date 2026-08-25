# AF Flow visual system

Decision document, 2026-08-25. Written by the visual designer role; implemented by a separate agent.
Source of truth for the brand: `/Users/andriifrolikov/Claude/AndrewFrolikov OS/Context/brand-visual.md` (the canon). This document applies the canon to a native macOS app and decides everything the canon does not cover. Where it adds to the canon, section 9 contains the paste-ready text.

Every contrast ratio in this document was computed with the WCAG 2.x relative-luminance formula, not eyeballed. The implementer must still re-measure the shipped pixels (screenshot sampling), because rendering, opacity compositing, and font smoothing can shift values. Computed here means "designed to pass"; measured on the built app means "passes".

Scope decisions already taken by Andrew, which this document works within:

- The brand replaces the Default skin inside the existing `AppTheme` system. Windows 95 and Space survive as deliberate novelties.
- The app icon moves to the Fraunces mark with the pine dot.
- The menu bar popover, onboarding, and the separate meeting transcript viewer are in scope.
- The canon gets the app-level additions (section 9).

---

## 1. The decision in one paragraph

AF Flow becomes a single sheet of warm paper. One ground colour, `#F5F1E8`, fills the entire window: sidebar, detail pane, headers, footers. Nothing on that sheet is a coloured region; structure comes from type, whitespace, hairlines in exactly four permitted places, and small bounded objects (a pine capsule for the selected section, cream wells where text is entered or read). The only saturated colour is the brand's deep pine `#1E5C46`, which marks whatever is selected, active, or primary, plus three functional status colours that exist to answer "what is the app doing right now". Type is the brand pair: Fraunces for the app's own words at display sizes, Inter for everything else, including every word Andrew dictated, so Russian never falls into a fallback face. The recording overlay is the same identity inverted: ink `#17201D` with paper text, floating over any app. The single idea: this is a paper document that happens to be an app, the same object as andrewfrolikov.com, his CV, and his reports. It is not a Mac preferences window wearing a theme.

What was rejected: keeping Home's existing warm palette (it is blue-cast and teal-signalled, brand-adjacent and wrong on every token, which is worse than obviously different); a light-plus-dark adaptive app (two hedged looks instead of one confident one, and it doubles the measured-contrast surface); and any per-section background colours, which are the exact thing Andrew asked to remove.

---

## 2. Tokens

### 2.1 Light surface (the app)

| Token | Hex | Role | Canon source |
|---|---|---|---|
| `ground` | `#F5F1E8` | The one window background: sidebar, detail pane, footers, everything | `--paper` |
| `well` | `#FFFDF7` | Bounded surfaces where text is entered or read: fields, editors, the debug log well, keycaps | `--panel` |
| `textPrimary` | `#17201D` | Primary text and icons | `--ink` |
| `textSecondary` | `#626C68` | Secondary text: captions, eyebrows, help text. Never on `selectedFill` or any tinted fill (measured fail, see section 7). Always set explicitly, never via the system `.secondary`/`.tertiary` styles: SwiftUI derives those from the primary colour at 50% and 25% opacity, which measure 3.18:1 and 1.67:1 on `ground` (verified by pixel readback), both failures. **There is no third text level.** `.tertiary` sites collapse into `textSecondary`; hierarchy below secondary is carried by the 11.5pt caption size, because any hex passing 4.5:1 sits within a hair of `#626C68` and would fake a level that cannot legibly exist | `--muted` |
| `hairline` | `#D8D3C8` | The only border colour on light | `--line` |
| `accent` | `#1E5C46` | Selection, primary buttons, links, focus tint, the ready state | `--signal` |
| `accentHover` | `#174A38` | Primary button hover | Addition |
| `accentPressed` | `#123B2D` | Primary button pressed | Addition |
| `onAccent` | `#F5F1E8` | Text and icons on any `accent` fill | `--signal-ink` |
| `hoverFill` | `textPrimary` at 6% over `ground` (composites to `#E8E4DC`) | Hover on rows and ghost controls | Addition |
| `pressedFill` | `textPrimary` at 10% over `ground` (composites to `#DFDCD4`) | Pressed on rows and ghost controls | Addition |
| `selectedFill` | `accent` at 12% over `ground` (composites to `#DBDFD5`) | Selected table and list rows (not the sidebar, which uses a full `accent` capsule) | Addition |

`--soft-panel` (`#E8EDDA`) and `--outer` (`#E7E2D8`) are deliberately not used in the app. The mint card variant is a website marketing surface, and a second panel colour is exactly the "separate sections" problem. `--outer` fails contrast with `textSecondary` (4.21:1, measured) and has no role on a monolithic ground. `--signal-soft` mist appears in the app only on dark surfaces (overlay, dark insurance column); on paper it is a dark-surface colour and was rejected for light-mode selection.

### 2.2 Status colours (functional, canon addition)

Three states, each in a light grade (for the window, on `ground`) and a dark grade (for the overlay, on `surfaceDark`). Both grades of each state are computed to pass 4.5:1 as text and 3:1 as dots on their surface.

| State | Meaning | Light grade | Dark grade |
|---|---|---|---|
| `statusReady` | Ready, learned correction, copied | `#1E5C46` (= `accent`) | `#A7E8C6` (= `--signal-soft`) |
| `statusBusy` | Loading, transcribing, cleaning up | `#7A5414` | `#E0A94E` |
| `statusLive` | Recording (mic live), and errors | `#9E3B24` | `#E8836B` |

Rationale. Recording must read as red at a glance; that convention is stronger than palette purity, and pine cannot mean both "all is well" and "the microphone is hot". `#9E3B24` is a deep clay red chosen to sit naturally on warm paper; it is not the retired terracotta `#8F5F44` (a brown) and not Home's old `#B0472F` (fails 6:1; this passes at 6.00:1). Recording and error share the red family on purpose: both mean "attend to this now", and they are distinguished by motion (recording pulses, error is static with a message). The ochre `#7A5414` is a muted working colour that cannot be confused with either. Rejected: Home's teal (off-canon), a blue busy state (no blue anywhere in this brand), and reusing pine for recording.

Status pill fills: the state colour at 12% over `ground`. Computed composites and text ratios: ready `#DBDFD5` (text on it 5.81:1), busy `#E6DECF` (5.06:1), live `#EBDBD0` (5.02:1).

### 2.3 Dark constants (the overlay and the context bubble)

| Token | Value | Role | Canon source |
|---|---|---|---|
| `surfaceDark` | `#17201D` | Overlay fill (at 96% opacity), context bubble base | `--dark` |
| `textOnDark` | `#F5F1E8` | Primary text on dark | `--dark-ink` |
| `secondaryOnDark` | `#B9C3BE` | Secondary text on dark | `--dark-muted` |
| `edgeOnDark` | `textOnDark` at 30% | The overlay hairline | Canon dark-border rule, off-white variant |

The canon offers two dark edges: mint at 45% or off-white at 30% "where the mint would read as an accent". On a status pill, a mint ring would read as a permanent green status while the dot is trying to say red; that is precisely the escape clause's case, so the overlay uses the off-white edge. Rejected: the mint edge on the overlay.

### 2.4 Theme architecture: the brand as an `AppTheme` skin

`AFFlowPalette` in `HomeWindow.swift` dies. Home and the recording overlay stop bypassing the theme and read `AppTheme` like every other surface. Consequence, accepted deliberately: when Andrew picks Windows 95, Home and the overlay wear grey chrome and navy like everything else. A skin that skins only five of seven surfaces is not a skin, and the whole point of this document is one system with no private palettes. The two novelty skins keep working untouched because every brand value below is a token value, not a hardcode.

Existing `AppTheme` slots, brand (`.current`) values:

| Slot | Brand value |
|---|---|
| `accent` | `#1E5C46` |
| `accentText` | `#F5F1E8` (note: the novelty skins use dark text on their accents; the slot means "text on an accent fill" and each skin satisfies it its own way) |
| `windowBackground` | `#F5F1E8` |
| `textBackground` | `#FFFDF7` |
| `controlBackground` | `#F5F1E8` (same as the window: the monolith rule forbids a third region colour; existing `controlBackground` call sites become invisible seams, which is correct) |
| `separator` | `#D8D3C8` |
| `selectedFill` | `accent` at 12% (`Color(#1E5C46).opacity(0.12)`, composites to `#DBDFD5` over ground) |
| `contextBubbleBackground` | linear gradient `#17201D` to `#1C2822`, text `textOnDark` |
| `usesDarkText` | `false` |

New slots this system needs. Every new slot ships with values for all three skins so neither novelty breaks:

| New slot | Brand | Windows 95 | Space |
|---|---|---|---|
| `textPrimary` | `#17201D` | `.black` | `#E2E7FF` |
| `textSecondary` | `#626C68` | `.black.opacity(0.6)` | `#9FA8CE` |
| `hoverFill` | `textPrimary.opacity(0.06)` | `accent.opacity(0.12)` | `accent.opacity(0.15)` |
| `pressedFill` | `textPrimary.opacity(0.10)` | `accent.opacity(0.20)` | `accent.opacity(0.25)` |
| `accentHover` | `#174A38` | same as `accent` | same as `accent` |
| `accentPressed` | `#123B2D` | same as `accent` | same as `accent` |
| `statusReady` | `#1E5C46` | `#008000` | `#63E6A8` |
| `statusBusy` | `#7A5414` | `#808000` | `#FFC85E` |
| `statusLive` | `#9E3B24` | `#C00000` | `#FF7A66` |
| `overlayFill` | `#17201D` at 0.96 | its current grey at 0.96 | its current navy at 0.92 |
| `overlayText` | `#F5F1E8` | `.black` | `.white` |
| `overlayEdge` | `overlayText.opacity(0.30)` | `accent.opacity(0.7)` | `accent.opacity(0.7)` |
| `overlayStatusReady` / `Busy` / `Live` | `#A7E8C6` / `#E0A94E` / `#E8836B` | its `status*` values | its `status*` values |
| `displayFont(size:)` | Fraunces (bundled, see 4) | `.system` | `.system` |
| `textFont(size:weight:)` | Inter (bundled, see 4) | `.system` | `.system` |

The novelty-skin values for the new slots are functional defaults in each skin's existing vocabulary, not designed artifacts; the implementer may adjust them by eye inside that vocabulary. Every brand value is binding.

---

## 3. The monolith rule

Andrew's words: "one background, not like a separate colors, separate section in one window." As a rule an implementer can apply and a reviewer can check:

1. **One ground.** Every point of the window that is not a bounded component is `ground`. The sidebar is not a differently coloured region. There is no band, no header strip fill, no footer fill, no toolbar fill, no `Color(nsColor:)` background anywhere. The sidebar is distinguished from the detail pane by layout alone: a fixed narrow column, its own type scale, and one vertical hairline.
2. **The only second surface is `well`,** and only on bounded components whose function is entering or reading text: text fields, text editors, the debug log well, search fields, keycaps. A well always has a 12pt corner radius (8pt for keycaps), a 1px `hairline` border, and at least 16pt of `ground` between it and any window edge. A well never spans a region.
3. **States are tints, never hues.** Hover, pressed, and selected are fixed opacities of `textPrimary` or `accent` over `ground` (6%, 10%, 12%). No greys, no new colours, no shadows, no blur materials, and no vibrancy inside the window.
4. **Hairlines are allowed in exactly four places:** (a) the vertical sidebar/detail boundary, (b) the top edge of a footer strip, (c) table and list row separators at 50% opacity, (d) the borders of wells and ghost buttons. Anything else with a border is wrong.
5. **Cards are dead.** Grouping inside a section is an eyebrow label plus whitespace: 28pt between groups, 10pt from a group label to its first control. No boxes around groups of settings, no `GroupBox`, no inset grouped lists.

Reviewer check: screenshot all seven sections at the default window size. Sampling background pixels anywhere outside wells and bounded components must return exactly `#F5F1E8`. Counting distinct background colours across the whole window must return two: `ground` and `well`. Any filled rectangle wider than 600pt that is not the window itself is a violation.

The window itself: force light appearance (`NSAppearance(named: .aqua)` on the window) so system semantic colours can never leak a dark value into the sheet; `titlebarAppearsTransparent = true` with `ground` behind it, so the title bar is part of the same sheet; standard traffic lights; no toolbar.

---

## 4. Type

### 4.1 Faces and bundling

Both families were registered and rendered with CoreText on this Mac before these decisions were made; the constraints below are measured, not assumed.

- **Fraunces**, the display face. Bundle **only** `Fraunces-opsz9-wght500.ttf` (the instanced cut, the same face the mark is built from) from `/Users/andriifrolikov/Claude/Projects/personal-website/brand/`. **Do not bundle `Fraunces-variable.ttf` in the app.** Measured trap: the variable file's default instance is Optical Size 9 but **Weight 900 with Wonky 1**, so a naive `Font.custom("Fraunces", size:)` against it renders black and wonky, not the brand's 500; and while both files are registered, resolving by the shared family name "Fraunces" is ambiguous and can return either file. Shipping one static cut removes both failure modes. The shipped instance, by axis value: opsz 9, wght 500, exactly as the mark was instanced; it reproduces the canon's mark geometry (verified numerically: ink span 13.00 to 46.85 in the 64-unit box against the canon's 13.0 to 46.8). Load it by file URL or by its PostScript name read from the file, never by family name. Acceptance number: the advance of "AF" at 72pt in the shipped instance is 89.62pt (measured); a result near 97.4 means the weight-900 variable instance leaked in. Divergence from the web canon, recorded: the website sets the brand name at weight 400, the app sets all Fraunces at 500 because one static instance cannot drift and the difference at 17pt is negligible. Fallback stack: Georgia, then serif.
- **Inter**, the text face. Bundle `Inter-variable.ttf` from the same folder; the app needs weights 400, 500, 600. Inter's variable defaults are safe (weight 400, optical size 14, measured), so the naive load renders Regular correctly. Acceptance test for the implementer: the three weights must be visibly distinct in the running app. If the variable font exposes only its default instance under SwiftUI, instance static cuts (Regular, Medium, SemiBold) with fonttools and bundle those three instead, and then the load-by-URL-or-PostScript-name rule applies to Inter too. Fallback: system.
- **SF Mono** (system, fallback Menlo) for the debug log and timing readouts. The brand has no mono face; this is a canon addition, chosen because a bundled third family buys nothing over the system mono for a diagnostic surface.

### 4.2 The Cyrillic rule, load-bearing

Measured on this Mac: rendering a Russian phrase in Fraunces loses 13 of 14 glyphs; Inter loses zero. So Fraunces has effectively no Cyrillic and Inter's coverage is complete. Andrew dictates in Russian roughly 60% of the time (1420 ru vs 935 en over 22 days), and that text comes back to him in History, the overlay, and the transcript viewer. The rule that removes the problem instead of styling it:

**Fraunces is reserved for strings the app authors. It never holds user or model content.** Section titles, the Home instruction, the brand name: Fraunces. Anything that can contain a dictated word, a meeting title, a transcript, a correction, a filename: Inter, which has complete Cyrillic. Under this rule the Georgia fallback can never actually appear in the app; Georgia stays in the stack purely as a safety net, and if it ever becomes visible that is a bug in role allocation, not a font problem.

Consequence for the transcript viewer: the existing Georgia 15pt notes face and Georgia 16pt article face become Inter at the same sizes (see 5.10). Rejected: keeping Georgia for long-form reading. Georgia is the display face's fallback, not the brand's text face, and using it as a reading face reinstates the retired Georgia look that the app icon is being moved off.

### 4.3 The ladder (points)

The canon's web scale (hero 52 to 94px) does not fit a 1000x720 utility window. App ladder, a canon addition. Tracking is given as SwiftUI kerning in points at the stated size.

| Role | Face | Size | Weight | Tracking | Line height | Used for |
|---|---|---|---|---|---|---|
| Display | Fraunces | 24pt | 500 | -0.48pt | 1.15 | The Home instruction ("Hold ... and speak"). App-authored only |
| Section title | Fraunces | 21pt | 500 | -0.32pt | 1.2 | The heading at the top of each detail pane, onboarding step titles |
| Brand name | Fraunces | 17pt | 500 | 0 | 1.2 | "AF Flow" beside the mark in the sidebar header |
| Eyebrow | Inter | 11pt | 600 | +0.9pt, uppercase | 1.3 | Group labels in forms, footer cell labels. Colour `textSecondary` |
| Body | Inter | 13pt | 400 | 0 | 1.45 | Default text everywhere |
| Body strong | Inter | 13pt | 500 | 0 | 1.45 | Control labels, sidebar rows, status pill label |
| Emphasis | Inter | 13pt | 600 | 0 | 1.45 | Buttons, keycap, overlay primary line, selected sidebar row |
| Caption | Inter | 11.5pt | 400 | 0 | 1.4 | Help text, timestamps, version line. Colour `textSecondary` |
| Reading | Inter | 15pt | 400 | 0 | 1.6 | Transcript viewer notes, history entry bodies |
| Reading large | Inter | 16pt | 400 | 0 | 1.6 | Transcript viewer article body |
| Mono | SF Mono | 12pt | regular | 0 | 1.5 | Debug log, timings |

**Fraunces floor: 17pt.** Below 17pt the serifs muddy and Fraunces loses its case for existing; everything smaller is Inter. Fraunces earns its place at app sizes by appearing exactly where the brand voice speaks (the instruction, the section names, the name beside the mark) and nowhere else, which keeps it a signature rather than a texture.

### 4.4 The cost of Inter, decided knowingly

The inventory (scratchpad `migration-inventory.md`) counts 660 type call sites across 20 files, 309 of them in the transcript viewer, and unlike colour there is no root-level escape: an explicit `.font(.system...)` beats any default, so "the app is set in Inter" means touching all of them, where "SF carries the UI" would cost roughly 30.

**The decision is Inter everywhere, phased.** Rejected: San Francisco as the UI face. The canon names Inter as the text face; SF is the face of every other macOS app, which is precisely what Andrew asked this app to stop looking like; and the cost is one-time and mechanical while a divergence from the canon is forever, which is the exact drift pattern the canon exists to end. The price is paid on these terms:

- The migration is a mechanical rewrite to two helpers, `theme.textFont(size:weight:)` and `theme.displayFont(size:)`, never 660 bespoke judgements. The 152 `.font(.caption)` sites map to the Caption role, `.body` to Body, and explicit `.system(size:)` sites keep their size through the helper unless this document's ladder names a different one for that role.
- **The halfway point is defined so it never shows.** Mixing is permitted at the surface level only: any given window or section is entirely Inter or entirely SF at all times, never mixed within one visible surface. Inter and SF are close enough cousins that a difference across a section boundary is invisible in passing; a difference within one paragraph is not. Sweep order is the order his eyes visit: shell chrome and sidebar, Home, the overlay, History, then the Settings sections, and the transcript viewer's 309 sites as their own dedicated pass, last.

---

## 5. Component specs

### 5.1 Window shell and sidebar

- Window: 1000x720 default, 900x680 minimum, unchanged. Title bar transparent over `ground` (see section 3).
- Sidebar: fixed width 232pt (min = max; the split is not draggable). Vertical hairline on its trailing edge, full height. Background: `ground`, nothing else.
- Sidebar header (new): the AF mark at 28x28pt (the canonical plate-glyph-dot construction, rendered as an asset, not live text) plus "AF Flow" in Brand name style, `textPrimary`. 20pt top padding, 16pt leading. This is the brand lockup exactly as the website header carries it, scaled down.
- Rows: single line, 34pt height, capsule shape (radius 999), 12pt horizontal content inset, 16pt from sidebar edges. SF Symbol icon at 18pt frame, then title in Body strong. **The two-line subtitles die.** Seven rows do not need explanatory subtitles, and their removal is what lets rows become quiet capsules. The subtitle text moves into each section as its first Caption line where it still earns its place.
- Selected row: `accent` capsule, text and icon `onAccent`, Emphasis weight. No stroke (the current selected-row border dies). This is the brand's pill button vocabulary applied to navigation; it is the single strongest colour statement in the window and it always points at where you are.
- Unselected row: transparent, text `textPrimary`, icon `textSecondary`.
- Bottom of sidebar: version line, Caption, `textSecondary`.
- Rejected: 12pt rounded-rect rows (kept the preferences-pane look), tinted selected rows in the sidebar (too weak to anchor the window; the tint vocabulary belongs to content tables).

### 5.2 Detail pane

`ground`. 32pt padding on top and sides. Form content max width 560pt, left aligned. Section title (Fraunces 21) at top, 8pt below it an optional Caption description, then 28pt to the first group. Groups: Eyebrow label, 10pt, controls at 8pt vertical rhythm within a group, 28pt between groups. No boxes.

### 5.3 Buttons

- Primary: capsule, `accent` fill, `onAccent` text, Emphasis type, height 28pt, min width 64pt, 14pt horizontal padding. Hover `accentHover`, pressed `accentPressed`, disabled at 40% opacity, non-interactive.
- Ghost (secondary): capsule, transparent fill, 1px `hairline` border, `textPrimary` text. Hover `hoverFill`, pressed `pressedFill`.
- Destructive: ghost geometry with `statusLive` text. The confirming action inside a native alert may be a filled variant: `statusLive` fill with `onAccent` text (6.00:1, computed). Destructive actions always confirm through a native alert; the in-window button never destroys directly.
- Link style: `accent` text, underline on hover.
- Pointer-target divergence from the canon, recorded: the canon's 44px minimum is a touch rule. AF Flow is pointer-first; minimum control height is 28pt with a hit area padded to at least 24x24pt. This goes to the canon as an app rule (section 9).

### 5.4 Form fields

Text fields and editors: `well` fill, 12pt radius, 1px `hairline` border, `textPrimary` text, `textSecondary` placeholder, 8pt vertical and 10pt horizontal text inset. Focused: border becomes 2px `accent`. Native focus halo: set the app accent colour to pine so any system-drawn ring is pine, not blue.

### 5.5 Native controls, and where the restyling line is

Toggles, checkboxes, radio groups, pop-up buttons, steppers, sliders, progress bars, and date pickers stay **native in geometry, tinted pine** (`.tint(accent)` at the window root). Restyling native macOS controls in SwiftUI is expensive, fragile across OS releases, and buys nothing once they sit on one calm ground with a single accent. The line: anything with system-owned chrome (menus, alerts, pickers' dropdown menus, the native focus ring) stays system; anything AF Flow draws itself (buttons, fields, rows, pills, the overlay) follows this document. Rejected: fully custom toggles and sliders.

### 5.6 Tables and lists (History, model lists)

`ground` background, no alternating row colours. Row separators: `hairline` at 50% opacity. Row height minimum 28pt. Hover `hoverFill`; selected `selectedFill` with **all text in the row `textPrimary`** (secondary text on `selectedFill` measures 4.02:1 and fails; hierarchy inside a selected row comes from size and weight, which the ladder already provides). Column headers: Eyebrow style.

### 5.7 Status pill (Home) and status indication

Capsule, state colour at 12% over `ground` as fill, 7pt dot and Body strong label both in the state's light grade: ready `#1E5C46` on `#DBDFD5`, busy `#7A5414` on `#E6DECF`, live and error `#9E3B24` on `#EBDBD0`. The dot pulses only for busy and live (see 6). Error keeps the pill static and puts the message below in `statusLive` Body. The Home footer strip stays: three cells, Eyebrow labels, Inter 500 12pt values in `textPrimary`, the privacy value in `accent`; the strip sits on `ground` with a top hairline. The old `band` fill dies.

### 5.8 Recording overlay

The most-seen surface in the product. Capsule; fill `surfaceDark` at 96%; 1px `edgeOnDark` stroke; system shadow; sizes unchanged (300x60 compact, 420x84 wide). Primary line: Emphasis 13pt, `textOnDark`. Secondary line: Inter 500 12pt, `secondaryOnDark` (9.21:1, computed; the current 80%-opacity trick dies). Dot: 10pt, dark-grade status colour: recording `#E8836B` pulsing, busy `#E0A94E` pulsing, result states `#A7E8C6` static, failure states `#E8836B` static. The ProgressView keeps `.colorScheme(.dark)`. Everything reads through the theme slots (`overlayFill`, `overlayText`, `overlayEdge`, `overlayStatus*`) so the novelty skins keep their own overlays.

### 5.9 Menu bar

The popover menu (`MenuBarView`) **stays entirely native.** Menus are system-owned chrome; a tinted menu reads as broken, not branded. The brand's presence in the menu bar is the status item icon: a template image of the AF monogram built from `af-path-compact.txt`, 18x18pt canvas, glyph fitted by the renderer with computed and reported bounds, dot included in the silhouette, monochrome, `isTemplate = true` so macOS handles light menu bars, dark menu bars, and the pressed state. No colour overrides inside the menu; the existing `.red` error text may stay, as system menus own their own semantics.

### 5.10 Meeting transcript viewer (separate window, stays separate)

The system, not a call-site audit: the viewer already consumes `AppTheme` slots (`windowBackground`, `textBackground`, `controlBackground`, `separator`, `accent`, `selectedFill`), so once the `.current` slot values become the brand values in 2.4, the viewer lands on the same paper ground with pine accents with no per-site work. The remaining sweep, specified here: the four Georgia call sites (notes 15pt, article 16pt, and the two `NSFont` twins) become Inter Reading and Reading large per the ladder, which is where the Cyrillic rule pays off, since this window is where long-form Russian is read. Titles that hold meeting or user content: Inter 600, never Fraunces. Toolbar and list backgrounds inherit `ground` through the slots; row selection follows 5.6; the monolith rule applies to this window exactly as to the main one.

### 5.11 Onboarding

Same tokens, same ladder: `ground` window, step titles in Section title style (app-authored, so Fraunces is safe), body in Body, the green success tints (`Color.green` at 8% fill and 20% stroke) become `accent` at 8% fill with a `hairline` border, the three `controlBackground` fills become `well` or `hoverFill` per their function (text-bearing surface or passive chip), and the continue button is the primary button. First run is the one moment the brand introduces itself; it must be the same object as the app it opens into.

### 5.12 Alerts

Native `NSAlert` / SwiftUI alerts, unstyled. See the restyling line in 5.5.

---

## 6. Interaction states

| Component | Default | Hover | Pressed | Selected | Disabled | Keyboard focus |
|---|---|---|---|---|---|---|
| Sidebar row | transparent, `textPrimary` | `hoverFill` capsule | `pressedFill` | `accent` capsule, `onAccent` | n/a | focus ring (below) |
| Primary button | `accent` / `onAccent` | `accentHover` | `accentPressed` | n/a | 40% opacity | focus ring |
| Ghost button | `hairline` border | `hoverFill` | `pressedFill` | n/a | 40% opacity | focus ring |
| Destructive ghost | `statusLive` text | `hoverFill` | `pressedFill` | n/a | 40% opacity | focus ring |
| Text field | `well` + `hairline` | no change | n/a | n/a | 40% opacity | 2px `accent` border |
| Table row | `ground` | `hoverFill` | `pressedFill` | `selectedFill`, all text `textPrimary` | n/a | system, pine-tinted |
| Link | `accent` | underline | no change | n/a | 40% opacity | focus ring |
| Native controls | system, `.tint(accent)` | system | system | system | system | system, pine-tinted |

**Keyboard focus ring** for custom controls: 2pt `textPrimary` at 2pt offset on light (14.78:1 against `ground`, computed; well above the 3:1 non-text minimum). This adapts the canon's web ring (3px ink at 4px offset), which is too heavy at app control sizes; recorded as a canon addition. Never the fill colour as its own ring. On the dark overlay nothing is focusable, so no dark ring is needed in the app today; if one ever is, it is `--signal-soft` per the canon.

**Motion**: state transitions (hover, pressed, selection moves) 180ms ease, per the canon's micro-interaction rule. The status dot pulse: 600ms ease-in-out autoreversing, in-progress states only, exactly as the overlay does today. **Reduced motion**: every transition collapses to instant and the pulse stops at full opacity; the dot's colour still carries the state, so nothing is lost. This is the canon's non-negotiable rule applied to an app.

---

## 7. Contrast pairs to prove

Computed with WCAG relative luminance. The implementer measures each from screenshots of the built app and must match within rounding. Minimums: 4.5:1 text, 3:1 large text and non-text indicators.

| # | Foreground | Background | Computed | Minimum | Where |
|---|---|---|---|---|---|
| 1 | `#17201D` | `#F5F1E8` | 14.78 | 4.5 | body text on ground |
| 2 | `#17201D` | `#FFFDF7` | 16.37 | 4.5 | text in wells |
| 3 | `#626C68` | `#F5F1E8` | 4.82 | 4.5 | secondary on ground |
| 4 | `#626C68` | `#FFFDF7` | 5.34 | 4.5 | placeholders in wells |
| 5 | `#1E5C46` | `#F5F1E8` | 6.97 | 4.5 | links, ready text, focus tint |
| 6 | `#F5F1E8` | `#1E5C46` | 6.97 | 4.5 | primary button, selected sidebar row |
| 7 | `#F5F1E8` | `#174A38` | 8.99 | 4.5 | primary button hover |
| 8 | `#F5F1E8` | `#123B2D` | 11.03 | 4.5 | primary button pressed |
| 9 | `#9E3B24` | `#F5F1E8` | 6.00 | 4.5 | error text, destructive, live dot |
| 10 | `#9E3B24` | `#FFFDF7` | 6.65 | 4.5 | error text in wells |
| 11 | `#7A5414` | `#F5F1E8` | 6.00 | 4.5 | busy text and dot |
| 12 | `#F5F1E8` | `#9E3B24` | 6.00 | 4.5 | destructive filled confirm |
| 13 | `#1E5C46` | `#DBDFD5` | 5.81 | 4.5 | ready pill text on its fill |
| 14 | `#7A5414` | `#E6DECF` | 5.06 | 4.5 | busy pill text on its fill |
| 15 | `#9E3B24` | `#EBDBD0` | 5.02 | 4.5 | live pill text on its fill |
| 16 | `#17201D` | `#E8E4DC` | 13.14 | 4.5 | text on hover fill |
| 17 | `#17201D` | `#DFDCD4` | 12.16 | 4.5 | text on pressed fill |
| 18 | `#17201D` | `#DBDFD5` | 12.32 | 4.5 | text on selected rows |
| 19 | `#F5F1E8` | `#17201D` | 14.78 | 4.5 | overlay primary text |
| 20 | `#B9C3BE` | `#17201D` | 9.21 | 4.5 | overlay secondary text |
| 21 | `#A7E8C6` | `#17201D` | 11.90 | 3 | overlay ready dot |
| 22 | `#E0A94E` | `#17201D` | 7.90 | 3 | overlay busy dot |
| 23 | `#E8836B` | `#17201D` | 6.26 | 3 | overlay live dot |
| 24 | `#17201D` ring | `#F5F1E8` | 14.78 | 3 | keyboard focus ring |

Known failing pairs, banned by this document: `#626C68` on `#DBDFD5` (4.02, why selected rows use `textPrimary` only); `#626C68` on `#E7E2D8` (4.21, why `--outer` is unused). Decorative pairs with no requirement, listed so nobody "fixes" them: `hairline` on `ground` (1.32), the overlay edge (2.55 composite), the pine dot on the icon plate (2.30, canonical mark geometry).

Measure on every surface the colour actually appears on, per the canon. If any measured value lands below minimum, the token changes here first; no local colour nudging.

**What this system fixes, measured.** The app as shipped today carries three text tokens below 4.5:1 on its own paper: its muted `#7C8797` at 3.44:1 (used for body-sized secondary text), its teal signal `#2E8B7A` at 3.89:1, and its gold `#B9822B` at 3.15:1. This system replaces them with `#626C68` at 4.82:1, pine at 6.97:1, and `#7A5414` at 6.00:1. The redesign is an accessibility repair, not only an aesthetic one, and the canon's method (the same arithmetic independently reproduced the canon's two published ratios to two decimals) is what caught it.

---

## 8. The app icon

Approved: AF Flow moves to the canonical Fraunces mark with the pine dot, closing the divergence recorded in the canon.

What the macOS icon needs that the touch icon does not, decided here:

- **OVERTURNED BY MEASUREMENT, 2026-08-25. The master is PRE-ROUNDED, not full bleed.** This section originally specified a full-bleed square on the stated ground that "this Mac runs the macOS generation (Darwin 25) that masks app icons into its own squircle". That is false. On macOS 26.5.2 (build 25F84) the largest representation of Notes, Mail and Calculator each returns corner alpha 0, 0, 0, 0: every one ships pre-rounded artwork, so the system expects the app to supply its own plate and does not mask. A full-bleed square would have sat in the Dock as a black tile beside every other app. Corroborating evidence was already on disk, since AF Flow's own previous icon is pre-rounded and has never looked wrong. The classic variant recorded below is therefore the shipped one, and the implementer selected it rather than redesigning. Rule 4 stands unchanged for iOS, where the mask is real.
- **The shipped master**: the plate at 824 centred on a transparent 1024 canvas, corner radius 180 (`rx=14` in the 64-unit box, scaled), plate colour `#16161A`, no hairline (canon rule 3: only the website header placement carries one), construction scaled by 12.875.
- **Construction**, the canon's 64-unit box scaled by 16 onto the 1024 canvas: glyph "AF" from `af-path.txt` (outline paths, never live text, canon rule 1), fill `#FAF8F5`, spanning x 208.0 to 748.8, optical centre at 512.0; dot at cx 832.0, cy 619.2, r 54.4, fill `#1E5C46`; glyph-to-dot clearance 28.8 units at this scale. The canon's construction numbers are verified by fresh measurement on this Mac (static cut loaded by URL at 26.96pt in the 64-unit box: ink span 13.00 to 46.85 against the stated 13.0 to 46.8, clearance 1.75 against the stated 1.8), so the implementer reuses `render-touch-icon-v5.swift`'s exact construction and the app icon matches the website by construction, not by eye. The renderer must still compute and print the actual clearance, per canon rule 2.
- **Sizes**: the `.appiconset` needs 16, 32, 64, 128, 256, 512, 1024 px (16 through 512 at 1x and 2x). All downsampled from the 1024 master; no hand-tuned small sizes in v1. If the AF glyph muddies at 16px, the fallback already exists: re-render the small slots from `af-path-compact.txt`, but only if 16 and 32 actually look muddy in the Dock and Cmd-Tab, checked by eye.
- **The full-bleed square variant** is retained only for a future macOS that genuinely masks, and for iOS. It is not the shipped one. Its renderer output was checked against the shipped website asset `apple-touch-icon-v5.png` at 180px and is pixel identical, 0 of 32,400 pixels differing, max channel delta 0, which is what establishes that the construction itself is right.
- The mark's two out-of-palette colours (`#16161A` plate, `#FAF8F5` glyph) are canonical and must not be "corrected" to `ground`/`textPrimary`. Glyph on plate: 17.02:1, computed.
- **The menu bar decision in 5.9 was narrowed on contact with the code.** 5.9 specified a single monochrome template. The app already carries four deliberate states, and `AFFlowApp.swift` records why: stock SF symbols were removed because the menu bar stopped showing his mark at exactly the moments he is most likely to be looking at it. That structure is kept and only the colours moved onto the brand, because a documented decision with a stated reason is evidence, not an oversight. The idle mark remains a true template; the three status marks take clay and ochre. Two defects were found and fixed in passing: the busy mark's dot was `#8E5E42`, effectively the RETIRED TERRACOTTA, in the most visible surface in the product; and all three coloured marks had white-only glyphs, so they were invisible on a light menu bar. Each now ships a light and a dark rendition. The sidebar lockup (5.1) reuses the same construction at 28pt as a pre-rendered asset.

---

## 9. Canon additions

Paste-ready for `brand-visual.md`, written in its voice. Do not edit that file from this session; this text is handed over.

> ## Application surfaces
>
> Decided 2026-08-25 for AF Flow, and binding on any future app. The full component-level system lives in `af-flow/docs/design/af-flow-visual-system.md`; what follows is the part that travels with the brand.
>
> **An app window is one sheet of `--paper`.** Sidebar, panes, headers and footers all share the one ground; structure comes from type, whitespace and hairlines, never from region fills. The only second surface is `--panel`, reserved for bounded components where text is entered or read. States are tints of ink or signal over the ground, at 6, 10 and 12 percent. Cards do not exist inside app windows.
>
> **Functional status colours, an addition to the thirteen.** Apps have states the website does not, and the signal green cannot mean both "all is well" and "the microphone is live". Three states, each in a light grade for paper and a dark grade for ink surfaces, every grade computed against its surface: ready `#1e5c46` / `#a7e8c6`, busy `#7a5414` / `#e0a94e`, live-and-error `#9e3b24` / `#e8836b`. The clay red is not the retired terracotta and does not revive it; it exists because a hot microphone must read as red at a glance. Recording pulses, errors hold still; that is how the two reds are told apart.
>
> **The app type ladder.** The web display sizes do not fit a utility window. In points: Fraunces 500 at 24 for the one display moment, 21 for section titles, 17 for the name beside the mark, and never below 17. Inter carries everything else: 13 for body and controls, 11.5 for captions, 11 uppercase eyebrows at +0.9pt tracking, 15 and 16 at 1.6 line height for long-form reading. The system mono face covers diagnostics; the brand adds no third family.
>
> **Fraunces never holds user or model content.** It has no Cyrillic, and Andrew's dictated text is Russian more often than not. Fraunces is reserved for strings the product authors; everything a user said, named or received is Inter, which covers Cyrillic completely. The Georgia fallback stays in the stack as a net, and if it ever becomes visible in an app, the bug is in role allocation.
>
> **System chrome stays system.** Menus, alerts and native picker internals are never tinted or restyled; native controls keep their geometry and take the pine tint. The brand's presence in the menu bar is a template rendering of the monogram, not a coloured menu.
>
> **Pointer targets.** The 44px minimum is a touch rule. On pointer-first macOS the minimum control height is 28pt with hit areas of at least 24 by 24. The keyboard focus ring on light app surfaces is 2px ink at 2px offset, the web ring scaled to control sizes; the rule that the ring is never the fill colour on its own background stands.
>
> **The macOS app icon is full bleed.** The current macOS generation masks icons with its own squircle, so rule 4 extends to it: the plate colour fills the square canvas edge to edge and the system cuts the corners. The construction is the canonical 64-unit box scaled by 16, rendered from the outline paths with the clearance computed and printed. The classic rounded-plate-on-transparent variant, plate 824 at radius 180 on 1024, exists only for OS versions that do not mask.
>
> **The open divergence closes.** AF Flow's icon moves to the Fraunces mark with the pine dot as specified above; the Georgia and terracotta icon is superseded, not deleted, under the no deletion rule.

Also for the canon, one-line status change: the "Open divergence" section's AF Flow entry can be marked resolved once slice 5 below ships, with the date.

---

## 10. Sequence

Sequenced against the measured inventory: 454 colour sites (65 raw macOS semantics, 31 `AFFlowPalette` reads, 55 theme reads, 303 system semantic foreground and tint calls) and 660 type sites. Each slice leaves the app shippable and compiling; the baseline is green. Slice 1 is the one that makes the window read as one thing.

1. **One ground, one accent.** Add the new `AppTheme` slots with all three skins' values (2.4); set the `.current` slot values to the brand tokens; kill all 65 raw `Color(nsColor:)` call sites (SettingsWindow 35, transcript viewer 32, onboarding 6, AppState 5) by routing them to slots; delete `AFFlowPalette` and point Home and the overlay at the theme (blue ink to green ink, teal to pine, the band and card fills die per 5.7 and 3). Named-colour map for the rejected colours: all 26 `.tint(.orange)` and the 29 orange foregrounds become `accent`; `.red` becomes `statusLive` except inside the native menu (5.9); `.green` becomes `statusReady` or an `accent` tint per 5.11. The 317 `.secondary`/`.tertiary` sites: **the root-level foreground style remap is ruled out**, because it was tested and SwiftUI derives the lower levels from the primary at 50% and 25% opacity, which measure 3.18:1 and 1.67:1 on `ground`, both contrast failures. Instead: every `.secondary` and every `.tertiary` becomes `theme.textSecondary` explicitly, and every `.primary` that a swept surface touches becomes `theme.textPrimary`. It is 317 mechanical, greppable substitutions, not 317 judgement calls, and there is deliberately no tertiary token (see 2.1). After this slice the entire window, all seven sections, is paper with pine, in San Francisco. That alone delivers "monolith and in my branding".
2. **Type foundations and the daily surfaces.** Bundle the two font files exactly per 4.1 (static Fraunces cut only, loaded by URL or PostScript name, acceptance numbers checked); implement the ladder as the two theme font helpers; convert shell chrome and sidebar, Home (including the two Georgia sites at `HomeWindow.swift:111` and `:116`, which become Fraunces Display), the overlay, and History. Surface-level mixing per 4.4: each converted surface is wholly Inter, everything else stays wholly SF until its turn.
3. **Components.** Sidebar capsule rows (subtitles die), status pill grades and fills, buttons, fields, tables, footer strip, focus and hover states, onboarding sweep (type and components together, 40 sites).
4. **Overlay polish and Settings type.** Overlay edge, dark status grades, secondary text colour, theme slots; then the SettingsWindow type sweep (136 sites).
5. **Icons, the viewer, the canon.** App icon from the mark, menu bar template icon; the transcript viewer pass as its own slice (309 type sites, plus the Georgia pair at `MeetingTranscriptWindow.swift:8805` and `:8806` becoming Reading and Reading large per 5.10); canon update handed over, divergence closed.

Review after each slice per the standing Codex rule, and measure the section 7 checklist after slices 1 and 3, since those move the colours.

---

## 11. Light and dark: the recommendation

**Commit to light. Force the window to light appearance and ship one look.**

Reasons: the canon is light-first and the brand's identity is warm paper; Home already encodes the doctrine that one confident look beats two hedged ones, and Andrew approved that reasoning; the surface he actually stares at all day while dark-mode matters, the recording overlay, is already dark ink and floats correctly over anything; and a second appearance doubles the measured-contrast surface (24 pairs become roughly 48) for a utility window he visits, not lives in. A paper-coloured window on a dark desktop reads as a document, which is the brand's whole metaphor.

**If Andrew wants dark instead, precisely what changes.** The monolith rule, the ladder, the components, the icon and the overlay are appearance-independent and do not change. The light token column is replaced as follows, and the section 7 checklist is re-run against the new surfaces before shipping:

| Token | Dark value | Computed |
|---|---|---|
| `ground` | `#17201D` (`--dark`) | |
| `well` | `#212D28` (addition, a green-cast raised dark) | text on it 12.67, secondary 7.90 |
| `textPrimary` | `#F5F1E8` (`--dark-ink`) | 14.78 on ground |
| `textSecondary` | `#B9C3BE` (`--dark-muted`) | 9.21 on ground |
| `hairline` | mint at 45% per the canon's dark border rule (composites to `#587A69`) | 3.49 on ground, decorative |
| `accent` as text | `#A7E8C6` mist takes over for links, ready text, focus | 11.90 on ground |
| `accent` as fill | pine `#1E5C46` stays for filled buttons with `onAccent` text | 6.97 |
| status colours | the dark grades from 2.2 everywhere | 6.26 to 11.90 |
| `hoverFill` / `pressedFill` / `selectedFill` | `textOnDark` at 6% / 10%, mist at 12%; composites and text ratios must be computed before use | to measure |
| Focus ring | `--signal-soft` per the canon | 11.90 |

The three hover/pressed/selected composites are the only unmeasured cells; they are flagged rather than guessed, per the contrast rule. If he wants both appearances, the dark column becomes a fourth `AppTheme` concern, not a skin, and every pair ships measured in both.
