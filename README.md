## <p align="center">Introducing SmartLoot!  Your new, clean EverQuest Emulator Looting Partner!</p>

<img width="919" height="678" alt="image" src="https://github.com/user-attachments/assets/a7cc943a-153c-4598-9517-3a45f3ab5c99" />

Intended to be a smarter, easier, and efficient way of managing loot rules, SmartLoot was born out desparation - no more trying to remember who has how many of an item, or who's finished which quest.
No more tabbing out of the game window to go change an .ini file to stop looting a certain item.

Within SmartLoot's interface, you can now add, change, remove, or update the rules for every character connected.  It doesn't ship with a default database, since most emulators run their own custom content.

As you encounter new items, looting will pause and prompt you to make a decision.  

<img width="519" height="424" alt="image" src="https://github.com/user-attachments/assets/c3ad7a3c-1c80-4157-827a-2fdbba5875ae" /> 

From there, you can set it for everyone, just yourself, or open the peer rules editor and set it per user! 

<img width="475" height="768" alt="image" src="https://github.com/user-attachments/assets/69c61cd4-fe95-4c3a-ab8f-ea54f4f79b07" />

## But How Does It Work?!

Simple! Your Main Looter is responsible for processing all those pesky corpses laying around.  That character will, when not in combat, begin cycling through nearby corpses and looting according to their rule set. When they've finished looted/processing the corpses, they'll go back through the list of items they ignored, and check to see if any of their buddies need or want that item based on their rules.  If anyone has a rule of "Keep" or "KeepIfFewerThan", the main looter will send a command telling them to go loot!  Then the process repeats on the triggered character, and down the line it goes until either all characters have processed the corpse, or there's no items left/no interested peers left.

## Ok, but How Do I Get Started?!

Once you've got the script loaded, you can /sl_getstarted for an in game help, OR...

1) Go to the Peer Loot Order Tab and set your loot order! This is super important, since the whole system is based off of "Who Loots First? What Loots Second?"  The good news is, the order is saved globally so you don't need to set it on each character!  It's stored in a local sqlite database, and you can change it "on the fly"!

   <img width="1014" height="168" alt="image" src="https://github.com/user-attachments/assets/183c129b-a675-40d2-838b-caa8fca3dc8e" />

2) Once you've saved your Loot Order, embrace your inner Froglok, and hop on over to the Settings Tab.  Here we'll need to tweak a couple things for your custom set up! Important Settings:
      a) Chat Output Settings - The System will announce various actions/activities.  Choose your output channel, or Silent if you don't want to hear it!
      b) Chase Commands - SmartLoot uses /nav to move around the world.  If you have any kind of auto chase set, you might want to set the commands here to pause/resume.  Otherwise if a corpse is further away than your leash, your toon will never get there!

   <img width="988" height="574" alt="image" src="https://github.com/user-attachments/assets/92c93dda-041b-47b6-babc-7a0d470ee569" />

3) Give yourself a /sl_save to ensure that the config got saved, then restart the script!  (Best to broadcast to all your peers to stop the script - /dgae, /e3bcaa, /bcaa, etc.).  Then, load 'er up on the main character!

   /lua run smartloot

4) It's Smart so it'll auto detect who's in what mode based on their order in the Loot Order.  Once she's running, go kill!

## Helpful tips!

I tend to have the Peer Commands window open all the time.  

<img width="264" height="214" alt="Screenshot 2025-07-14 044646" src="https://github.com/user-attachments/assets/c58fce58-b518-46d1-ab84-b9b27b5e4000" />

This window lets you choose a targetted peer, and then send them individual commands.  


***DISCLAIMER***

This is still a work in progress.  I've done what I can to test, but MY use case may (hah, IS) different than YOUR use case.  I look forward to ironing out the kinks!

### Helpers and FAQ's

1) /sl_help will toggle a help window!

2) Why am I not looting?!
     * Who knows?! Haha, not really.  Check first: Are you in main looter mode?  /sl_mode to check!  If you are, and still aren't looting, are you in combat?  You can check with: /echo ${SmartLoot.State}.  Finally, did you already process this corpse?  Try a /sl_clearcache and see if we start looting!  Finally, if all else fails: /sl_doloot to kick yourself into a looting cycle.
