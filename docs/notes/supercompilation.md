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

## Milestone 2, step 4: the obvious way is not the slow way (2026-10-18)

The goal: code written the obvious way -- the way a first draft is written,
and the way a review would flag -- runs at the speed of the version a review
would ask for. `dreams/src/accum.dr` runs after `hoist` and rewrites three
quadratic shapes, each a wrapper and a worker:

- `go .. (acc + [x])` and `go .. (acc + piece)`: the accumulator is kept
  newest first, a cons per step, and put in order once where the loop ends
  (`_append_rev`, `_str_append_rev`). Every read of it must be where the loop
  ends, or it would be put in order once per read.
- `f rest + [x]`, naive reverse: an accumulator for what follows is
  introduced, `f' args k = f args + k`, and the recursion becomes a tail call.
- `list.contains x seen` with `seen` handed on as `x :: seen` or unchanged: a
  set is carried beside the list. `_set_lookup` answers what the scan would --
  forcing `x` only when there is something to compare it with, and each
  element added unevaluated only when the scan would have reached it -- and
  answers `()` when it cannot say, and then the scan as written runs.

Each builtin these write means what the code it replaces means, the same
values forced no further, and where it cannot be sure it says so and the
code as written runs. That is the rule for every rewrite here: what the
supercompiler cannot prove it leaves as it was written.

At four times the size, the same VM, the JIT on:

| `tests/sc/` | n | as written | supercompiled |
|---|---|---|---|
| appends | 16,000 | 2,687 ms | 22 ms |
| reverse | 16,000 | 1,443 ms | 22 ms |
| strings | 40,000 | 1,323 ms | 28 ms |
| dedupe | 16,000 | 900 ms | 51 ms |

Each doubles as written for twice the input four times over; supercompiled it
is the VM's start-up.

A worker's body is the original with its slots past the parameters moved up
to make room (`hoist.shift_slots`), one substitution for the whole body. The
first version renamed every binding afresh, which copies every node the body
shares once per parent: the self-compile ran out of memory in `prune`.

Later the same day the shapes widened, each found by writing the slow
program a second way: `list.append acc [x]` is `acc + [x]`; a loop that
tests `len acc` reads a count carried beside it (as written it ran out of
memory at 12,000); `fold` with `acc + [x]` in its lambda is caught by running
`hoist` and `accum` again after the driver, over the loops it specialised;
and `filter (fn x -> list.contains x keep) xs` is caught through the scan
loop `std`'s fusion writes for `contains` (`scan_shape`). The set grows with
the list as the list is evaluated (`_set_refresh`), and a lookup it cannot
answer hands back the rest it has not seen, where the scan goes on.

## Milestone 2, step 5: tree recursion, kept in a table (2026-10-18)

`fib (n - 1) + fib (n - 2)` is exponential as written, because each call
makes the same smaller calls again. When a pure function calls itself more
than once on one path, each call stepping its numbers back by constants
(`n - c`) and handing every other parameter on as it was, `accum.memo_table`
gives it a table: a lazy cell for each combination of its numbers from zero
to where it was called, row by row, each cell the body again with every call
of itself read from the table. The cells are lazy, so a cell no call reaches
is never made, and the table is a knot -- the builder is handed the table it
is building, which Dream allows because the bind is lazy and the cells are.

What keeps it exact is where the table is asked for. The wrapper runs the
body as written down to the branch that calls itself (`memo_point`), so what
it forces before then is what the program forces, and there each number
must already be forced (`forced_when`: both sides of a comparison, both
sides of `a || b` once it is false) and must be an integer from zero to
`memo_cap` -- the table is made whole, so a million cells is where making it
stops being cheaper than not. Anything else, a negative number say, runs on
as written. A call in a cell whose numbers fall below zero calls the
function as written too.

| | as written | supercompiled |
|---|---|---|
| `tests/sc/memo` (fib 27, choose 22 11, a 15×16 LCS) | 4,969 ms | 35 ms |
| fib 32, choose 26 13, a 25×25 LCS | did not finish in 120 s | 34 ms |
| fib 300 (a bignum) and a 720×720 LCS | -- | 389 ms |

The first version built the table with a Dream recursion -- a builder
function consing a list of cells, read into an array -- and the 720×720
table, 518,000 cells, allocated 179 MB, about 350 bytes a cell. The cell is
now a closure of its place in the table, capturing what every cell shares,
and `_memo_cells` makes each cell as the frame a call of it would have and a
thunk of its body, which is what a top-level value already is
(`global_value`). That is 134 MB, and no faster: what is left is running the
cells, 34 reductions each, and a cell is a thunk of a function body, which
the interpreter runs and the JIT does not take. `tests/sc/memo` went from 35
to 7 ms, the builder having been most of a small table's cost.

## Milestone 2, step 6: naive programs, timed at n and 2n (2026-10-18)

A corpus of programs written the way someone new writes them, each run as
written and supercompiled at n and 2n, is what finds the next shape: a
quadratic shows itself as four times the time for twice the input, and the
outputs must agree. What it found, and what each became:

| program | as written, n → 2n | supercompiled | what changed |
|---|---|---|---|
| `paths`: `match [r, c]` with `paths (r - 1) c + paths r (c - 1)` | 42 ms → timeout | 9 ms | the driver reads the tail of a list written out (`[r, c]`), so the match is `r == 0`, `c == 0`, and the table for tree recursion applies |
| `lastloop`: `list.last acc` every step of `acc + [x]` | 1,995 → 5,814 ms | 22 → 23 ms | the last element carried beside the accumulator, as its count is |
| `queue`: `bfs (rest + [a, b])` | 185 → 741 ms | 37 → 36 ms | the queue of two lists: what is added kept newest first, turned around when the front runs out (`queue`) |
| `countdup`: `filter (fn x -> count x xs == 1) xs` | 110 → 319 ms | 24 → 24 ms | the list counted once into a map (`_tally`), each count a lookup (`tallied`) |
| `nth`: `list.nth i xs` in an index loop | 54 → 183 ms | 24 → 25 ms | already: `hoist` reads the list as an array |
| `wordfreq`: counts in an association list | 3,719 ms → timeout | the same | not yet: an association list wants to be a map |

Each is exact in the way the others are. The queue is turned around only
when the program would read past what was left, and only pieces written out
are kept, so turning them forces nothing; a tally answers only for values a
map holds exactly as `==` compares them, and forces the list's first cell,
its head and the value before the rest, in the scan's order.

A trap on the way: compiling the compiler with `--supercompile` failed one
time in three, past the 1 GB process heap. Each pass handed on an image whose
new nodes were suspensions of its patch, holding the pass's emitter and its
reading of the whole arena (`sc.patch` now settles what it returns); and the
image's bytes were first forced inside the write, so emitting ran inside a
native's force. With both, 1.08 GB live at the largest collection went to
0.85 GB and eight builds in a row passed. That margin is thin; the
supercompiler's own live set is next.

The cells then went under the JIT, or tried to: a cell is now a thunk of `fn
i -> cell i`, a two-slot frame holding its place and the cell closure, so
forcing one calls the cell, which is what the JIT takes, and the cell's own
frame lives only while it runs. That took the 720×720 LCS's peak live set
from 58 to 34 MB and its time from 398 to 345 ms; the JIT compiles the cell
but gains little, because every lookup forces a neighbouring cell through a
nested force and the compiled code falls back each time. Filling the table
bottom up, a loop the JIT would take whole, is only exact when a cell cannot
fail, and is not done.

It also showed a cost every short program paid: a run that ended while the
JIT was compiling a function that had just got hot waited for LLVM to
finish, 50 ms on a 7 ms program. `dream_main` now ends without waiting, once
the processes are gone, as `os.exit!` does.

## Milestone 2, step 7: a second corpus (2026-10-18)

Eight more programs written the slow way. Four were already linear --
`contains` on an unchanging list (`twosum`), a string grown in a fold, a
count per letter, and a matrix of lists read by position, which is cubic as
any product is -- and two became linear:

| program | as written, n → 2n | supercompiled | what changed |
|---|---|---|---|
| `revloop`: `list.head (list.reverse acc)` per step, `acc` grown at the front | 44 → 145 ms | 10 → 10 ms | the oldest element carried beside the list: a cons changes it only on an empty list (`consed_last`) |
| `prefixmax`: `maximum (take (i + 1) xs)`, `sum (take i xs)` for each `i` | 2,154 ms (test) | 25 ms | the aggregate carried from step to step (`prefix_folded`) |

`prefix_folded` knows nothing about maxima or sums. A fold that answers its
accumulator on an empty list and steps by the list's tail (`fold_shape`) is
carried on by one element by running it on that element alone from the
accumulator so far, so any aggregate made by one -- handed the list whole,
as a fused `sum`, or the head as the accumulator and the tail as the list,
as `maximum` -- is carried that way. The rest past the prefix comes from
`_list_drop`, once, where the length carried is not this step's.

Two traps. A rewrite that calls a `std` function the program never reached
calls the stub every unreached declaration shares, which divides by zero
(`global_named` now answers `-1` for one). And the shapes that also extend
their calls of themselves rewrote the reads first only by accident: a read
inside a call's own arguments was rebuilt from the call's original
arguments and left as written. Each now replaces the reads in one pass and
extends the calls in another.

Still quadratic: a join by key (`list.find (fn c -> key c == o) customers`
per order), which wants an index built as the scans go, as the membership
set is; and a priority queue sorted again each step, which wants a heap.

The join became linear too. A search of an unchanging list by a key --
`list.find (fn c -> c.[0] == o) customers`, the scan fusion writes for it --
reads through an index (`_index_new`, `_index_find`) filled as the scans
would have read it: a key already read answers from the map, anything else
reads on from where the index stopped, an element and its key at a time,
until it finds the key or the list ends. It is filled in place, with the
write barrier on each store, because a functional index threaded through
the loop cannot learn keys the scans compute and drop. A search inside a
small function the loop hands the list to (`name_of customers o`) is read
the same way, through a copy of that function taking the index too, called
as a closure so it needs no global. The test puts an element whose key is
`1 / 0` past the last one asked for: neither the scan nor the index reaches
it. 641 → 31 ms.

The supercompiled self-compile still ran past the process heap one time in
five. The cap is a guard against a program that runs away; a whole-program
compile is large on purpose, so `[vm] max_heap` joins `nursery_max` as a
setting a manifest makes and the image carries (`VMOP` key 2), applied
unless `--max-heap` or `DREAM_MAX_HEAP` says otherwise, and the compiler's
manifest asks for 4 GB. Its live set is still to be made smaller.
