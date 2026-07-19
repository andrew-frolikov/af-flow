# AF Flow: voice test protocol

Andrew reads the scripts aloud via AF Flow into the target app. Read naturally, at normal speed, and do NOT suppress your real ums, pauses, and restarts: the cleanup layer must handle them. Claude Code records pass/fail and latency in PROGRESS.md.

Scope, amended 2026-07-18 on measured usage data and applied here 2026-07-19: v1 is English plus Russian plus mixed RU/EN. Ukrainian is out of v1, so T3 and T4 have moved to the post-v1 section at the bottom and neither gates any chunk. The v1 set is T1, T2, T5, T6, T7, T8, T9, T10.

## T1 English brain-dump (60s, core loop)
Read into Claude desktop:
"Okay so, um, quick thoughts on the job search this week. I want to, uh, follow up with the recruiter from Tuesday, the one about the account executive role, and I should probably, no wait, I definitely need to update the pipeline spreadsheet first. Then LinkedIn: draft a post about the AF Flow build, something about how a non-coder ships a real Mac app by directing AI agents. Keep it concrete, numbers, no hype. Also groceries after four, and, um, check whether the EI report is due this Friday or next."
PASS: fillers and false starts gone, punctuation clean, no em dashes, meaning intact, lands at cursor.

## T2 Russian brain-dump (~40s)
Read into Telegram (changed from Obsidian 2026-07-19: Obsidian has zero recorded dictations, Telegram is the measured number two target at 25):
"Так, значит, по поводу квартиры. Надо, эээ, позвонить насчёт интернета, потому что Shaw опять поднял цену, и посмотреть, есть ли альтернативы дешевле. Потом, ну, записать идею для канала: короткое видео про то, как я строю своё приложение для диктовки. И ещё не забыть про день рождения мамы, подарок надо заказать заранее."
PASS: clean Russian, fillers (эээ, ну, значит) removed, Shaw stays Latin, output entirely Russian.

## T5 Mixed RU/EN (his real register)
Read into Claude desktop:
"Значит, идея такая: я хочу сделать pivot в контенте и больше говорить про vibe coding и агентов, потому что это, ну, use case, который сейчас всем интересен. Ранние, эээ, early adopters уже это делают, и я хочу double down на этой теме."
PASS: clean single-language Russian with the allowlisted English terms kept in English (pivot, vibe coding, use case, early adopters, double down); no chaotic word salad.

## T6 Dictionary terms and snippets

PENDING REWRITE. The list below was written from memory and the real one is known to differ: the actual Wispr dictionary has 13 entries, roughly half of them snippets rather than spelling fixes, and it includes terms this list misses. Rewriting it from the real entries is queued behind the completed extraction so it is done once. Do not seed C3 from the list below.

Provisional (from memory, to be replaced): Frolikov, Andrii, Softchoice, WWT, ENA Solution, Kharkiv, Calgary, Cowork, Wispr Flow, AF Flow, WhisperKit, Qwen, Obsidian.

Two kinds must be tested, not one:
- Spelling protection: dictate each term in a sentence, all must come out spelled exactly.
- Snippet expansion: dictate each trigger phrase, the expansion must land in full and must not be rewritten by the cleanup model afterwards.

## T7 Insertion matrix (each app: T1 or T5 script, shortened)

Weighted by measured usage, not treated as six equals. Claude desktop is 86 percent of all real dictation (1162 of 1355), so it is tested hardest and a failure there is a v1 blocker. A failure in a tail target is a known issue, not a blocker. Obsidian is removed from the matrix: zero recorded dictations.

| Target | Real share | Insert works | Clipboard restored | Notes |
|---|---|---|---|---|
| Claude desktop (Electron) | 86% | | | primary target, blocker if it fails, test repeatedly and under load |
| Telegram desktop | 2% | | | second real target |
| Chrome (incl Gmail compose) | 2% | | | |
| Codex | 1% | | | |
| TextEdit (control) | n/a | | | isolates app-specific bugs from insertion bugs |
| macOS password field | n/a | | | MUST refuse cleanly with the Secure Input message, not crash |

## T8 Hotkey
fn/globe hold: starts on press, stops on release, no emoji picker popping (Globe remapped to Do Nothing at onboarding). Right Command hold: same. Rapid double-tap fn: no ghost recordings.

## T9 Latency (record in PROGRESS.md)
15s utterance and 60s utterance, 3 runs each, release-to-text. Targets: ~3.5s and <10s.

PENDING CALIBRATION. Both reference points were chosen before any usage data existed. The extraction measures Andrew's real utterance length distribution and Wispr's own latency, which gives a true p50 and p90 to test at and a competitive baseline to beat. Update these targets once, from that data.

## T10 Stability
Reboot: app auto-starts, hotkey works without re-granting permissions. Wi-Fi OFF: everything still works (proves local). Full day of normal use: no crash, no leaked clipboard content, history shows entries and they are local files only.

## Post-v1: Ukrainian

Moved out of v1 on 2026-07-18 by Andrew, on measured evidence: of 1355 real dictations in Wispr Flow, 874 were English, 332 Russian and zero Ukrainian. Neither test below gates any v1 chunk, and T4 is explicitly no longer a binding condition on the C1 tripwire.

These are kept verbatim rather than deleted because Ukrainian is a wanted later capability and the force-language control still ships in v1, which is what makes adding it cheap. When Ukrainian returns, both tests return with it, and T4 returns as a binding condition: the single Bulgarian misdetection in the real data says Slavic language confusion is a genuine risk, not a hypothetical one.

### T3 Ukrainian clip (~30s), post-v1
Read into TextEdit:
"Отже, коротка думка щодо навчання. Хочу цього тижня пройти ще один модуль по агентних системах і зробити нотатки у вологому вигляді, тобто, ні, стривай, у робочому вигляді, начисто. І ще треба відповісти рекрутеру з Торонто."
PASS: output is Ukrainian (NOT Russian), the self-correction resolved to the corrected version.

### T4 UK-vs-RU discrimination pair, post-v1, NOT a binding condition
Two consecutive dictations, same app:
a) Pure UK: "Сьогодні гарна погода в Калгарі, і я планую піти на прогулянку після обіду."
b) Pure RU: "Сегодня хорошая погода в Калгари, и я планирую пойти на прогулку после обеда."
PASS: (a) comes out Ukrainian, (b) comes out Russian. No cross-contamination. Run 3 times each; 5/6 correct minimum.
