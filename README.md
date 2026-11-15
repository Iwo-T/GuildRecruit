# GuildRecruit

A World of Warcraft: Forever addon that finds Danish speakers without a guild in chat and recruits them for your
guild. It listens on its own; everything it sends goes out on a key press, one step per press, because Blizzard
only lets channel posts, `/who` and guild invites happen on a key press or click.

## Install
- **Release zip:** download `GuildRecruit-<version>.zip` from Releases and extract it into
  `World of Warcraft\_forever_\Interface\AddOns\`, so the folder is `AddOns\GuildRecruit\` with `GuildRecruit.toc`
  directly inside it.
- **Or git:** `git clone https://github.com/Iwo-T/GuildRecruit.git` inside that `AddOns` folder (`git pull` updates).
- A new addon folder needs a logout to character select (or a restart) before the AddOns list shows it.

## Set up
1. Log in on a character in the guild. Inviting needs a guild rank that may invite; ads and whispers work without.
2. Bind Esc > Options > Key Bindings > AddOns > GuildRecruit > **Next recruiting step**, or make a macro with
   `/gr next` and put it on a bar.
3. Join the channel the ads go to: `LookingForGroup` by default. `/gr channels` shows its number and when the next
   ad is due.
4. `/gr show` opens the window: its button says what the next press will do, and lists the people found.

## What a press does: the first of
1. **Invite** the person who asked longest ago (2 s between invites).
2. **Whisper** the oldest checked Danish speaker without a guild who was never whispered: 30 s apart, at most 10 an
   hour, and never the same person twice.
3. **Post an ad** in an ad channel whose interval has passed (15 min per channel by default). The ad texts rotate.
4. **/who** the newest Danish speaker heard in the last hour, to see whether they have a guild (one at a time,
   5 s apart). The answer stays out of chat.
5. Otherwise it prints what it is waiting for.

A step that can't go out (no invite right, a channel not joined, the guild name not loaded yet just after login)
says so and the press does the next one instead.

## What it does by itself
- **Finds Danish speakers** in channels, say, yell, emote, whispers, party, raid and instance chat (not guild chat,
  not guild members, not GMs). It scores words only Danish uses against Norwegian and Swedish ones over a person's
  lines for half an hour; lines a Norwegian could have written the same way don't count.
- **Reads answers:** `/who` results (guild or not, level, class), and a guild name seen on a target or mouseover.
- **Reads replies to the whisper** (within a day): ja, gerne, jep, inv, ok, "hvorfor ikke" queue them for an invite;
  nej, "har en guild", "already in a guild" mark them as declined; måske, senere, "ikke nu" leave them for you
  (`/gr invite <name>`).
- **Queues invite requests:** a whisper saying ginv, or guild plus invite, or a bare "inv" within 15 min of an ad.
- **Reads the server's guild messages:** invited, already in a guild, declined, joined, not found (offline).

## Texts
The defaults are Danish and say only that the guild is a Danish social guild for dungeons, raids, PvP and hygge,
all levels and classes welcome, whisper for an invite. `{guild}` becomes `<Your Guild>`, `{name}` the player's
first name. Every text must fit one chat message (255 bytes; æ, ø and å take two), checked when you set it.
- `/gr ads` lists the ads; `/gr ad add <text>`, `/gr ad set <n> <text>`, `/gr ad del <n>`, `/gr ad reset`.
- `/gr whisper` shows the whisper; `/gr whisper <text>` replaces it; `/gr whisper reset`.

## Commands (`/gr` or `/recruit`)
| Command | Does |
| --- | --- |
| `/gr` | status, counts and this list |
| `/gr next` | the next step (same as the key) |
| `/gr show` / `hide` / `toggle` | the window (remembered across sessions) |
| `/gr list` | the people found, with what they said |
| `/gr invite <name>` | invites them now |
| `/gr skip <name>` | drops them for good: no /who, whisper or invite |
| `/gr channels` | ad channels, their numbers and when the next ad is due |
| `/gr channel add\|del <name>` | LookingForGroup, Services, Trade, General or a channel you `/join`ed |
| `/gr interval <minutes>` | minutes between ads per channel (5-120) |
| `/gr watch on\|off` | chat watching (invite requests by whisper still count) |

## Saved data
`GuildRecruitDB` (account-wide): the people found and what happened with each, your texts, channels and counts.
Whom it has whispered, invited or been told no by is kept, so nobody is contacted twice.

## Status
Version 1.0.0, tested against a stand-in of the game's API; not yet run in the live client. If something misbehaves,
`/gr` shows the state and the window says what the next press will do.
