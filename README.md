## <p align="center">Introducing SmartLoot!  Your new, clean EverQuest Emulator Looting Partner!</p>

<img width="919" height="678" alt="image" src="https://github.com/user-attachments/assets/a7cc943a-153c-4598-9517-3a45f3ab5c99" />

Intended to be a smarter, easier, and efficient way of managing loot rules, SmartLoot was born out desparation - no more trying to remember who has how many of an item, or who's finished which quest.
No more tabbing out of the game window to go change an .ini file to stop looting a certain item.

Within SmartLoot's interface, you can now add, change, remove, or update the rules for every character connected.  It doesn't ship with a default database, since most emulators run their own custom content.

As you encounter new items, looting will pause and prompt you to make a decision.  

<img width="519" height="424" alt="image" src="https://github.com/user-attachments/assets/c3ad7a3c-1c80-4157-827a-2fdbba5875ae" /> 

From there, you can set it for everyone, just yourself, or open the peer rules editor and set it per user! 

<img width="475" height="768" alt="image" src="https://github.com/user-attachments/assets/69c61cd4-fe95-4c3a-ab8f-ea54f4f79b07" />

<p align="center">## But How Does It Work?!</p>

Simple! Your Main Looter is responsible for processing all those pesky corpses laying around.  That character will, when not in combat, begin cycling through nearby corpses and looting according to their rule set. When they've finished looted/processing the corpses, they'll go back through the list of items they ignored, and check to see if any of their buddies need or want that item based on their rules.  If anyone has a rule of "Keep" or "KeepIfFewerThan", the main looter will send a command telling them to go loot!  Then the process repeats on the triggered character, and down the line it goes until either all characters have processed the corpse, or there's no items left/no interested peers left.

<p align="center">## Ok, but How Do I Get Started?!</p>

Once you've got the script loaded, you can /sl_getstarted for an in game help, OR...

1) Go to the Peer Loot Order Tab and set your loot order! This is super important, since the whole system is based off of "Who Loots First? What Loots Second?"  The good news is, the order is saved globally so you don't need to set it on each character!  It's stored in a local sqlite database, and you can change it "on the fly"!

   <img width="1014" height="168" alt="image" src="https://github.com/user-attachments/assets/183c129b-a675-40d2-838b-caa8fca3dc8e" />

2) Once you've saved your Loot Order, embrace your inner Froglok, and hop on over to the Settings Tab.  Here we'll need to tweak a couple things for your custom set up! Important Settings:
      a) Chat Output Settings - The System will announce various actions/activities.  Choose your output channel, or Silent if you don't want to hear it!
      b) Navigation Commands - Choose the movement command SmartLoot should use to reach corpses (/nav, /moveto, /warp, etc.).  You can also define a fallback if MQ2Nav isn't available and a stop command to send when looting finishes.
      c) Chase Commands - If you have any kind of auto chase set, set the pause/resume commands here.  Otherwise if a corpse is further away than your leash, your toon will never get there!

   <img width="988" height="574" alt="image" src="https://github.com/user-attachments/assets/92c93dda-041b-47b6-babc-7a0d470ee569" />

3) Give yourself a /sl_save to ensure that the config got saved, then restart the script!  (Best to broadcast to all your peers to stop the script - /dgae, /e3bcaa, /bcaa, etc.).  Then, load 'er up on the main character!

   /lua run smartloot

4) It's Smart so it'll auto detect who's in what mode based on their order in the Loot Order.  Once she's running, go kill!

## <p align="center">Helpful tips!</p>

I tend to have the Peer Commands window open all the time.  

<img width="264" height="214" alt="Screenshot 2025-07-14 044646" src="https://github.com/user-attachments/assets/c58fce58-b518-46d1-ab84-b9b27b5e4000" />

This window lets you choose a targetted peer, and then send them individual commands.  


***DISCLAIMER***

This is still a work in progress.  I've done what I can to test, but MY use case may (hah, IS) different than YOUR use case.  I look forward to ironing out the kinks!

### Helpers and FAQ's

1) /sl_help will toggle a help window that shows you all the / commands for SmartLoot.  I find these commands the most commonly used:
     * /sl_doloot - this triggers a "once" round of looting.  If for some reason you character was out of the zone or missed the automatic trigger, you can issue a /sl_doloot command to them (this is also hard coded into the Peer Commands window).
     * /sl_peer_commands - I leave this window open all the time and dock it somewhere out of the way but accessible.  The command toggles the visibility of the Peer Commands Window.
     * /sl_clearcache - This will clear the corpse cache.  If for some reason you have a corpse at your feet and you're not looting, check if you're in Main Mode, or Once mode, then clear your corpse cache.
     * /sl_mode - This will output your current mode - helpful when checking the above!
           * /sl_mode main/background - you can change modes with a command, or you can right click the floating button.
     * /sl_pause - Need to stop looting for some reason? /sl_pause will pause corpse processing until you toggle it back on.  This is also hard coded into the Peer Commands window (it pauses looting on yourself, not the targetted peer).
     * /sl_stats - Toggle the Live Stats window.
     * /sl_chat <mode> - available options are raid, group, guild, custom (if you wanted a channel, for example) or silent.

3) Why am I not looting?!
     * Who knows?! Haha, not really.  Check first: Are you in main looter mode?  /sl_mode to check!  If you are, and still aren't looting, are you in combat?  You can check with: /echo ${SmartLoot.State}.  Finally, did you already process this corpse?  Try a /sl_clearcache and see if we start looting!  Finally, if all else fails: /sl_doloot to kick yourself into a looting cycle.
  
4) The script needs to be running on all your characters simultaneously.  To achieve this, we'll autobroadcast a start up message from our "Main" toon when it starts on that character.  If you have the script set to run in a .cfg file or at start up on your character, the background guys might miss the command.  Be sure it's running on everyone before you start hunting!

5) Item Stats - I'm not a mathematician, but I tried my best to keep the drop stats as accurate as possible.  If you notice any oddities, please let me know.  There's a ton of weird SQL syntax that Claude and ChatGPT helped me with!  :)

6) The script does expose some TLO's if you wanted to integrate this into your own macro/bot system.
      * SmartLoot.State - this will return what State you're in.  (Idle, Finding Corpse, Pending Decision, Combat Detected)
      * SmartLoot.Mode - this will return what Mode you're in. (Main, Background, Once, RGMain, RGOnce)
      * SmartLoot.CorpseCount - this will return how many corpses are in the configured loot radius
      * SmartLoot.SafeToLoot - a simple true/false to identify if we're in a mode and conditions are met for looting (e.g., out of combat, not casting, not moving)
      * SmartLoot.NeedsDecision - are we in a pending decision mode?  This can be helpful if you're not paying attention to the chat spam.  This'll return True for background peers if they're pending a decision. (Add a monitor to your HUD for your backgroung guys!)

## <p align="center">AFK Temp Rules Mode</p>

What's this AFK Rules tab?!  Good question!  The system is designed around saving loot rules based on itemID's (You can thank Luclin Shards for that fun fact!).  As such, since we don't have a precompiled database, in order to save a loot rule we need the item ID.  AFK Farm Rules solves this temporarily.  If you're going to let this run overnight (provided it's permitted on your server!), you can set temporary rules based on item names alone, and assign it to a peer.  Camping Lord Begurgle?  Add the Crown by name, set the rule, and assign it to your cleric (or whoever needs it, I guess).  When it's encountered over night, it'll apply the rule, and save the item to the database with all the pertinent information!


  

## Whitelist-Only Loot (per character)

- Enable a character to only loot items you’ve explicitly set to Keep, and silently ignore everything else (no prompts).
- Toggle it on the character you want:
  - `/sl_whitelistonly on` to enable
  - `/sl_whitelistonly off` to disable
- Or enable it from Settings → Character Settings → “Whitelist-Only Loot (this character)”.
- Manage whitelist items:
  - Open UI: Settings → Character Settings → Manage Whitelist…
  - Or command: `/sl_whitelist` to open, `/sl_whitelist off` to close.
- Optional: “Do not trigger peers”
  - In Settings → Character Settings, enable “Do not trigger peers while whitelist-only” if you don’t want this toon to start waterfall triggers for others while running in whitelist-only mode.
- How to “whitelist” items: add normal rules for those items (e.g., set Diamonds/Blue Diamonds to Keep for that toon via the UI or commands). With whitelist-only enabled, only those Kept items will be looted; all other items are auto-ignored without asking.
