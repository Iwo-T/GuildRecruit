# GuildRecruit

A World of Warcraft: Forever addon that recruits for your guild: it posts your ads in General and LookingForGroup,
finds Danish speakers without a guild in chat, whispers them, and invites whoever says yes. Whispers go out on their
own. Ads, `/who` checks and invites need a key press, because Blizzard only allows those on a key press or click; one
press does all of them that are due.

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
3. Be in the channels the ads go to: General (`/1`, always there outside instances) and LookingForGroup
   (`/join LookingForGroup` if you haven't). `/gr channels` shows their numbers and when the next ads are due.
4. `/gr show` opens the window: its button says what the next press will do, and it lists the people found.

**Recruiting while you play:** add `/gr next quiet` as the last line of a macro you press all the time anyway (your
mount, a filler spell). Every press of it then posts the ads that are due, checks a candidate and invites anyone
waiting, and says nothing when there's nothing to do.

## What a press does: everything that's due
1. **Invites** the person who asked longest ago.
2. **Posts an ad** in every ad channel whose interval has passed (5 minutes per channel by default), a different text
   in each; every channel goes through all your texts in turn. `/gr interval` changes it; ads every minute or two can
   get you reported for spam.
3. **Checks** the newest Danish speaker heard in the last hour with a `/who` (one at a time, 5 s apart), to see
   whether they have a guild. The answer stays out of chat.

With nothing due, the press says what it's waiting for (`/gr next quiet` doesn't). Anything it can't do (no invite
right, a channel you're not in) gets a short note at most every 5 minutes, and the rest still goes.

## What it does by itself
- **Finds Danish speakers** in channels, say, yell, emote, whispers, party, raid and instance chat (not guild chat,
  not guild members, not GMs). It scores words only Danish uses against Norwegian, Swedish and German ones over a
  person's lines for half an hour; lines a Norwegian or German could have written the same way don't count. Most
  Danes write English in public channels, so expect few of these: your ads find most recruits.
- **Whispers** each Danish speaker the `/who` found without a guild: 30 s apart, at most 10 an hour, never the same
  person twice. Someone who whispered you first, in any language, is left to you (the window says "whispered you"). A
  "no guild" older than 3 hours is checked again before anyone is whispered.
- **Holds still in boss fights:** while the game locks chat for addons (encounters), no ad or whisper goes out,
  since the answers couldn't be read; whispers follow on their own afterwards, ads on your next press.
- **Reads the replies** (within a day): ja, gerne, jep, inv, ok, "hvorfor ikke" queue them for an invite; nej,
  "har en guild", "already in a guild" mark them as declined; måske, senere, "ikke nu" leave them for you
  (`/gr invite <name>`).
- **Queues invite requests:** a whisper saying ginv, or guild plus invite, or a bare "inv" within 15 min of an ad.
- **Rings when someone wants in:** a raid-warning sound and a message mid-screen, so you know to press the key.
- **Reads guilds it can see:** a guild name on a target, mouseover or nameplate settles it without a `/who`.
- **Reads the server's guild messages:** invited, already in a guild, declined, joined, not found (offline).

## Texts
The defaults are Danish and say only that the guild is a Danish social guild for dungeons, raids, PvP and hygge,
all levels and classes welcome, whisper for an invite. `{guild}` becomes `<Your Guild>`, `{name}` the player's
first name. Every text must fit one chat message (255 bytes; æ, ø and å take two), checked when you set it.
- `/gr ads` lists the ads; `/gr ad add <text>`, `/gr ad set <n> <text>`, `/gr ad del <n>`, `/gr ad reset`.
- `/gr whispertext` shows the whisper; `/gr whispertext <text>` replaces it; `/gr whispertext reset`.

## Commands (`/gr` or `/recruit`)
| Command | Does |
| --- | --- |
| `/gr` | status, counts and this list |
| `/gr next` | the next press (same as the key); `/gr next quiet` for macros |
| `/gr show` / `hide` / `toggle` | the window (remembered across sessions) |
| `/gr list` | the people found, with what they said |
| `/gr whisper <name>` | whispers them the pitch now (not guild members) |
| `/gr invite <name>` | invites them now |
| `/gr skip <name>` | drops them for good: no /who, whisper or invite |
| `/gr auto on\|off` | whispers on their own (on) or on a press (off) |
| `/gr channels` | ad channels, their numbers and when the next ad is due |
| `/gr channel add\|del <name>` | General, LookingForGroup, Services, Trade or a channel you `/join`ed |
| `/gr interval <minutes>` | minutes between ads per channel (1-120) |
| `/gr watch on\|off` | chat watching (invite requests by whisper still count) |

## Saved data
`GuildRecruitDB` (account-wide): the people found and what happened with each, your texts, channels and counts.
Whom it has whispered, invited or been told no by is kept, so nobody is contacted twice. A save from version 1.0.0
that still has its default ad settings (LookingForGroup alone, every 15 minutes) moves to General and
LookingForGroup every 5 minutes; settings you changed stay.

## Status
Version 1.1.0. Ads, `/who` checks and the invite right work in the live client; several ads and a `/who` on one
press, automatic whispers and the alert are tested against a stand-in of the game's API and not yet seen live. If
something misbehaves, `/gr` shows the state and the window says what the next press will do.
