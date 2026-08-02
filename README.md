# Classroom Question Board — Setup Guide

Three plain HTML files + a free Supabase database. No server to run, no
coding needed after setup — you'll copy-paste two values into each file
and run one SQL script once.

**Files:**
- `submission.html` — students submit questions
- `voting.html` — students vote (grade comes from a hidden link/QR code)
- `admin.html` — you manage rounds and see results
- `schema.sql` — the database setup script (run once)

---

## Step 1: Create a free Supabase project

1. Go to https://supabase.com and sign up (free tier is plenty for this).
2. Click **New project**. Pick any name and a database password (save the
   password somewhere — you likely won't need it again, but keep it safe).
3. Wait about a minute for the project to finish setting up.

## Step 2: Run the database script

1. In your Supabase project, open the **SQL Editor** (left sidebar).
2. Click **New query**.
3. Open `schema.sql` from this folder, copy **all** of it, and paste it in.
4. Click **Run**. You should see "Success. No rows returned."

This creates the two data tables (`questions` and `votes`), a couple of
small supporting tables, and all the logic the three pages need.

## Step 3: Get your connection details

1. In Supabase, go to **Project Settings** (gear icon) → **API**.
2. Copy the **Project URL** (looks like `https://abcdefgh.supabase.co`).
3. Copy the **anon public** key (a long string starting with `eyJ...`).

## Step 4: Paste your details into each HTML file

Open each of `submission.html`, `voting.html`, and `admin.html` in a text
editor. Near the top of each, inside a `<script>` tag, you'll see:

```js
const SUPABASE_URL = "https://YOUR-PROJECT-REF.supabase.co";
const SUPABASE_ANON_KEY = "YOUR-ANON-PUBLIC-KEY";
```

Replace both values with what you copied in Step 3, in all **three**
files, then save.

## Step 5: Change the admin passphrase

The default admin passphrase is `changeme123`. Change it before handing
this out: in the Supabase **SQL Editor**, run (with your own values):

```sql
select fn_change_admin_passphrase('changeme123', 'your-new-passphrase');
```

Use this same function any time you want to change it again later.

## Step 6: Host the three HTML files

Because these are plain files with no server behind them, they need to be
somewhere a browser can open them over the web (not just a Google Drive
download link — Drive doesn't display HTML, it downloads it).

The simplest free options:
- **Google Sites**: create a site, add an "Embed" block on three separate
  pages, and embed each HTML file's code (or upload the file and link to
  it as an attachment — Sites will serve it directly).
- **GitHub Pages**, **Netlify Drop**, or **Cloudflare Pages**: drag-and-drop
  the three files in and get a public link instantly, no account
  configuration needed beyond signup. This tends to be the most reliable
  option if you can spare five extra minutes.

Once hosted, you'll have three URLs, e.g.:
```
https://your-site.example/submission.html
https://your-site.example/voting.html
https://your-site.example/admin.html
```

## Step 7: Make the grade-specific voting links / QR codes

The voting page reads the grade from the URL and never shows a grade
picker to students. Create one link per grade:

```
https://your-site.example/voting.html?grade=3
https://your-site.example/voting.html?grade=4
https://your-site.example/voting.html?grade=5
https://your-site.example/voting.html?grade=6
```

Turn each into a QR code with any free QR generator (e.g.
https://www.qr-code-generator.com or the QR option built into Google
Chrome's address bar — click the share icon). Print one per grade.

The submission page and admin page don't need any URL parameters — just
share those links as-is.

There's also a fifth, optional link for the **final vote** (see below),
which only matters once every grade has finished:
```
https://your-site.example/voting.html?grade=FINAL
```
Don't hand this one out until you've actually started the final vote on
the admin page — before that, it just shows a "hasn't started yet" message.

---

## How it works day-to-day

1. **Students submit questions** any time via the submission page.
2. **You open the admin page**, enter your passphrase, pick a grade, set
   how many votes each student gets, and click **Start Round**.
3. **Students scan their grade's QR code**, enter their Student ID, pick
   up to that many questions, and submit.
4. **You click End Round.** Any question that got zero votes that round
   is permanently removed from future rounds for that grade. The admin
   table updates immediately, and a "Round Two" line appears so you can
   set the next round's votes-per-student and start it.
5. Repeat for as many rounds as you like (up to 30).
6. **When you're done, click End Voting.** This locks the grade and shows
   you the top 5 questions.

The **Overall** option in the grade dropdown lets you start/end a round
for all four grades at the same time instead of one at a time.

### Final vote (optional)

Once **all four grades** have had End Voting clicked, a "Start final vote"
button appears in the **Final vote** card at the bottom of the admin page
(it stays hidden/disabled until then). Clicking it pulls the single
highest-voted question from each grade and opens a head-to-head vote.
Hand out the `?grade=FINAL` link/QR code at that point, watch the tally
update live on the admin page, then click **End final vote** to lock it in
and reveal the winner.

This is a one-time-per-year feature by design — once ended, it can't be
restarted from the page. If you ever need to run it again (e.g. a new
school year with the same database), a teacher comfortable with SQL can
reset it in the Supabase SQL Editor:
```sql
delete from final_votes;
delete from final_candidates;
update final_round set status = 'not_started', started_at = null, ended_at = null where id = 1;
```

## A note on privacy and security

- The admin passphrase is a light lock appropriate for a classroom tool —
  good enough to keep students out, not meant to withstand a serious
  attacker. Don't reuse a sensitive password for it.
- The voting page never shows students who submitted which question, or
  any IP addresses — only you can see that on the admin page.
- IP addresses are looked up via a free public service (ipify.org) since
  these pages have no server of their own to read them from directly.
