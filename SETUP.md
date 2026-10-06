# Ife Life: turning on online mode (about 15 minutes, free tier)

The game works without any of this. It then runs in LOCAL mode: your progress is saved in the browser, and ranks and chat use practice students.
Online mode gives you real accounts, real players in the leaderboard and chat, and money rules checked by a server.

## Steps
1. Create a free project at supabase.com.
2. Open **Authentication > Providers** and turn on **Anonymous sign-ins**. (Guests play first. Email comes later.)
3. Open **SQL Editor**, paste all of `supabase_schema.sql`, press Run.
4. Open **Project Settings > API**. Copy the **Project URL** and the **anon public key**.
5. Open `ife-life-oau.html` in a text editor. Near the top of the script, find:
   `var SUPABASE_URL = '', SUPABASE_ANON = '';`
   Paste your two values inside the quotes. Save.
6. Host the file (Netlify Drop, Cloudflare Pages or GitHub Pages all work). Open it, pick a username, roll your background.

## Check it works
- Open the site in two browsers with two usernames. Both should show in **Ranks**.
- After 10 minutes of account age, message the other username in **Chat**.

## What the server decides
- Your starting background (rolled on the server, so nobody can reroll).
- Your cash. The game sends what you earned and spent. The server caps each kind per call and per hour, and it refuses to go below zero.
- Net worth, aura limits, chat rules (280 characters, no links, bad-word filter, 10 messages a minute, 10-minute account age), blocks, reports.
- The weekly SUG election and the winning policy.

## What the server does NOT decide (read this)
- The game runs in the player's browser. A determined cheater can still send fake "job" earnings up to the caps (for example about 30,000 an hour from jobs).
  That is a bounded leak, not a closed door. Tighten the caps in `apply_ledger` when you see real players.
- Time, quests, CGPA and furniture placement are saved as the player's own data. Only cash, assets, aura, CGPA ranges and chat are checked.
- Chat moderation is a small word list plus report and block. Real players will need a real moderation routine. Read the `reports` table.

## Costs and limits to know
- Supabase free tier pauses a project after about a week with no traffic, and has a monthly user cap. Check the current numbers on their pricing page.
- Anonymous guests who never save an email lose their account if they clear browser data.

## New in this version: live players and hostel beds
- Re-run the whole `supabase_schema.sql` in the SQL Editor. It is safe to run again. It adds player level, live positions (`presence`), and bed claims (`room_claims`).
- Two players on the same campus path see each other, with name and level above the head. Players inside the same hostel room, party or library see each other too.
- Each hostel bed holds one real player. If two students roll the same bed, the second one is moved to the next free bed.
- Load: each player makes one small call every 1.4 seconds. Supabase free tier handles a few dozen players at once. Past 100 players online, expect to pay or to slow the poll rate.
- Not tested on a real Supabase project. The SQL passes my local database test. The browser side passes a mock server test. Your two-browser test is the first real one.

## Custom sounds (optional)
The game uses the phone's built-in speech voice for shouts like "Wereyyy!", "Sabo! Lagere!" and market calls. It will not sound like a real Nigerian recording.
For real sounds, record short mp3 files and put them in the same folder as the html file. Then add this line in the html, just before the closing </head>:

    <script>window.IFE_SOUNDS = { werey: ['werey1.mp3','werey2.mp3'], sabo: 'sabo.mp3', keke: 'keke.mp3', market: 'market.mp3', goal: 'goal.mp3', church: 'church.mp3', evangelist: 'evangelist.mp3', passerby: 'passerby.mp3' };</script>

Any key you leave out falls back to the built-in voice.
