# Inlining, measured

Writing small functions out where they are called, built and measured on
2026-10-17, and not enabled. The code is on the `inline-experiment` branch of
this repository; what follows is what it did and why it did not pay, so that
the next attempt starts from the numbers.

## What was built

Resolution recorded every function that was pure, not recursive, at most 48
nodes of syntax, and free of lambdas, thunks, local functions, `comp` and
`try` -- carrying its body's resolutions with it, since a module lowered in a
part of its own knows only its own spans. Lowering wrote a saturated call of
one out in place: the callee's body in the callee's module and file, its slots
moved past the caller's, which grew by that much, its parameters substituted
where read at most once (or where the argument was a name or a literal) and
bound otherwise. The inlinable bodies a part reached went into its unit key.
It reproduced itself (stage 2 = stage 3) and a compiled JSON grammar answered
39 of 39 inputs as before.

## What it did

| | reductions | allocated |
|---|---|---|
| self-compile, as on main | 395.7 M | 7.46 GB |
| self-compile, compiler built with inlining | 417.8 M (+5.6%) | 8.08 GB (+8%) |

Wall time moved by 2%, inside the noise. A compiled JSON grammar allocated a
fifth more (517 MB to 651 MB) and parsed small messages a third slower.

## Why it did not pay

- **A frame is allocated whole on every call.** An inlined body's slots are
  appended to the caller's frame, and every call of the caller pays for all of
  them whichever branch it takes. They cannot be shared between two places a
  body was written out, because a suspension made in one holds the frame and
  may read its slots long after. Restricting inlining to bodies that need no
  slot at all removed the growth and still allocated more.
- **A call is cheap next to what laziness costs around it.** Arguments are
  suspensions whether they go to a frame or are written where they are read,
  and the work a call saves -- one frame, one reduction -- is a small part of
  a step.
- **It moved work out of the JIT's reach.** The inlined bodies' bindings made
  their callers too large for the tier's binding rules (`bindings_substitutable`),
  so rules that had been compiled were interpreted. Making a strict binding a
  load in the tier ("Strict bindings are loads" in the VM's notes) recovered
  most of that, not all.

What would change the answer is fewer suspensions, not fewer calls: a body
inlined into a context known to be strict could evaluate its arguments in
place. That is a strictness analysis, which has its own history ("strictness
analysis measured worthless" in the VM's notes) and would need measuring again
on its own.
