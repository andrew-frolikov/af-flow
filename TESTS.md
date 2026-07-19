# AF Flow: voice test protocol

Andrew reads the scripts aloud via AF Flow into the target app. Read naturally, at normal speed, and do NOT suppress your real ums, pauses, and restarts: the cleanup layer must handle them. Claude Code records pass/fail and latency in PROGRESS.md.

## T1 English brain-dump (60s, core loop)
Read into Claude desktop:
"Okay so, um, quick thoughts on the job search this week. I want to, uh, follow up with the recruiter from Tuesday, the one about the account executive role, and I should probably, no wait, I definitely need to update the pipeline spreadsheet first. Then LinkedIn: draft a post about the AF Flow build, something about how a non-coder ships a real Mac app by directing AI agents. Keep it concrete, numbers, no hype. Also groceries after four, and, um, check whether the EI report is due this Friday or next."
PASS: fillers and false starts gone, punctuation clean, no em dashes, meaning intact, lands at cursor.

## T2 Russian brain-dump (~40s)
Read into Obsidian:
"Так, значит, по поводу квартиры. Надо, эээ, позвонить насчёт интернета, потому что Shaw опять поднял цену, и посмотреть, есть ли альтернативы дешевле. Потом, ну, записать идею для канала: короткое видео про то, как я строю своё приложение для диктовки. И ещё не забыть про день рождения мамы, подарок надо заказать заранее."
PASS: clean Russian, fillers (эээ, ну, значит) removed, Shaw stays Latin, output entirely Russian.

## T3 Ukrainian clip (~30s)
Read into TextEdit:
"Отже, коротка думка щодо навчання. Хочу цього тижня пройти ще один модуль по агентних системах і зробити нотатки у вологому вигляді, тобто, ні, стривай, у робочому вигляді, начисто. І ще треба відповісти рекрутеру з Торонто."
PASS: output is Ukrainian (NOT Russian), the self-correction resolved to the corrected version.

## T4 UK-vs-RU discrimination pair (binding condition d)
Two consecutive dictations, same app:
a) Pure UK: "Сьогодні гарна погода в Калгарі, і я планую піти на прогулянку після обіду."
b) Pure RU: "Сегодня хорошая погода в Калгари, и я планирую пойти на прогулку после обеда."
PASS: (a) comes out Ukrainian, (b) comes out Russian. No cross-contamination. Run 3 times each; 5/6 correct minimum.

## T5 Mixed RU/EN (his real register)
Read into Claude desktop:
"Значит, идея такая: я хочу сделать pivot в контенте и больше говорить про vibe coding и агентов, потому что это, ну, use case, который сейчас всем интересен. Ранние, эээ, early adopters уже это делают, и я хочу double down на этой теме."
PASS: clean single-language Russian with the allowlisted English terms kept in English (pivot, vibe coding, use case, early adopters, double down); no chaotic word salad.

## T6 Dictionary terms
Dictate each name in a sentence; all must come out spelled exactly: Frolikov, Andrii, Softchoice, WWT, ENA Solution, Kharkiv, Calgary, Cowork, Wispr Flow, AF Flow, WhisperKit, Qwen, Obsidian.
Seed these into the replacement layer + cleanup glossary in C3.

## T7 Insertion matrix (each app: T1 or T5 script, shortened)

| Target | Insert works | Clipboard restored | Notes |
|---|---|---|---|
| Claude desktop (Electron) | | | primary target |
| Gmail compose in Chrome | | | |
| Obsidian | | | |
| Telegram or WhatsApp desktop | | | |
| TextEdit (control) | | | |
| macOS password field | | | MUST refuse cleanly with the Secure Input message, not crash |

## T8 Hotkey
fn/globe hold: starts on press, stops on release, no emoji picker popping (Globe remapped to Do Nothing at onboarding). Right Command hold: same. Rapid double-tap fn: no ghost recordings.

## T9 Latency (record in PROGRESS.md)
15s utterance and 60s utterance, 3 runs each, release-to-text. Targets: ~3.5s and <10s.

## T10 Stability
Reboot: app auto-starts, hotkey works without re-granting permissions. Wi-Fi OFF: everything still works (proves local). Full day of normal use: no crash, no leaked clipboard content, history shows entries and they are local files only.
