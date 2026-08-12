# DiskDrama — "of that" has no clear antecedent

## DD.B012 — reclaimable line's referent is ambiguous, and the near reading is wrong

`Sidebar.reclaimableLine`:
```
Text("\(ByteFormat.compact(model.totalReclaimableBytes)) of that is reclaimable.")
```
sits directly under "41.3 GB free of 494.4 GB" and a capacity bar. "That" has
no explicit noun, so the reader grabs the nearest one — "free" — and that
reading is actively wrong: reclaimable space (86.3 GB) is *larger* than free
space (41.3 GB) here, because it's space currently in use that could be
freed, not a subset of what's already free. The sentence only makes sense
once you separately work out "that" must mean the disk as a whole, several
words back and past a more prominent candidate.

Fix by naming the thing instead of pointing at it. `DiskInfo.usedBytes`
already exists (`totalBytes - availableBytes`) — use it:

"Of the 453.1 GB in use, 86.3 GB is reclaimable."

or similar, your call on exact phrasing, but the requirement is: no bare
pronoun standing in for a quantity that was never stated as its own number
on screen. Same fix likely applies to the menubar tooltip/label in
`MenubarController.swift` if it has the same construction — check while
you're in there.

## Verification
Look at the sidebar on a real scan and confirm the sentence names what's
reclaimable *out of* without requiring the reader to do subtraction in their
head or guess which number "that" points to.
