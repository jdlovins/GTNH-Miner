# Asteroid data: game vs calculator vs config.lua

Dump version: 1.4. Asteroids in game: 43, in calculator: 41, in config.lua: 43.

## The calculator's model is incomplete

- Per drone tier the game also divides duration by sqrt(k) and, for most asteroids, multiplies EU/t by sqrt(k) (k = drone - minDrone + 1). The calculator scales size only, so its Time and Voltage are wrong for every drone above an asteroid's minimum. Where the game departs from that formula it is listed under "Per-drone recipes the formula does not predict".
- Its Chance column is weight / sum of ALL asteroids' weights. The game only competes asteroids eligible at the chosen distance, drone and module tier.
- Output chances are a weighted pick of ONE output per draw, not independent rolls. config.lua's asteroidOutputs header says otherwise ("~2.9 items per run") and is wrong.

## Game and calculator disagree (1)

| asteroid | field | game | calculator |
|---|---|---|---|
| PlatLine Dust | minModule | 2 | 3 |

## Drop weights disagree (2)

| asteroid | game | calculator |
|---|---|---|
| Gem Ores | [100, 400, 500, 500, 750, 750, 750, 1000, 1500, 1500, 1500, 1500] | [100, 400, 500, 500, 750, 750, 1000, 1500, 1500, 1500, 1500] |
| Phosphate | [2500, 3000, 3000, 4500] | [2500, 3000, 4500] |

## In the game, not the calculator (2)

| asteroid |
|---|
| Space Ores |
| Nether Ores |

## In the calculator, not the game (0)

None.

## No value from either source (0)

None.

## Per-drone recipes the formula does not predict (the game's value is used) (17)

| asteroid | drone | field | formula | game |
|---|---|---|---|---|
| Everglades | uv | eut | 10862 | 7680 |
| Everglades | uhv | eut | 13303 | 7680 |
| Clay | mv | eut | 10862 | 7680 |
| Clay | hv | eut | 13303 | 7680 |
| Clay | ev | eut | 15360 | 7680 |
| Clay | iv | eut | 17174 | 7680 |
| Clay | luv | eut | 18813 | 7680 |
| Mysterious Crystal | luv | eut | 173779 | 122880 |
| Mysterious Crystal | zpm | eut | 212835 | 122880 |
| Mysterious Crystal | uv | eut | 245760 | 122880 |
| Mysterious Crystal | uhv | eut | 274769 | 122880 |
| Mysterious Crystal | uev | eut | 300994 | 122880 |
| Mysterious Crystal | uiv | eut | 325110 | 122880 |
| Mysterious Crystal | umv | eut | 347558 | 122880 |
| Mysterious Crystal | uxv | eut | 368640 | 122880 |
| Draconic Core | uev | eut | 11121829 | 7864320 |
| Draconic Core | uiv | eut | 13621402 | 7864320 |

## Best distance differs from config.optimizationMatrix (0)

None.

## Best distance differs from the calculator's own best sheets (6)

| module | asteroid | drone | calculator | merged |
|---|---|---|---|---|
| MK-I | Aluminium-LanthLine | zpm | 41 | 101 |
| MK-I | Naquadah | uv | 50 | 121 |
| MK-II | Aluminium-LanthLine | luv | 41 | 101 |
| MK-II | Aluminium-LanthLine | zpm | 41 | 101 |
| MK-III | Aluminium-LanthLine | luv | 41 | 101 |
| MK-III | Aluminium-LanthLine | zpm | 41 | 101 |

