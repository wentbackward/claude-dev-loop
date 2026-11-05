---
id: close-position-clears-alert
title: Closing a position clears its price alert
spec: [positions, alerts]   # the spec sections this scenario covers
tags: [smoke, alerts]
required: true              # true: must pass; false: scored
---
<!-- One file per scenario, in the scenario store (scenarios.dir, default ~/.dev-loop/<repo>/scenarios),
outside every worktree. Write it from the spec, never from the code, in the user's terms. Front matter:
key: value lines, lists as [a, b]; id and title are required, id is unique in the store, required is
true or false, and the body below must not be empty. -->

## User and goal

A trader who holds one position with a price alert closes the position and expects no more alerts for it.

## Preconditions and fixtures

- One open position of 10 units, with a price alert at 105.
- The market data source is a fake that can move the price on request.

## Steps

1. Open the positions view and close the position.
2. Move the fake price to 106.

## Satisfied when

- The position no longer appears among the open positions.
- No alert fires for it at 106, and the alerts list shows none for that position.
