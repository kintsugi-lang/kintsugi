# Tic-Tac-Toe

A tic-tac-toe example in two flavors: terminal and graphical (LÖVE2D).

## Files

```
tic-tac-toe/
├── board.ktg              # Board state, win detection (shared)
├── ai.ktg                 # AI strategy (shared)
├── game.ktg               # Game flow, turns, status (shared)
├── terminal/
│   └── main.ktg           # Text-mode demo (interpreter)
└── graphical/
    ├── main.ktg            # LÖVE2D source (Kintsugi/Lua)
    ├── main.lua            # Compiled Lua output
    └── conf.lua            # LÖVE2D window config
```

## Terminal

```bash
kintsugi examples/tic-tac-toe/terminal/main.ktg
```

Plays a demo game in the terminal with X vs AI.

## Graphical (LÖVE2D)

```bash
# Compile
kintsugi -c examples/tic-tac-toe/graphical/main.ktg -o examples/tic-tac-toe/graphical/main.lua

# Run
love examples/tic-tac-toe/graphical
```

Click cells to play X. AI responds as O. Click anywhere after game over to restart.
