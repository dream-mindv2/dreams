# Supercompilation

The plan for supercompiling Dream programs, and a log of how far it has got.
Begun 2026-10-17 on the `supercompile` branch.

## Why this, and not the things before it

What a Dream program spends is suspensions and the frames they hold: half of
a self-compile's allocation is frames and a quarter suspensions, and a
suspension reads 1.5 to 1.7 values of the frame it pins whole ("Frames freed
on return" and the flat-suspension probe in the VM's notes). Strictness was
measured twice and does not help, because it has to prove an argument will be
needed. Inlining was measured and made things worse ("Inlining, measured"),
because it moves suspensions around without removing them.

A supercompiler removes them. It runs the program symbolically at compile
time, with unknown inputs, and writes out what is left: a call of a known
function is unfolded; a `match` on a constructor it can see is decided; a
`match` on the result of a `match` is pushed into the branches; and a list
built only to be consumed is never built -- the consumer is run against the
producer directly. What is left is a smaller program with fewer
intermediates, which is exactly the suspensions and frames that cost: the
`std.list` pipelines, the parser combinators, the records passed between
stages. Because Dream compiles whole programs, every function's body is
there to be run.

## Where it runs

On the lowered IR, after the optimizer, before the image is written
(`compile.image`). Not on source syntax: the IR has every construct desugared
-- patterns are tests and field reads, records are `record_make`, pipes and
`let?` are gone -- and names are global indices, so a residual program can
call a `priv` function of any module, which source could not. Its output is
IR, so the optimizer's sharing, the emitter and the JIT take it as they take
anything.

## The pieces

1. **Core** (`sc.dr`). The IR's slots become named variables. A block's
   `bind` is a `let`, lazy or strict as its flag says; `local` and `capture`
   are variables; `make_closure` and `make_thunk` are lambdas and delays that
   name their free variables; `if`, `switch_head` and `switch_atom` are
   cases; every other operation is one generic primitive form that keeps its
   operands and children as they were. Translating back allocates slots and
   capture descriptors again.

2. **The round trip** (milestone 1). IR to core to IR with nothing in
   between, on every program the test suites run, with the same output. It
   proves the translation before anything is transformed.

3. **The driver** (milestone 2). Call-by-need supercompilation as in
   Bolingbroke and Peyton Jones, "Supercompilation by evaluation" (2010):
   a state is a heap of lazy bindings, a term in focus and a stack of what
   waits on it; states are normalised by a symbolic evaluator; a state seen
   before (up to renaming) becomes a call of the function made for it; and a
   state is split into the part written out and the parts supercompiled
   again. Lazy semantics are kept by never duplicating a binding's work: a
   `let` is shared until it is a value or used once.

   Termination is the whistle: an embedding test on the history of states
   (tag-bags in the paper), and generalisation where it blows.

   What is opaque is called, not run: effects (an impure function or
   builtin), natives, `try`, and anything the driver does not know. A pure
   function it knows is run.

4. **Measuring** (milestone 3). Reductions, allocation and wall time against
   the same program not supercompiled, on the self-compile, the JSON
   grammar and the benchmark suite, and compile time and image size against
   what they buy.

## Risks, written down before they are met

- **Code size.** A supercompiler specialises, and specialising multiplies
  code. The memo table and the whistle bound it; it is measured as image
  size.
- **Compile time.** The driver runs the program; a whistle that blows late is
  a slow compile. Budgets per function, and measured.
- **Sharing.** Call-by-need's whole cost model is that work is shared. A
  transformation that duplicates a binding's work is a slower program and,
  for an infinite structure, a different one. The rule above is the guard.
- **Effects.** Dream's purity is checked, so the driver can trust it: it only
  runs what the checker says is pure.

## Milestone 1: the round trip (2026-10-17)

`--sc-roundtrip` takes the finished program through the core and back
(`compile.finished`, `sc.roundtrip`), and `dreams/tests/sc.sh` holds it to
no change: every example prints what it is recorded to, and the compiler
built through it compiles itself to the same bytes as the one that was not.
It does, and a round-tripped compiler costs what the other does (388M against
383M reductions, 7.49 GB against 7.34 GB allocated; the difference is nodes
nothing reached, which the round trip drops).

What it found, which every example had passed:

- **A strict parameter is a flagged read.** `!acc` is lowered to a `local`
  node marked strict at the head of the body (`lower_body`), so a variable
  has flags. The first version dropped them and every strict parameter
  became lazy again: the compiler it built still compiled itself to the same
  bytes, in 27 s instead of 4.7, holding 10 GB live. Output equality is not
  enough of a check for a translation of a lazy language; the self-compile's
  `--stats` is the other half.
- **The state threaded through the emitter must be forced at each step.**
  A setter stores its value unforced, and 55,000 nodes of unforced pushes
  overflowed the stack (`sc.settle`, and every function taking the state
  strictly).
- **Slots are numbered when a binding is seen, before its value**, which is
  the order `lower` numbers them in; the other order renumbered most of the
  program's frames. What still differs is slots `lower` left unused.

What it costs: about 12 s on a self-compile, against 4.7 for the whole build.
Half is the translation and half is sharing again what it wrote. A parallel
build lowers in parts and shares each part, so the arena the round trip reads
is already a graph -- 55,000 nodes -- and the core's trees are the
unshared program, 246,000. That is the size the driver will work on, and it
will have to work in parts as lowering does; the round trip runs in one
process, which is right for a check and not for a build.

## Milestone 2, step 1: deciding what is known (2026-10-17)

`--supercompile` drives every function (`dreams/src/drive.dr`): a name bound
to a record, a list or a closure is known to be one, the tests a `match`
lowers to are decided on it (`_record_is`, `_match_at`, `_match_is_cons`,
`switch_atom`, `type_is`, `if`, `and`), and a call of a known pure
non-recursive function or closure is unfolded -- its parameters bound to its
arguments lazily, so no argument's work is done twice -- and kept only when
something in it was decided. A block it comes to is spliced into the place it
was called from when that keeps what is evaluated when, so what it answers is
known to what reads it. `area (Shape.square 4)` comes out as `4 * 4`; `twice
(fn y -> y + 1) 5` as two additions. `--sc-stats` says what was decided and
where code grew.

What it took to keep the program the size it was:

- **The arena is a graph and must be read as one.** A `match` lowers to a
  switch whose targets are the tails of one chain of tests, so read as trees a
  self-compile's 57,000 nodes were 670,000 terms, and written back as such.
  Each node is now read into one term (`sc.read`), a map from term to node
  (`origins`, keyed by identity) says which, and the emitter writes a term the
  driver handed back unchanged as the node it was read from. Patching keeps
  every slot where it was, so such a node means what it meant.
- **Every walk over it is memoised**, by identity: the driver per term and
  context, pruning per term, emitting per term and tail position. A walk that
  is not makes one copy per parent. 112,000 nodes became 78,700.
- **A decided term inherits what it replaces' strictness.** An `if` statement
  decided to its branch must still be a strict statement, or it is dead code:
  example 11's `unless` printed nothing.
- **Unfolding is tried only where something is known**, with a budget per
  function; tried everywhere, the work is the product of the bodies' sizes.

What it buys, a self-compile A/B against the same compiler not supercompiled,
interleaved: 2-5% fewer reductions, 1.5-2.4% more allocation, the same wall
time. That is the inlining result again (docs/notes/inlining.md): writing a
callee out moves its suspensions into a bigger frame. Deciding what is known
is the floor the rest is built on, not the win; what removes suspensions is
specialising recursive functions and pushing a consumer into its producer,
which is step 2.

## Milestone 2, step 2: specialising, and running producers into consumers (2026-10-17)

A call of a recursive function is **specialised** on what is known of its
arguments -- a closure (its captures become parameters), or a call nothing
else reads, a *producer*, itself in shapes -- and the specialisation is
registered before its body is driven, so the same call inside it folds back
to it. Where a body forces a parameter bound to a producer (the subject of
its `match`), the producer is unfolded there and the rest of the body pushed
into each of its branches (case-of-case): a branch ending in a constructor
meets the `match` and decides it; one ending in a call is the consumer called
again on that call, a call of a known shape that folds. `dreams/tests/sc/`
holds two programs to it: `suml 0 (mapl f (filterl p (upto 0 n)))` comes out
as one loop over `i` that builds no list, and a `Result` made and matched at
every step of a loop is never made.

What it buys, the same VM, the JIT on:

| program | as written | supercompiled |
|---|---|---|
| `tests/sc/deforest.dr` | 3.16 s, 2.84 GB allocated, 515 majors | 0.079 s, 0.48 MB, 0 majors |
| `tests/sc/results.dr` | 203 ms, 131 MB | 68 ms, 9.9 MB |
| self-compile | 4.85 s, 7.97 GB | 4.78 s, 8.01 GB |

Interpreted the gain is smaller (deforest 8.7 s to 1.9 s, results 27% fewer
reductions): what is left is a loop of strict integer arithmetic, which is
exactly what the JIT takes and the interpreter still runs a frame per step
for. The compiler itself is neither faster nor slower: its pipelines are
`std.list`'s, which the existing fusion already runs as loops.

What it took:

- **Outermost first.** A call is specialised on its arguments *as written*,
  before they are driven, and a producer is remembered as written; driven
  first, the inner stage is specialised on its own and the outer one sees a
  call it cannot look into. And a specialisation's call is seen through to
  the call it stands for (`original_call`), so a stage that was specialised
  anyway is still part of the shape.
- **A name read in each branch of an `if` is read once.** The use count that
  decides whether a binding is a producer added the branches together, so
  the tail of every filtered list looked shared, and the loop over it was
  specialised on the list instead of on the call that makes it.
- **Globals are numbered when a specialisation is begun and recorded when it
  is done**, and one begun inside another is done first: the table has to be
  sorted, or a call of one specialisation is a call of another.
- **A growth whistle per function.** Pushes nest -- each copy of a block's
  rest may push its own -- so a bound per push is no bound; each unfolding
  and push is charged the terms it writes against three times the function's
  size. Without it example 21 needed more than 12 GB to compile.
- **Impure bodies are not driven.** Driving them made the self-compile 15%
  slower and allocate 15% more, none of it in any function's profile: a
  process the build spawns copies the frame of what it is handed, and a body
  written out into an impure function that spawns makes that frame larger.

## Milestone 2, step 3: loop invariants and the data structure (2026-10-17)

Before the driver, `--supercompile` hoists (`dreams/src/hoist.dr`). A
self-recursive function that passes a parameter on unchanged at every call of
itself has a *static* parameter, and anything pure it computes from static
parameters alone is computed once, in a wrapper, bound lazily there and
handed to a worker as a parameter -- the same value, shared, done when it was
first needed. The same reasoning picks the data structure: a static list
the loop only indexes and measures, and measures first (the test of its first
`if`), is read into an array once by `_indexed` -- a builtin no program
writes, which answers anything not a list as it was -- and every `.[i]` and
`len` reads the array. The spine was forced by that first `len` anyway, so
nothing is evaluated that was not.

`tests/sc/indexed.dr`, a loop over positions reading a list: 491 ms as
written, 26 ms hoisted; doubling `n` quadruples the first and leaves the
second where it was (n = 12000: 7.7 s against 31 ms). `tests/sc/results.dr`
lost 99% of its reductions to the same pass: the loop that repeats a
computation of a static argument computes it once.

A builtin that walks a list is one reduction however long the list, so
the indexed loop runs *more* reductions once it is linear, each constant
time; that test is held to the clock instead (`indexed.ratio`).
