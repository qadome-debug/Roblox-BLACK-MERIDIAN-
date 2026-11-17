# Unwanted Company — behaviour-based proposal

Status: 2026-11-16. A PROPOSAL for approval. Nothing here is implemented;
Unwanted Company has no effect in the game until a version is approved.
All numbers are provisional placeholders for discussion.

## Established design (from the report)

Unwanted Company is Nearness's default Burden. At higher Dissonance,
hostile adjacency becomes more dangerous, increasing the threat of certain
nearby attacks.

## What you asked for

Not a flat increase in incoming damage. Instead: changed nearby enemy
behaviour, targeting or proximity pressure, with clear feedback and fair
counterplay.

## Proposal: enemies are drawn to the player's company

**Idea.** Nearness pulls distances together, and the Burden makes the
world answer in kind. As Dissonance rises, enemies close to the player
stop ignoring them and press in.

| Dissonance band | Effect on enemies within 12 studs of the player |
| --------------- | ------------------------------------------------ |
| Stable (0-39) | None. Calm play is untouched |
| Noticeable instability (40-64) | **Attention.** Nearby enemies prefer the player as a target over other players, and pick the player first when they choose whom to attack |
| Enemy and environmental reactions (65-84) | **Closing in.** Nearby melee enemies shorten the pause between their attacks by about 20% and step in to attack range faster. Their attacks are not stronger |
| Fractured event risk (85-99) | **Crowding.** A nearby enemy that has not attacked recently makes one extra approach per 8 seconds, so a player standing among enemies is pressed from more directions |
| Controlled rupture (100) | Handled by the region or encounter, as for all of Dissonance |

Damage per hit never changes. The threat comes from tempo, attention and
positioning, which a player can read and answer.

**Counterplay.**

- Stay out of the 12-stud ring, or fight at range, and nothing happens.
- Shed Dissonance with stable ground, anchors, camps or consumables, and
  the effect falls away at once.
- Between Us and No Farther are the natural answers: tether or slow the
  enemies pressing in.
- Close Step out of the ring resets the pressure after 2 seconds.

**Feedback.** A faint ring on the ground at 12 studs that appears from the
40 band and tightens in colour at each higher band. Enemies inside it get a
small marker over their head ("watching", then "closing in"). A low,
close sound layer rises with the band. Every cue also has a non-colour,
non-sound form (ring pattern and marker shape) for accessibility.

## What this needs that does not exist yet

- Enemy target selection and attack tempo hooks in `Combat/Ai.luau`
  (today every enemy attacks on a fixed cooldown with jitter).
- Visuals: ground ring, enemy markers, audio. None exist; they would be
  placeholders first.
- The Dissonance band as an input to the AI, through `Combat/BurdenEffects`.

## Questions for approval

1. Is "attention, tempo and crowding" the right feel, or should it be
   something else (for example nearby enemies telegraph attacks more
   clearly but hit from more angles)?
2. Is 12 studs the right "adjacency"? The decision sheet used 6 (melee
   reach); 12 gives the player time to react.
3. Do the 20% tempo and the 8-second extra approach feel fair as starting
   values?
4. Should bosses be affected? The proposal says no, so boss patterns stay
   authored.
