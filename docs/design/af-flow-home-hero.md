# AF Flow Home: the dark fog hero, and the first-run walkthrough that lives on it

Decision document, 2026-08-25, superseding the same-day first draft in place. Written by the visual designer role; implemented by a separate agent. Companion to `af-flow-visual-system.md`, which stays authoritative for everything this document does not touch; section 12 lists exactly what it amends. The canon is `/Users/andriifrolikov/Claude/AndrewFrolikov OS/Context/brand-visual.md`.

Andrew saw four treatments live and chose D, the dark fog hero that looks like his website. Shown the measurement that centred text over the website's scrim can fall to 1.76:1, he chose to keep the centred composition and fix it with a soft plate. He then expanded the surface: on first run, Home itself walks a new user through setup, over the fog, in his style, and collapses into the compact Home when setup completes, with the shortcut chosen by the user as a step of that walkthrough. Those four decisions are his and are not reopened here; this document makes them excellent.

Every ratio here was computed with the WCAG 2.x relative-luminance formula (script: `hero-contrast.py`, session scratchpad; it reproduces all six published canon pairs to two decimals before asserting anything new). Computed means designed to pass; the implementer re-measures the shipped pixels from screenshots, including video frames, per the canon. The worst-case bounds below assume SDR sRGB video; an HDR encode would break the bounding argument and is therefore forbidden for this asset.

---

## 1. The decision, and the trade

Home keeps the website's dark fog hero, whole: the graded fog clip under the ink scrims, paper and mist type on ink, the same weather his site opens with. It becomes organic in three moves. First, the fog is a **bounded fog plate**, a rounded ink object inset in the paper pane the way a photograph is tipped into a book, so the window never splits into two colour regions and never changes identity when he navigates. Second, the text block stays centred, as he chose, and sits on a **soft plate**: a feathered bank of ink under the block, at a density that guarantees every glyph a named, measurable floor, while the image stays alive at the top and around the edges. Third, the status pill and the chord keycap become **solid objects** with canonical, video-independent contrast, so the two-second glance ("is it ready, what do I hold") never depends on what the fog is doing. On first run the same surface carries the walkthrough (Part 2): five steps over the fog, ending in a collapse into the compact Home. The footer strip stays over the fog, as approved, on a guaranteed band.

**The trade, in one sentence:** the monolith rule loses its absolutism, because the window now carries one bounded ink object, and section 12 amends the rule deliberately rather than pretending the fog plate is not a second surface.

Rejected: full-bleed dark pane with a hard seam against the paper sidebar (the exact "separate colours, separate section in one window" this redesign exists to remove); feathering dark into paper at the sidebar boundary (the blend passes through greys that belong to neither brand surface); taking the whole window dark on Home (the window then changes identity on every click); a permanently dark sidebar (repaints six paper sections for one hero); raising the whole scrim to a uniform 0.76 or more (flattens the clip into near-darkness and wastes the asset); and moving the text block left into the strong end of the diagonal, which the measurement favoured and which I recommended, **rejected by Andrew with the measurement in front of him**. The centred composition plus the soft plate is his call, it is fully sound, and it is what this document engineers.

---

# Part 1: the hero surface

## 2. The four problems of a literal port, solved

### 2.1 The vertical seam

The fog plate solves it structurally. One ground, `#F5F1E8`, still fills the window edge to edge: the sidebar, the title-bar strip, the margins around the fog plate. The dark region is an object ON the sheet, not a second region OF the sheet, with 24pt of ground between its edge and the sidebar hairline. The plate edge needs no border and no shadow: its darkest regions sit near 10:1 against paper, which articulates the boundary by value alone.

**When he clicks General:** nothing happens to the window. The pine capsule moves in the sidebar, the pane swaps its content on the same paper ground, exactly as every section swap works today. The fog plate leaves with Home's content the way a photograph leaves when the page turns.

### 2.2 The window changing identity on every click

Dissolved rather than mitigated. The window has one identity at all times: a sheet of paper. Home does not make the window dark; it places a dark object on the page, which is precisely what andrewfrolikov.com is, a paper page whose first object is a dark hero. Because no ground ever flips, section switches need no cross-fade, no persistence trickery, and no transition design: the instant swap the app already does is correct. This is where "organic" is won: not by softening a flip but by removing the thing that flipped.

### 2.3 Text on moving video: the soft plate

The facts. Measured across the clip, the brightest pixels reach relative luminance 0.8098 after `saturate(0.62)`, an sRGB grey near 232. The website's diagonal scrim runs 0.88 ink at the left to 0.24 at the right, and delivers 10.68:1 for paper text at its strong end and 1.76:1 at its tail (measured over composited real frames): it is a composition that happens to work because the site's text is left-aligned. Home's text is centred, so the scrim alone cannot carry it, and Andrew has chosen to keep it centred. The soft plate is the fix he chose.

**The soft plate.** A feathered bank of ink under the text block:

- **Fill:** `#17201D`. **Core:** a rounded rectangle, radius 28pt, covering the text block's current layout bounds plus 36pt on every side, at a flat **effective alpha of 0.84**. Effective means the composited result of however the implementer builds it (a fill times a mask, a single layer, anything), measured as final ink coverage: the first draft of this document specified a 0.85 fill under a 0.82 mask and the reviewer correctly multiplied them to 0.697, which fails; the spec is therefore stated as the composite, with the burden on the build to reach it.
- **Feather:** from the core edge outward, alpha eases 0.84 to 0 across a 56pt band (any smooth ease; a Gaussian-blurred mask is fine so long as the core invariant below holds). It should read as a bank of deeper fog behind the words, not as a panel with edges.
- **Invariant:** every glyph of the block sits at least 36pt inside the core edge, so the ink under every glyph is at least 0.84 regardless of the feather's shape. The core is derived from the same layout bounds that position the text, so this holds by construction.
- **Growth:** when the block grows (a permission warning appears, an error message, a walkthrough step with more content), the core tracks the new bounds, animating over 250ms ease; the incoming text fades in only once the plate covers its bounds (see 8.1), so no glyph ever renders off the plate. Reduced motion: both changes are instant.
- **The guaranteed worst-case surface: ink `#17201D` at 84% over pure white, which composites to `#3C4441`, relative luminance 0.0544.** Compositing is monotone per channel, so ink at 0.84 over any SDR video pixel is darker per channel than over pure white; for light text the true ratio is always at or above this bound, on every frame of any SDR encode, present or future. On that floor: paper text 8.92:1, `#B9C3BE` 5.56:1, mist `#A7E8C6` 7.18:1 (all against 4.5), clay dot `#E8836B` 3.78:1 and ochre dot `#E0A94E` 4.77:1 (against 3).
- **Why one density, not tiers.** The per-element minimum alphas over pure white are computed at 0.643 for paper body text, 0.780 for `#B9C3BE`, 0.707 for mist, and 0.513 for the Fraunces 24pt line at its large-text 3:1 (these are the strict-bound versions of the 61/76/46 percent figures measured over real frames). A plate that thinned per zone would save at most 0.2 of alpha in places while making the object visibly lumpy and the guarantee three rules instead of one; the single 0.84 core dominates every tier with margin.
- **Error text is paper, not clay.** `#E8836B` on the floor measures 3.78:1, below 4.5, so on the fog the error message is set in paper with a 7pt `#E8836B` dot marker before it (3.78 against the 3:1 non-text minimum, passes). The pill above has already turned red; the dot ties the message to it. The light-mode rule (error text in `statusLive`) is unchanged on paper surfaces.

The website's diagonal scrim survives **verbatim as mood, not as guarantee** (4, layer 3): it is part of what he approved, it shapes the light across the whole plate, and with the soft plate carrying the floor it no longer has a legibility job.

### 2.4 The pill and footer were designed for paper

- **The status pill takes the recording overlay's dark vocabulary** (visual system 5.8), which already solved status-on-ink: a solid `#17201D` capsule, 1px `#F5F1E8` at 30% edge, label in paper, 7pt dot in the dark status grades: ready `#A7E8C6`, busy `#E0A94E`, live and error `#E8836B`. Every pair is canonical and video-independent: label 14.78:1, dots 11.90, 7.90, 6.26 against 3:1. Busy and live pulse, per the system's section 6. The same status object he watches all day in the overlay now sits on the fog, which is coherence, not coincidence.
- **The footer strip stays over the fog**, as in what he approved, in dark grades on a guaranteed band: the grounding scrim (4, layer 4) holds a flat 0.88 from the plate's bottom edge up to 8pt above the footer's top hairline, so every footer glyph sits on at least ink 0.88 over white, `#333B38`, luminance 0.0409. On that band: eyebrows `#B9C3BE` 6.39:1, values `#F5F1E8` 10.25:1, the privacy value in mist `#A7E8C6` 8.25:1 (all against 4.5). Top hairline: paper at 30%, decorative. Cells stay three across with their existing structure.
- **The chord keycap is a solid `well` `#FFFDF7` fill with ink text**, 16.37:1, radius 8pt, no hairline border on the fog (on ink the edge articulates itself; the light-surface keycap keeps its border). It is the single lightest object on the plate, which is deliberate: the chord is what the eye must find first.
- **The fill rule on the fog, so nothing else drifts:** every fill on the fog plate is ink-side (it darkens), never paper-side, with exactly two solid light exceptions: the chord keycap in every state it takes, including the shortcut capture field of 7.3, which is the keycap being chosen, and the transcription well (7.4). Both exceptions carry ink text at 16.37:1. Translucent paper-side fills over video are how contrast quietly dies, and they are banned.

---

## 3. Layout and geometry

The pane is fluid; numbers are exact at the brief's two reference widths and interpolate between and above them. At the 1000pt default window with the 232pt sidebar the pane is about 768pt; everything holds down to the 530pt floor, and the 900x680 minimum window gives a pane wider than either reference.

**Fog plate.** Inset in the pane: 24pt leading and trailing, 34pt top, 24pt bottom. Corner radius 14pt (the canon's card radius). No border, no shadow. The 34pt top inset carries an invariant: the ink never enters the title-bar strip, so the window title stays ink on paper; if the content view is not full-size under the title bar, the inset reduces so that 8pt of paper remains below the title bar.

**Compact Home (after setup).** Centred column, maximum text width 340pt, vertically centred between the plate top and the footer. Order and rhythm as today: status pill, then 26pt (10pt when a permission warning is present, warning below the pill), instruction lines ("Hold" with the keycap inline, then "and speak", Fraunces 24pt, 6pt line gap), 14pt to the release sub-line (Inter 13.5 paper), 18pt to the hands-free line (Inter 12 `#B9C3BE`), error message below with 16pt (paper text, clay dot marker). Soft plate core: block bounds + 36pt, so at most roughly 412pt wide.

**Walkthrough (first run).** Same region, centred column, maximum width 400pt, 40pt minimum side padding inside the plate (402pt available at the 530pt pane floor, so it fits exactly there). The footer is hidden during the walkthrough and appears at the collapse: its three facts are the outcome of setup and are not yet true while setup runs. On the dense Setup step the soft plate core (400 + 72) approaches the plate's width at the 530pt floor and the feather clips at the plate edge; accepted, that step is a form and earns the coverage.

**Footer.** Inside the fog plate, full plate width, at the bottom: 52pt tall, top hairline paper at 30%, cells with 32pt side padding, over the 0.88 band (2.4).

| Measure | Pane 630pt | Pane 530pt |
|---|---|---|
| Fog plate width | 582pt | 482pt |
| Fog plate height at a 680pt pane height | 622pt | 622pt (shrinks by whatever height the title bar takes from the content view; the 8pt-below-title invariant governs, not this number) |
| Compact column / soft plate core width | 340 / up to 412pt | 340 / up to 412pt |
| Walkthrough column | 400pt | 400pt |
| Footer | 582 x 52pt | 482 x 52pt |

**Reading order, compact Home.** The block sits at the pane's optical centre. First fixation: the solid paper keycap inside the Fraunces instruction, the highest-contrast object on the plate (16.37:1). Second: the status pill directly above it, whose dot colour answers the two-second question ("is it ready") without reading the label. Third: the sub-lines. Fourth: the footer facts along the bottom. In the real usage scene, the window opened for two seconds, status and chord are the two brightest, most central objects, and both are solid: the glance never waits on the fog.

---

## 4. Treatment: the exact layer stack

Bottom to top inside the fog plate. Layers 1 and 2 are baked into the shipped asset (section 10); the rest are live, cheap, static layers.

1. **The graded fog.** The clip with the grade baked in: `saturate(0.62)` (the website's own value, what he approved), then a blue-channel gain of 0.88 (one line of colour matrix). Measured effect on the mean frame: raw `rgb(32, 75, 98)`, blue minus green +23.0, which is why the raw clip reads blue; after the grade `rgb(45.5, 72.2, 76.0)`, blue minus green +3.9, a neutral sea-green that the green-cast ink scrims then finish into the brand. The poster is frame zero of the graded encode, so the two can never mismatch. Playback fills the plate, aspect-fill, centre crop.
2. **Grain guard.** The encode keeps the clip's native grain (no denoising pass), which is what prevents banding inside the dark scrims.
3. **The diagonal scrim, verbatim from the site:** `#17201D` at 0.88, 0.72, 0.40, 0.24 along the site's 100-degree axis (for SwiftUI, unit points (0, 0.39) to (1, 0.61) at the default plate aspect; the exact tilt is mood, not guarantee, so small aspect drift is fine). This is the light of the hero he approved.
4. **The grounding scrim:** `#17201D`, flat 0.88 from the plate's bottom edge up to 8pt above the footer's top hairline, then easing to 0 at 45% of the plate height. The flat band is the footer's guarantee (2.4); the ease above it is the site's bottom scrim.
5. **The soft plate** (2.3), tracking the text block.
6. **Content:** the text block, the solid pill and keycap, and on first run the walkthrough (Part 2).

Edges: fog plate radius 14pt, no stroke. Pill edge 1px paper at 30% (decorative). Keycap: no stroke on the fog. Masks: none beyond the soft plate's own feather.

**Native controls on the fog** (the walkthrough uses a few: progress indicators, the input-device picker): the plate's subtree takes explicit dark appearance so system chrome renders its dark forms, the same precedent as the overlay's ProgressView, and the tint on dark is mist per the canon. **Keyboard focus on the fog is the canon's dark ring: `--signal-soft` mist**, 7.18:1 against the soft-plate floor, well above the 3:1 non-text minimum. The window's forced-light rule (visual system, section 3) stands everywhere outside the plate.

---

## 5. Motion of the fog

- **Rate:** 0.5x, so the 10s clip reads as 20s, matching the site. Mean luminance across the clip moves only 0.117 to 0.132, so nothing pulses behind the text.
- **The loop seam: ping-pong.** Forward 20 seconds, then reverse 20 seconds, a 40-second cycle with no seam by construction. This is what the approved preview ran, and it is what he judged. Reverse playback is measured at the same cost as forward. The fallback, if the direction turn reads as a bounce on the built app, is the website's own crossfade-to-still: fade the video to the poster over a 0.75s wall-clock envelope at the seam, restart from frame zero, fade back in; frame zero equals the poster, so the loop cannot jump.
- **Start:** the player exists and plays only while all three are true: the window is really visible (the app's own `afFlowWindowVisibilityChanged` signal, which exists precisely because `orderOut` does not unmount SwiftUI), Home is the selected section, and Reduce Motion is off. First appearance: poster immediately, video fades in over 700ms linear once the first frame is ready, invisible because the poster is frame zero. The fog runs identically under the walkthrough and the compact Home; it never restarts on a step change.
- **Stop:** on any of the three going false, pause and release the player (frees the measured 45 MB). On return, restart from frame zero behind the same 700ms fade; ambience has no plot, so a deterministic restart beats resuming mid-clip against a frame-zero poster.
- **Reduced motion, non-negotiable:** the player is never created and the clip never decoded; the plate shows the graded poster under the same scrims, so every contrast number holds unchanged. Pill pulse collapses to full opacity per the system's section 6; the dot colour still carries the state.
- **Budget, measured:** looping playback costs 0.2 to 0.4% of one core and 45 MB while Home is visible, zero when it is not.

---

# Part 2: the first-run walkthrough

## 6. What it is, and the rules it obeys

On first run (`onboardingCompleted` false), Home's fog plate carries the walkthrough instead of the compact block: five steps, one column, over the same fog. When setup completes it collapses in place into the compact Home (8.2). It can be re-invoked later from Settings, and if the app quits or the window closes mid-way, it resumes at the first incomplete step. The sidebar stays present and usable throughout; a new user who wanders off finds the walkthrough waiting where they left it.

The existing onboarding (`OnboardingWindow.swift`, a separate 480x620 window) is the source of what these steps teach, and Andrew's verdict on it stands: "it was very simple and it was great." **This is a redesign of where it lives and how it looks, not of what it teaches.** Its window retires when this ships, superseded, not deleted.

Hard rules, each with its reason:

1. **There is no Accessibility step, row, button, or mention, anywhere in the walkthrough.** Measured 2026-08-21: sandboxed builds return AXError -25204 on all 28 queries, after every grant, and the sandbox stays. The shipping SetupStep's Accessibility row and the TryItStep failure message that names Accessibility are both defects under this rule. The permission surface is exactly two grants: **Microphone** and **Input Monitoring**.
2. **Every chord string on every surface reads the live binding.** The shipping TryItStep breaks this at four sites: the waiting message hardcodes the chord (line 662), the hotkey monitor binds `AppState.defaultPushToTalkChord` rather than the user's binding (line 690), the instruction hardcodes "Right Command + Right Option" (line 773), and the two keycaps hardcode their labels (line 778), so it can tell a new user to hold keys that do nothing. Home was fixed for this exact defect class on 2026-07-26: "the screen has to say what is actually bound, or the first thing the app tells him is a lie." The rule is a literal ban: no chord literal may appear in any string or keycap; every one renders `displayString` of the live binding it claims to describe.
3. **The fill rule (2.4) applies to every step:** ink-side fills only, except the keycap and the transcription well.
4. **User and model content is Inter; Fraunces only for what the app authors** (visual system 4.2). The transcribed try-it text, device names, and model names are Inter; step titles are Fraunces.
5. **Resource honesty:** anything that polls, listens, or decodes runs only while its step is current AND the window is really visible, and says so in its spec below. One deliberate exception: a model download, once started, runs to completion in the background regardless of visibility, because cancelling a multi-hundred-megabyte download when the window hides wastes the user's bandwidth; only its UI rendering is gated on visibility.

**Resume, persisted honestly.** Three stored booleans: `onboardingCompleted` (exists today, set by the collapse), `onboardingWelcomeSeen` (set by Get Started), and `onboardingShortcutChosen` (set by Use this or Keep it). Everything else is derived live from the system: grants are queryable and models report their own state, so no stored step index can go stale against reality. On entering an incomplete walkthrough: Welcome if not seen; else Setup if a grant is missing or models are not ready; else Your shortcut if not chosen; else Try it. "Set up later" advances without setting any flag, so an abandoned skip resumes at Setup, which is correct: the skip was a deferral, not a completion.

There is no step counter. The four-step original had none and he called it great; each step advances with one obvious action, and a counter is furniture on a surface he asked to keep brief and beautiful. Recorded as my call, cheap to reverse.

## 7. The steps

Common frame: each step is a centred column (max 400pt) on the soft plate, over the fog. Step titles: Fraunces 21pt paper. Body: Inter 13 paper; secondary: Inter 13 `#B9C3BE`; captions: Inter 11.5 `#B9C3BE`. Primary buttons: pine `#1E5C46` capsule, paper text (6.97:1), the system's primary button unchanged. Ghost buttons on the fog: capsule, 1px paper at 30% border, paper label (8.92:1 on the floor; the label, not the decorative border, carries the affordance). Rows and summaries sit in **dark wells**: fill ink `#17201D` at 55% over the soft plate (effective ink 0.928 over white, surface `#28302D`), radius 12pt, no border; on them paper 12.01:1, `#B9C3BE` 7.49:1, mist 9.67:1, clay dot 5.09:1, ochre dot 6.42:1.

### 7.1 Welcome

The cover. No icon: the mark's plate is invisible on ink without a hairline, the canon permits that hairline only in the website header, and the sidebar lockup already shows the mark 24pt away. Instead: **"AF Flow" in Fraunces 24pt paper**, then the tagline "Sovereign personal intelligence for your Mac", Inter 15 `#B9C3BE`, then the two reassurance lines kept verbatim from the shipping step (open-source models under your control; no accounts, everything stays on this Mac), each with its SF Symbol in mist, Inter 13 `#B9C3BE`, left-aligned as a pair within the centred column, no box around them (boxes on the fog are dark wells, and reassurances are prose, not a form). One action: **Get Started**, primary. Generous vertical air; the fog is the artwork and this step is the one place it is allowed to dominate.

### 7.2 Setup

Title "Setup" (the chili emoji retires with the Ghost Pepper era). Sub-line: "Grant two permissions. AF Flow chooses the local models." Then three dark wells:

- **Microphone**, "To hear your voice". States: waiting (small primary **Grant**, which triggers the system prompt); granted (mist check); denied (clay dot, "Denied", small primary **Open Settings** opening the Microphone privacy pane). While granted, below the row: the input-device picker (native, dark appearance, only when more than one device) and the **sound check**: an 8pt meter, track ink at 55% over the well, a recessed groove (decorative, and ink-side per the fill rule), fill mist, turning `#E8836B` above 0.7 (hot), with the caption "Say something" until the first sound arrives. If the audio engine fails to start despite the grant: caption in paper with a clay dot, "The microphone could not start. Check the selected device." The meter runs only on this step while granted and visible, and stops on leaving it.
- **Input Monitoring**, "To notice your shortcut". States: waiting (**Grant**, opening the Input Monitoring privacy pane, which is the only way macOS grants it); granted (mist check). Returning from the pane without granting is not an error, just still waiting: the row keeps its **Grant** button and gains the caption "Not granted yet. macOS grants this in System Settings." in `#B9C3BE`. This grant is what the shortcut capture (7.3) and the hotkey itself need; the copy never mentions Accessibility.
- **Local models**, subtitle mirroring the live status ("Downloading the local models AF Flow needs", "Downloading 43%", "Ready for voice-to-text", "Download failed"). States: downloading (native progress, dark, mini); failed (clay dot, small primary **Retry**); ready (mist check). Below it the model summary rows (Voice, Cleanup: name, size, per-row status) in the same well, Inter, with the existing caption "AF Flow picks these during onboarding. Advanced model controls live in Settings."

**Continue**, primary, appears when microphone and Input Monitoring are granted and both models are ready. Below it always: "Set up later", a caption-weight link in `#B9C3BE` (5.56:1), which advances anyway, and skipping must be safe, not silent, on both axes: a missing grant resurfaces on the compact Home as the existing permission-warning line, and missing models surface through the status pill, which reads the app's live status and shows busy while a model still downloads and error with the message line if a download failed. The permission-warning line is permission-specific and does not know about models, so the pill path is load-bearing: the implementer verifies that model failure genuinely reaches `AppStatus`, and if it does not, the warning line is extended to name the missing model rather than letting the pill claim Ready.

**Polling, exactly:** microphone and Input Monitoring status poll every 2 seconds only while this step is current AND the window is visible per `afFlowWindowVisibilityChanged`; polling stops the moment both are granted, the step changes, or the window hides. Accessibility is never queried. This keeps the earlier review's fix intact: the front door does not poll.

### 7.3 Your shortcut

New step, his decision: "not everyone may like Left Control plus Globe." Title "Your shortcut". Sub-line: "Hold these keys anywhere, speak, release. Your words land where the cursor is."

- **Default offered:** the live stored push-to-talk binding rendered as the solid keycap (live `displayString`, rule 6.2), centred, with two actions: **Use this** (primary) and **Press my own** (ghost). On a true first run the stored binding is the factory default, so a new user sees the default; on a rerun the user sees their own current chord, never a factory reset dressed as an offer.
- **Capture:** choosing "Press my own" turns the keycap area into a capture field: solid well, 2px mist focus border (the canon's dark focus), placeholder "Hold the keys you want" in `#626C68` (5.34:1 on well). While keys are held, the field shows them live in ink; releasing after a hold of at least 250ms sets the binding. Then: mist check, "That's yours:" with the new chord in a keycap, actions **Keep it** (primary) and **Try again** (ghost). Escape cancels back to the default offer.
- **Guards:** the chord binding store rejects a chord that collides with **any** existing action, not only the hands-free toggle, so the capture field refuses a colliding chord with a clay-dot caption naming the owner ("That's already your hands-free shortcut", "That's already used by Pepper Chat", and so on from the store's own collision report) and stays in capture. If the store rejects a write for any other reason, the field shows a clay-dot caption "Could not save that shortcut" with **Try again**; the binding never silently fails to persist. If Input Monitoring is missing (possible via "Set up later"), the capture field is replaced by a caption with a clay dot, "AF Flow cannot see the keyboard yet", and a ghost **Back to Setup**.
- The chosen chord writes through the same store Home reads, and the walkthrough only advances past this step on a confirmed successful write, so the instruction on the collapsed Home is true for every user by construction. The hands-free toggle chord is not captured here: one capture kept the step brief, and the caption under the actions says "Hands-free and other shortcuts live in Settings." Recorded as my call.

### 7.4 Try it

Title "Try it". Instruction: "Hold" plus the solid keycap rendering the **live** binding chosen in 7.3, "and say something", Inter 13 paper (this step teaches the gesture; the Fraunces display line belongs to the compact Home it collapses into). The hotkey monitor for this step binds the live chord, closing the second half of the line-690/773 defect.

States, in the same centre area (min height reserved so the layout does not jump):

- **Waiting:** "Waiting for you..." in `#B9C3BE`.
- **Listening:** 10pt `#E8836B` dot, pulsing, with "Listening..." in paper.
- **Transcribing:** native progress (dark, small) with "Transcribing..." in paper.
- **Result:** the transcription, quoted, Inter 15 ink on a **solid `#FFFDF7` well** (user content on the brand's reading surface, 16.37:1), max width 400pt; beneath it a mist check and "It works. Your words land where the cursor is." in mist (7.18:1 on the floor, 9.67:1 on a well backdrop). Auto-advance after 2 seconds, as shipped.
- **No speech:** clay dot plus paper text, "No speech detected. Check the microphone and try again." A transcription that comes back nil, empty, or whitespace-only all map here, never to Result: an empty quoted well congratulating the user would be the interface lying politely.
- **Monitor failed** (start retries exhausted): clay dot plus paper text, "AF Flow cannot see the keyboard yet. Grant Input Monitoring, then come back.", with ghost **Back to Setup**. Accessibility is not mentioned.

Actions: **Skip** (ghost) and **Continue** (primary). The recorder, transcriber warm-up, and monitor live only while this step is current and the window visible, torn down on exit, as the shipping step already does.

### 7.5 You're all set

Mist check at 48pt, title "You're all set" in Fraunces 24pt paper (the completion beat earns the display size), sub-line "AF Flow lives in your menu bar" in `#B9C3BE`. Then, replacing the shipped fake-menu-bar mockup (a light strip would fight the fog and the fill rule): a single line with the menu bar mark glyph rendered in paper at 18pt and "Look for this mark in your menu bar" in paper. Then the five capability bullets kept verbatim from the shipping step, mist bullet dots, Inter 13 `#B9C3BE`, left-aligned within the column. One action: **Start Using AF Flow**, primary, which sets `onboardingCompleted` and runs the collapse. The step does not linger: no further reading gates the button.

## 8. Transitions, the collapse, and resources

### 8.1 Between steps

600ms on the canon's reveal curve, cubic-bezier(0.22, 0.7, 0.2, 1): the outgoing step fades out over the first 250ms; the soft plate animates to the incoming step's core bounds over 300ms starting at 150ms; the incoming step fades in over the final 350ms with an 8pt upward drift, beginning only once the plate covers its bounds, so the floor invariant holds mid-transition. The fog underneath never reacts to steps. Reduced motion: instant swap, plate resized instantly.

### 8.2 The collapse

On "Start Using AF Flow": the walkthrough column fades out over 250ms; the soft plate morphs to the compact block's core; the compact Home (pill, instruction with the user's own chord, sub-lines) fades in over the final 350ms of a 700ms envelope; the footer fades in with it. The fog does not blink, which is what makes the collapse read as the same place quieting down rather than a screen change. Reduced motion: instant. Re-invoking later ("Run setup again", a link-style control in General, one line added to that section) runs the same walkthrough from Welcome and collapses the same way.

### 8.3 Resource lifecycles, in one place

| Thing | Runs | Stops |
|---|---|---|
| Fog playback | window visible AND Home selected AND motion allowed | any of the three false; player released |
| Permission polling (mic + Input Monitoring, 2s) | Setup step current AND window visible | both granted, step change, or window hidden |
| Mic level meter | Setup step, mic granted, window visible | leaving the step or hiding the window |
| Model download | started on the Setup step | runs to completion or failure in the background, the rule-5 exception; UI rendering of its state gated on visibility |
| Hotkey capture (7.3) | capture mode active AND window visible | leaving capture, leaving the step, or hiding the window |
| Try-it monitor, recorder, and transcriber warm-up | Try it step current AND window visible | leaving the step or hiding the window; existing teardown |
| Accessibility queries | never | n/a |

---

# Part 3: proofs, assets, decisions, amendments

## 9. Contrast pairs to prove

**Note added by the implementer, 2026-08-25.** Every figure in this table is computed in continuous float. The pixel that reaches the screen is 8-bit, and quantising the composites moves each ratio by about 0.03: the plate floor reads 8.891 / 5.542 / 7.159 / 3.766 / 4.751 and the footer band 10.217 / 6.368 / 8.227. The difference never changes a verdict, every pair still clears its minimum, and the tests pin the QUANTISED values because those are what a screenshot sampler reads back.

Floors are named surfaces: **the soft-plate floor `#3C4441`** (ink 0.84 over pure white, L 0.0544), **the footer band `#333B38`** (ink 0.88 over pure white, L 0.0409), **the dark well `#28302D`** (ink 0.55 over the soft-plate floor, effective 0.928, L 0.0276). The white bound dominates every SDR video pixel (2.3). The implementer measures each pair on the built app from screenshots including at least twelve video frames, per the canon.

| # | Foreground | Background | Computed | Minimum | Where |
|---|---|---|---|---|---|
| 1 | `#F5F1E8` | `#3C4441` floor | 8.92 | 4.5 | instruction, body text, error text, step titles |
| 2 | `#B9C3BE` | `#3C4441` floor | 5.56 | 4.5 | sub-lines, captions, "Set up later" |
| 3 | `#A7E8C6` | `#3C4441` floor | 7.18 | 4.5 | "It works" line, mist accents |
| 4 | `#E8836B` | `#3C4441` floor | 3.78 | 3 | error dot markers, listening dot |
| 5 | `#E0A94E` | `#3C4441` floor | 4.77 | 3 | any busy marker on the plate |
| 6 | `#A7E8C6` ring | `#3C4441` floor | 7.18 | 3 | keyboard focus on the fog |
| 7 | `#F5F1E8` | `#28302D` dark well | 12.01 | 4.5 | row titles, model names |
| 8 | `#B9C3BE` | `#28302D` dark well | 7.49 | 4.5 | row subtitles, summary captions |
| 9 | `#A7E8C6` | `#28302D` dark well | 9.67 | 3 | granted checks, meter fill |
| 10 | `#E8836B` | `#28302D` dark well | 5.09 | 3 | denied dots |
| 11 | `#F5F1E8` | `#333B38` footer band | 10.25 | 4.5 | footer values |
| 12 | `#B9C3BE` | `#333B38` footer band | 6.39 | 4.5 | footer eyebrows |
| 13 | `#A7E8C6` | `#333B38` footer band | 8.25 | 4.5 | footer privacy value |
| 14 | `#F5F1E8` | `#17201D` pill fill | 14.78 | 4.5 | pill label |
| 15 | `#A7E8C6` | `#17201D` pill fill | 11.90 | 3 | ready dot |
| 16 | `#E0A94E` | `#17201D` pill fill | 7.90 | 3 | busy dot |
| 17 | `#E8836B` | `#17201D` pill fill | 6.26 | 3 | live and error dot |
| 18 | `#17201D` | `#FFFDF7` | 16.37 | 4.5 | keycap text, transcription text |
| 19 | `#626C68` | `#FFFDF7` | 5.34 | 4.5 | capture-field placeholder |
| 20 | `#F5F1E8` | `#1E5C46` | 6.97 | 4.5 | primary buttons |

Banned on the fog, with the measured reason: `#E8836B` as body text (3.78 on the floor, hence the paper-plus-dot error treatment); any paper-side translucent fill outside the two solid light objects (2.4); any text outside the soft plate's core or the footer band (the open fog reaches ink 0.24, where paper text bounds at 1.47:1). The Fraunces 24pt lines qualify as large text (3:1) but are held to 4.5 anyway. Decorative pairs with no requirement, listed so nobody "fixes" them: fog plate against paper ground; pill and ghost edges at paper 30%; the footer hairline; the meter track. To measure on the built app, not asserted here: the shipped pixels of every row above, and behaviour under the system Increase Contrast setting.

## 10. Assets

- **`hero-fog-960-graded.mp4`, 960x540, the shipped encode.** The ungraded 960x540 measured 948 KB; the graded re-encode will land near that, exact size to measure. Why not the 341 KB 640x360: at the default window the plate is about 720pt, 1440 physical pixels on Retina, a 1.5x upscale from 960 and a 2.25x from 640; fog forgives upscaling but the dark gradient regions are where banding lives, and 600 KB is noise in an app bundle. Decode cost is measured equal across encodes. SDR only (section header rule).
- **`hero-poster-graded.jpg`**: frame zero of the graded encode, extracted after grading so poster and video match by construction. Serves reduced motion, pre-play, and the crossfade fallback.
- The grade (saturate 0.62, blue gain 0.88) ships **inside the assets**, not as runtime filters: zero runtime colour cost, and the poster cannot drift from the video.
- Nothing else ships. Scrims, the soft plate, pill, keycap, wells, and every walkthrough element are drawn, not assets.

## 11. Genuinely his to decide

1. **Bounded fog plate versus literal full-bleed.** He chose variant D, which was full-bleed; this document bounds it (2.1, 2.2) and I recommend the plate without hedging. If, on the built app, he wants full-bleed back: plate insets go to zero, radius to zero, the vertical seam against the paper sidebar returns as an accepted cost, and everything else in this document survives unchanged, footer band included.
2. **The ping-pong turn**, judged by his eye on the built app; the crossfade-to-still fallback in section 5 is ready. The default ships.
3. Decided by me, cheap to reverse if he objects on sight: no step counter (6); the toggle chord not captured during onboarding (7.3); the Done step's menu-bar mockup replaced by the mark line (7.5); the Welcome step dropping the 128px icon for the Fraunces name (7.1, forced by the canon's hairline rule).

## 12. Amendments and canon additions

### 12.1 Amendments to `af-flow-visual-system.md`

Paste-ready, to be applied when this ships; recorded here first because that file is not modified by this pass:

> **Amendment 2026-08-25, by Andrew's choice (Home hero).** Home carries one bounded media object: the fog plate, a rounded ink region holding the graded hero clip under its scrims, inset in the ground on all sides, specified in `af-flow-home-hero.md`. It is the only permitted region-scale fill in the app, it exists only on Home, and it does not license cards, bands, or tinted regions anywhere else. On the fog plate, and only there: the status pill takes the overlay's dark vocabulary (solid ink capsule, paper label, dark-grade dot, paper-30% edge) in place of 5.7's tinted pill; error messages are paper with a clay dot marker in place of 5.7's clay text; the keycap well carries no hairline; ghost buttons on the fog take a paper-30% border in place of 5.3's `hairline` token; the hairline whitelist in section 3 gains the pill edge, the fog ghost border, and the footer's top hairline in their dark grades; dark wells (ink 55% over the soft plate) are the fog-side counterpart of `well`, and the solid light exceptions are exactly the chord keycap (capture state included) and the transcription well. Every one of these carries a computed pair in `af-flow-home-hero.md` section 9. Reviewer check, updated: sampling background pixels outside wells, bounded components, and the Home plate must still return exactly `#F5F1E8`; distinct background colours across the window: three on Home (`ground`, `well`, the plate), two everywhere else.
>
> **The hero is a brand-skin surface.** Under Windows 95 and Space, the fog plate, its scrims, and the dark components do not render: Home lays out the same content, compact or walkthrough, on the skin's own themed ground with the skin's existing component vocabulary. This keeps 2.4's contract (a skin skins every surface) without asking novelty skins to carry a brand asset.
>
> **Onboarding moves into Home** (first run, over the hero; collapse to compact Home on completion; re-invocable from General), specified in `af-flow-home-hero.md` Part 2. The separate onboarding window (5.11's host) is superseded, not deleted. 5.11's token rules apply wherever that walkthrough renders on paper (novelty skins, and any paper fallback).

### 12.2 Canon addition (`brand-visual.md`)

Paste-ready, in the canon's voice, handed over rather than applied:

> **The fog hero.** The dark fog opening is a brand surface, not a website feature: the front door of andrewfrolikov.com and of AF Flow are the same weather. The recipe travels: the fog clip graded to the brand (saturate 0.62, then blue channel at 0.88, which takes the clip's blue cast, measured blue minus green of +23, to a neutral +4 that the ink scrims finish into green), under the ink scrims. The scrims are composition, not dimming: measured over real frames, the strong end of the site's diagonal delivers 10.7:1 for paper text and the tail 1.76:1, so text sits either in a region the scrim genuinely covers or on a soft plate of deeper ink added under the block. **Text over video always names its guaranteed worst-case surface**: the minimum ink coverage under the text, composited over pure white, which bounds every frame of any SDR encode; AF Flow's floors are `#3C4441` at 84% coverage and `#333B38` at 88%. The loop runs at half speed and closes by ping-pong or by crossfading into its own first frame; reduced motion never downloads or decodes the clip and shows the graded poster at identical contrast.

### 12.3 Recorded divergences and review

- The app's hero keeps the site's diagonal scrim as mood; the legibility floor comes from the soft plate, because the app's block is centred (Andrew's choice) where the site's is left-aligned.
- The walkthrough teaches what `OnboardingWindow.swift` taught, minus the Accessibility step (sandbox-blocked by measurement, 2026-08-21) and plus the shortcut step (Andrew's addition); its four chord-literal defects (waiting string at line 662, monitor binding at line 690, instruction at line 773, keycaps at line 778) are closed by rule 6.2.
- Independent review: Codex (read-only) reviewed this document twice on 2026-08-25. Round one found four defects in the first draft (a multiplied-alpha arithmetic error, the unresolved novelty-skin contract, the un-amended supersession of 5.7, and border inconsistencies); round two verified all arithmetic to four decimals and all round-one fixes, and found nine further gaps (two fill-rule violations, resource-table disagreements, the undercounted chord defects, the "Set up later" model gap, the incomplete collision guard, missing empty-state mapping, unpersisted resume semantics, the conditional 622pt height, and the un-amended ghost border). All thirteen findings are incorporated in this text.
