# Native on many threads: the plan

Status: **being built; the log at the end says how far.** Read `aot.md` first. The plan was
written from a reading of the runtime, without a prototype, so its costs were predictions; the
log has the measurements.

## What was asked

- Native programs must be able to use every core.
- It stays **green threads**: cheap processes, M of them on N OS threads.
- It is the time to think about async.
- Blake questioned a stop-the-world collector. It is rejected below.

## Decisions

### 1. M:N green processes, on one worker per core

A worker is an OS thread with its own context. `p`, the first argument of every machine
function, already reaches everything fast, so `p` becomes the worker. No generated code needs
to find its context another way, and no thread-local storage is needed from our linker.

### 2. Async is not a language feature

There is no `async`/`await` and no coloured functions. A process plus a `!` call that parks is
already async: direct-style code, and a wait costs a parked stack. What needs building is below
the language: **a native may block its green process, never its worker** (decision 5).

### 3. A heap per process, each collected by its own process

| | Shared heap, stop-the-world (rejected) | Heap per process (chosen) |
|---|---|---|
| A collection stops | every worker | that one process |
| A collection walks | every process and all live data | one stack and one heap |
| 100,000 idle processes | scanned every collection | cost nothing |
| Thunk entry | needs an atomic claim once threaded | no atomic: only its process can reach it |
| Thunk update | needs ordering, and an aarch64 barrier | ordinary stores, except shared thunks |
| Pause scaling | grows with total live data and cores | bounded by one process's data |
| `send!`, `spawn!` | a pointer | **a copy (the real cost)** |
| CAFs | just work | **need a shared region (the real complexity)** |

The reasons to prefer it:

- The stop-the-world collector would be a global pause on every allocation budget. Making it
  parallel still means a rendezvous; making it concurrent needs a barrier in generated code.
- This is already the language's behaviour on the VM: messages are deep-copied and `spawn!` copies
  its closure (`dream/docs/gc.md`, "The collector today"). Copying changes nothing a program may
  rely on. This design is chosen for its own merits, not to match the VM; `aot.md` still holds.
- A lazy language mutates almost nothing. The only writes that cross heaps are thunk updates in
  the shared region and mailbox deliveries, so the barrier has exactly two places to live.

Known costs: a large message is copied, where one heap passed a pointer. `procs` and any
message-heavy program are the ones to watch (decision 7 mitigates; the benchmark decides).

## The design

### Worker and process state

Stays on the worker context (`p`): `ctx_hp`, `limit`, `guard`, `floor`, `stack_top`, `retry`,
`retry_stack`, `error`, `scratch`, `scratch2`, `current`, `current_id`, `ffi_sp`, `in_callback`,
`cb_error`, `cb_text`.

Moves to the process, swapped by `make_current!` and on leaving: `hp`, `limit`, `chunks`, `total`.
`to` and `want_gc` stay on the worker, since a collection runs to completion on one.

Moves to one static shared block, `prim.info "world"`, with its own locks: `table`, `next_id`,
`live`, `unique`, `ticking`, `handles*`, `argc`, `argv`, `k512`, `ssl`, `foreign*`, `opened`,
`spare`, `wait_*`, `poll_tick`, `ptys`.

Each of these reads `p + ctx_x` today, so the change is mostly mechanical. Each field still has
to be looked at, as a racy one will not fail in a test.

### Heaps

- A process starts small (try 4 KB, with its 32 KB stack), not `min_chunk`'s 8 MB, which would be
  800 GB for 100,000 processes. Measure the size; growth is `live * 2` as now.
- `collect!` keeps its shape. It scans the running process's stack and record, and its held
  messages. `scan_processes!` goes: nothing else can point here.
- `evacuate!` leaves alone what is static **or in the shared region**. That is one more range
  test beside `static_limit`, so reserve the region at a fixed range.
- A small chunk comes from `malloc` or a per-worker free list. The spare list (`take_chunk!`) is
  per worker.
- A process's heap goes when it finishes, in `finish!`, all at once.

### Messages, spawn, results: copy once

A message is copied by the sender into a detached chunk and linked to the target's mailbox under
a per-process lock. The receiver **adopts the chunk into its heap's chunk list** with no second
copy, and its next collection evacuates it (BEAM's heap fragments). `spawn!` builds the new
process's heap the same way. `finish!` copies its result out to a detached chunk before freeing
its heap; a joiner adopts or copies it.

`monitors`, `joiners` and the mailbox are heap lists on the record today, built with `new_cons!`.
They become raw, `malloc`ed lists, since a record is read by other workers. `pcb_kill`'s reason
and `[:down, ..]` are made by the copy too.

The copy preserves sharing and cycles (letrec) by forwarding in the sender's heap, then restoring
it, or with a side table. The sender is the only one who can see that heap, so either is safe.

**Open: a hole inside a message.** Entering a thunk overwrites its first payload word and drops
the rest from the collector's view (`object_words!` says 2), so a message that reaches a thunk
its sender is evaluating cannot copy that work. Read how the VM answers this (`copy_between`,
`dream/src/scheduler.cpp`) before choosing. Candidate: keep a claimed thunk's payload whole, which
costs retention, or make the copy a shared thunk the owner fills.

### CAFs and the shared region

A CAF is static and every process may force it. It is the only thing shared by reference.

- Claimed by compare-and-swap on its info. Only CAFs and shared thunks pay for an atomic; **the
  thunk code generated for ordinary thunks is unchanged** (`machine.dr`, thunk entry).
- A process evaluates the CAF on its own heap as now. On update, the answer is **promoted**: the
  value and everything evaluated it reaches is copied to the shared region, and the CAF points there.
- An unevaluated thunk reached in the promotion becomes a **shared thunk**: it is claimed by CAS,
  evaluated by whoever forces it first, and its update promotes in turn. An infinite CAF list
  is therefore fine: promotion follows evaluation and never forces anything.
- A loser of the claim parks on the CAF rather than spinning, and is woken on its update.
- Order the update: value, then info with release. `store_rel!`, `cas64!` and a fence are new
  dialect primitives (`dialect.dr`, `primitive`). Reading an evaluated shared object needs no
  barrier on x86-64; **aarch64 needs an acquire at a shared thunk's entry**, which is one place,
  for whoever does that port.
- The region is immortal to begin with. A CAF retains what it holds anyway, though a shared
  thunk's discarded input is garbage until a later mark-sweep exists. Write it down as a limit.
- An error raised while evaluating a CAF is promoted too. A kill during one must **release the
  claim** rather than leave it raising, or killing one process poisons a value for all of them.
  This differs from `unwind!`'s private-thunk rule, which stays. Check what the VM does here.

### Scheduling

- A run queue per worker; a worker with none steals half from another. A wake pushes to the
  waker's queue, so a message pair stays on one core. Lock first, deque if the numbers ask.
- `state` changes are guarded by the record's lock, and **parking is check-then-sleep under it**:
  `recv_m!`, `await_message_m!` and `join_m!` must look at the mailbox and publish
  `state_waiting` together, or a send landing between them is lost. `pcb_sp` is saved first.
- Preemption: the tick thread loops over a table of workers' guards (`tick_text`, which holds one
  target today). A kill sets the running worker's guard.
- A process's `make_current!` overwriting a guard set a moment before loses at most one tick or
  delays a kill by one. With no global stop, nothing depends on it, unlike in the rejected design.
- Workers start at the first `spawn!`, so a program with one process keeps today's numbers.
  Count from `sched_getaffinity`, with an environment override. The tick thread already starts there.
- Idle workers sleep on a futex or condition variable, and a push wakes one if any sleep.
- Deadlock: every worker idle, nothing in the poller or pool, `live > 0`. `all_done!` is
  when `live == 0`. Compare with the current `idle!`.

### Decision 5: nothing blocks a worker

- **One poller**, using `epoll` (kqueue when macOS comes). This replaces `poll_fds!`, which
  rebuilds its list from the waiters on each call and is quadratic in sockets. A process registers
  its descriptor and parks. Timers become a heap, replacing `earliest_at!`'s walk.
- **A small pool of blocking threads** for what the system cannot do without blocking. A process
  hands over the call and parks. Calls found by grep: `read`, `write`, `open`, `fsync` on regular
  files, `getaddrinfo`, `waitpid`, directory and stat calls, the `"read"` in `digest_file!`,
  file copies. Note the pool writes into memory that must not move: use a detached buffer.
- `nanosleep` in `idle!` goes. `waitpid` by `WNOHANG` poll goes, in favour of `pidfd` or the pool.
- **The handle table** stops being `realloc`ed under readers (`add_handle!`): reserve it with
  `map_memory!` or chunk it. Buffered handles and TLS sessions get a per-handle lock, not held
  across a park. Two processes on a socket is a program's business, but must not corrupt memory.

### FFI

- `@i_cb_context` is one global, and a callback finds its context there (`rt/main.dr:6168`). With
  many workers, use `pthread_getspecific` or similar, set once per worker.
- A foreign call in a process blocks its worker. A long one should run on the pool or on a
  dedicated thread. **A callback must run on the thread C called it on**, and a library with
  thread affinity must not migrate. `foreign.run!`'s library server is the shape: pin a server
  process to one OS thread. A pinned process needs a scheduler rule.
- Pointers into a process's heap handed to C stay valid, as only its own process collects it and
  that process is inside the call. This is a gain over a shared collector.
- OpenSSL: one session at a time on a handle, by the per-handle lock.

## Order of work

Each step ends with `dreams/tests/aot_programs.sh`, `dreams/tests/aot.sh` and
`dream/tests/ffi/run.sh` passing, plus the two benchmark sets, A/B on one machine.

1. **Heap per process, still one thread.** Records, small heaps, copying `send!`, `spawn!`, results,
   the shared region and CAF promotion. Measure `procs` and `maps` here: **this is the go/no-go on
   the decision**, as it shows the price of copying with no threads to confuse it.
2. **Raw records and the world block**, with locks, still one thread.
3. **Workers**: run queues, stealing, parking under locks, tick table. Then run the programs with
   stress settings: one worker, many workers, a tick of 1 ms.
4. **The poller**, timers, the blocking pool. Then `std.net` under load.
5. **FFI and TLS** on workers; pinning.
6. **Tests**: a parallel benchmark showing a speed-up (none exists: `procs` measures switching),
   a stress of CAFs forced from many processes at once, kill during a CAF, a race pass under
   ThreadSanitizer-like scrutiny if one can be had for generated code.
7. **Then**: generational per-process heaps (`aot.md` lists this for `maps`), which gets simpler
   here; and sharing large immutable data by reference, below.

## Decision 7: large messages, later

If step 1 shows copying hurts, a large forced structure can be promoted to the shared region once
and passed as a pointer. It needs reclaiming, as the VM's `vm.share` and `vm.release!` do. Do not
build it before a measurement asks for it.

## Facts to start from

- Baseline, VM → native, ms, from `aot.md`: `tree` 691→72, `maps` 598→631, `sorts` 358→528, `recs`
  745→511, `strs` 201→169, `procs` 938→144. All on one thread, so the VM's numbers may use more.
- The scripts behind them are in a session scratchpad and **will not outlive it**. Recreate the
  programs in `benchmark/` as step 1's first commit. They are in the session transcript.
- Things that should stay as they are: stacks (`move_stack!` moves only the running process), the
  guard, trunks and maps (path-copied, so immutable).
- Runtime natives that mutate an object should be audited at step 1 (`array_store!`, `index_set!`
  and the 81 stores of the form `store64! (x + ..)`). I have not read them all.
- Machine: 24 cores here; aarch64 and macOS native remain unbuilt (`aot.md`), and the plan keeps
  their one new constraint, the acquire at shared thunks, written above.
- `std.proc`/`spawn!`'s surface does not change. No program should need editing.

## Log

**2026-11-02: step 1, a heap per process on one thread.** Built as designed above, in
`mind/std/rt/main.dr`:

- Each process has its own chunk list, saved to its record when another runs (`save_heap!`,
  `load_heap!`), and a collection is of the running process alone: its stack, its resume value and
  the messages it has taken in. Its first allocation area is what is left of the segment its work
  was copied into, then a budget that doubles at each collection from 4 KB to `min_chunk`. The first
  process starts at `min_chunk`, so a program of one process allocates as before.
- Chunks of a megabyte or less come from free lists by power of two, carved from 2 MB slabs
  (`chunk_get!`); larger ones are mapped and the largest few freed are kept, as before.
- `copy_out!` is the collector's walk with a log to put the source back. It writes a message,
  a spawn's work and a monitor's `[:down, ..]` into segments the receiver takes in as chunks
  (`take_mail!`), and promotes into the shared region: a process's answer, a kill's reason, the
  foreign-handle table and every CAF's value. A thunk being evaluated arrives as an error, as on
  the VM; a suspension in a message travels as itself.
- **The shared region** starts at 4 GB and grows upwards by fixed mappings (`shared_more!`), so
  the collector's test of an address is one compare against its end, a load from the world block.
  It is not collected.
- **A CAF is a shared thunk**: `[info, suspension, owner]`, whose suspension is never written.
  Whoever claims it evaluates a copy in its own heap and promotes the answer
  (`code_shared!`, `frame_shared_update!`). On a raise or a kill the claim is given back
  (`frame_shared` in `unwind!`), so killing a process in the middle of a CAF poisons nothing: the
  next process to ask evaluates it again. A suspension reached in a promotion becomes one too.
  This answered the plan's open question about a raised CAF: it is evaluated again, not promoted
  as raising.
- Mailboxes, joiners and monitors are raw `malloc`ed lists, as other processes write them.
- An error in the shared region is copied before `where` is written on it (`own_error!`).

Found on the way: a tick yielded only when the run queue had something in it, so a process
sleeping on a timer could not wake until a busy one finished. It now yields while anyone waits
on a timer or a descriptor too.

Measured A/B against the commit before, same VM, interleaved, ms, best of three
(`benchmark/native/run.sh`, which is new):

| | tree | maps | sorts | recs | strs | procs | fanout |
|---|---|---|---|---|---|---|---|
| before | 75 | 586 | 501 | 470 | 159 | 137 | 120 |
| a heap each | 75 | 585 | 497 | 461 | 158 | 156 | 142 |

`procs` pays 14% for copying and for a heap per process, against the VM's 939. The first try was
1,267: every receive walked the whole mailbox looking for messages not yet taken in, which a
pointer to the first such fixed, and then 229, from touching a fresh page for each of 50,000 live
processes, which starting in the work's segment fixed. `fanout` is code placement: its IR is the
same function for function, and built from the same IR with clang the two are within 3%.
**The decision stands: go on to threads.**

`dream/tests/programs/process_heaps.dr` holds the new behaviour to the VM's: a CAF from many
processes, sharing kept in a copy, a closure, a big integer and a 200,000-element list through
messages, a lazy answer joined twice, a CAF that depends on itself, a kill's reason, and a kill
in the middle of a CAF.

**2026-11-02: steps 2 and 3, the world block and workers.** Native programs now run on every core.

- **The world block** (`@i_world`, `w_*` in `rt/main.dr`) holds what no one process owns: the
  process table, now one mapping of 16M entries touched as it fills rather than reallocated under
  readers; the handle table, the same at a million; the counts, by atomic add; the scheduler's
  lock, condition and wake descriptor; and the libraries, terminals and foreign table opened, under
  a lock of their own. The foreign table's read-modify-write moved into the runtime
  (`foreign_put!`, `foreign_drop!`), as two workers adding a handle at once would lose one.
- **Workers** start at the first `spawn!`: `DREAM_CORES` of them, as on the VM, or the cores the
  process may run on. Each is an OS thread with a context of its own, so `p` is the worker and no
  generated code changed. The tick thread sets every worker's guard from a table.
- **A run queue a worker**; a wake pushes to the waker's own, and a worker with nothing takes half
  of another's. Before sleeping it spins a while, but at most two do at once: a crowd of spinners
  reading the queues slowed the worker running the root by a third.
- **Parking is check-then-sleep without holding a lock across both**: a wake of a process that is
  not parked yet sets `pcb_woken`, and the park that follows goes round again. A record's state,
  mailbox, joiners, monitors, kill, `wake_at` and `wait_fd` are under its lock, which, like a run
  queue's, is a word spun on. A mutex there cost a system call each time two workers met at one,
  and on `procs` that was most of the run.
- **Shared thunks** are claimed by compare-and-swap of the info, and a process that finds one
  claimed by another parks on its list of waiters, woken when it is updated or given back.
  Promotion is under one lock. The update stores the value, then the info with release.
- **Waiting for the system**: one worker at a time asks `poll`, with the scheduler's lock, now and
  then while others are busy and blocking when it has nothing else, the lock let go and an
  `eventfd` in the set that a new waiter writes to. Timers are under each process's lock, so a
  new one is not mistaken for one that ran out. The deadlock test is every worker counted idle,
  nobody polling and nobody waiting on the system.
- A callback from C finds its worker by a thread-specific key, and its function is promoted when the
  stub is made, so any worker's process may be called back on and no collection moves it.
- Small raw cells (a waiting message, a joiner) and first stacks are kept by the worker that freed
  them: from `malloc`, each thread that freed one grew an arena of its own.

Found on the way: a push made while holding the scheduler's lock -- a timer running out -- took the
lock again to signal a sleeper, and the run hung with four workers or more. A worker now knows
whether it holds that lock (`ctx_sched_held`).

Measured A/B against the commit before step 1, same VM, interleaved, ms, best of three:

| | tree | maps | sorts | recs | strs | procs | fanout |
|---|---|---|---|---|---|---|---|
| before | 74 | 588 | 504 | 471 | 159 | 144 | 121 |
| 24 workers | 74 | 599 | 502 | 473 | 161 | 212 | 22 |
| one worker | | | | | | 158 | 130 |

`fanout` is 5.5 times faster, and its sixteen pieces are not of one size, so that is near what it
can be. `procs` is one process exchanging a message with each of 50,000 others, which is serial
by construction, and pays on many workers for handing each process to another core: 212 against
158 on one and 939 on the VM. What is left of it is `malloc` of records and stacks on whichever
thread the root has moved to, and the futex calls of waking sleepers.

`dream/tests/programs/caf_race.dr` forces CAFs that depend on one another, a shared lazy list and
a failing CAF from 64 processes at once; it and `process_heaps.dr` were run forty times each on 2
and 24 workers with no difference from the VM. The whole program suite passes on 1, 3 and 24.

Not done yet: the `epoll` poller and a pool of threads for calls that block a worker (step 4),
pinning a foreign library's server to one thread (step 5), and a stress run with a faster tick.

**2026-11-02: step 4, nothing waits in a worker.**

- **`epoll`** replaces `poll` over a list rebuilt from every waiter on every call. A descriptor
  is registered once, edge-triggered, the first time anyone waits on it, in a slot of a table the
  size of the handle table with a spin lock of its own, so a wait is a list push and no system
  call. An edge with nobody waiting sets a ready bit, and a process about to park that finds its
  direction there goes round again instead, which closes the window between `EAGAIN` and the
  wait. Only the waiters an event's direction is for are woken. Two measured steps on the way:
  one-shot registration cost an `epoll_ctl` per wait, and one lock for every slot -- the
  scheduler's -- had the workers queueing on it, 146,000 futex calls on `net`.
- **Timers** are a binary heap under the scheduler's lock. A process woken some other way leaves
  its entry, which is dropped when it reaches the top; the deadlock test counts only the timers
  still meant (`live_timers!`), so a stale one cannot hold off the report.
- **The blocking pool**: four threads, started at the first job, for what the system cannot do
  without blocking. A name lookup in `connect!` goes there (a literal address does not), and the
  process parks with the job in its retry frame. Jobs in flight count against a deadlock.
- **Children**: `posix_spawnp` instead of `fork`, and a wait on a `pidfd` instead of `waitpid`
  polled with a backoff. Two hundred concurrent `exec!` calls took 158 ms before this work; with
  `fork` from many workers they took 520, as the copies of the page tables queue on the address
  space's lock, and with `posix_spawnp` they take 65.
- **A heap's budget** stops doubling at 64 KB for every process but the first, unless the
  process has the live data or the stack to need more. At `min_chunk`, two hundred busy
  connections each mapped and unmapped a to-space at every collection and faulted every page of
  it in again: 103,000 faults where the shared heap had 12,000.

Found on the way: the runtime's own library bound `native.spawn_child`'s answer with a lazy
destructuring, and since a native looks pure to the compiler, the two processes `exec!` starts
were each given a copy of that suspension and started the child again. Ordinary code is not
affected -- an impure call runs where it is written -- but the library forces it now.

`net` is new in `benchmark/native`: a listener, a process a connection, and 100 clients doing 250
round trips each. With 500 clients it measured the kernel retransmitting the connections the
backlog of 128 dropped, a second each, on the VM too.

| | tree | maps | sorts | recs | strs | procs | fanout | net |
|---|---|---|---|---|---|---|---|---|
| before step 1 | 75 | 602 | 510 | 476 | 164 | 145 | 123 | 344 |
| now, 24 workers | 72 | 603 | 506 | 469 | 161 | 199-231 | 23 | 122 |
| now, one worker | | | | | | | | 345 |

Not done, on purpose for now: reading and writing regular files stays on the worker. The plan put
them in the pool, but a read from the page cache is a microsecond and a hand-off to the pool is
two thread switches; it wants measuring with a slow disk before it is moved. `fsync` and the
directory calls likewise.

**2026-11-02: step 5, foreign libraries and TLS on workers.**

- **Pinning without an API**: a process pins itself to its worker the first time it calls C
  (`ffi_call_m!`), as a library may keep state for its thread -- a GUI toolkit, a GL context, a
  thread-local error. A library server is such a process, so `foreign.run!` gets this with no
  change to `std.foreign`, and so does code that calls C itself. A pinned process is pushed to its
  own worker's queue, stealing stops at the first pinned process in a queue, and a push onto
  another worker's queue wakes every sleeper, since which one a signal wakes is the kernel's
  choice. The deadlock test counts every queue, pinned or not.
- **A TLS session is held** for the stretch of work between two parks, by the process's id, so a
  reader and a writer on one connection -- HTTP/2, WebSockets -- on two workers do not interleave
  inside OpenSSL. It is let go before every park, answer and failure.
- **A push from outside the workers** -- the blocking pool's -- interrupts `epoll_wait` if the
  worker it is for may be the one waiting there. On one worker an HTTPS request named by host
  waited out its whole 30 s timeout without it, as the only worker was the one in `epoll`.

`dreams/tests/aot.sh` now builds `dream/tests/tls/tls.dr` and `http.dr` native and holds them to
the VM's output on one worker and on 24; before, nothing ran TLS native. Both pass, and so does
"the server stops, and every connection with it", which the native build failed before this work.

Step 6 is in the log above: `fanout` is the parallel benchmark, `caf_race` and `process_heaps`
the stress of CAFs and of a kill in the middle of one, and the suites run on 1, 3 and 24 workers.
No race detector for generated code was found. Step 7 -- generational heaps per process, and
sharing large immutable data by reference -- waits, as decision 7 says, for a measurement to
ask for it.

**2026-11-03: what the shared region keeps.** Asked whether to collect it, the first question was
what grows in it that should not. In order of size:

- **A finished process's answer** stays for as long as its record, and records are never freed --
  on the VM too: `Runtime::retire_process` exists and nothing calls it, so every `exit_value` lives
  as long as the run. Native is no worse here, and freeing either needs a rule for when a pid can no
  longer be joined, which neither runtime has.
- **The foreign-handle table** was a map promoted at every change, so every version of its path was
  kept: hundreds of bytes for every handle made or released, where the VM keeps a C++ table. It is
  raw memory now (`foreign_put!`, `foreign_get!`, `foreign_children!`, `foreign_owned!` in
  `rt/main.dr`): an array of entries by id, each `malloc`ed and freed on release, the live ones
  linked oldest first. A handle leaves nothing behind unless a field of it is an object, which no
  address on x86-64 is.
- **A shared thunk's suspension**, once it is evaluated, and a kill's reason: small, and once each.
- **A CAF's value**: what it holds, which any runtime keeps.

So nothing native keeps grows without a matching growth on the VM. Collecting the region itself
would mean knowing that no heap points into it, which is every heap traced, the global pause this
design was chosen to avoid, or a census each process contributes at its own collections; it is
worth building with process records that can be reaped, and not before.

**2026-11-03: the census -- the shared region collected, finished processes reaped.** Each process
reports at its own collections, as the VM's shared areas do (`request_census` in
dream/src/scheduler.cpp is the pattern), and the census decides two things at once:

- **The region is blocks of a megabyte** (`take_blocks!`), filled by promotion as a message fills
  segments, a large object taking a run. A block nothing marked in a round, and nothing wrote to
  since it began, has its pages given back (`madvise`) and is used again, so the region stays one
  range and the collector's test one compare.
- **A round** begins when the region has grown past what the last one kept, or 65,536 processes
  have finished since. Every live process is then due: one running collects at its next function
  entry, one parked is collected by whoever began the round, in a context kept for it, holding its
  record so that nothing wakes it. That collection is the report: every shared object it meets is
  marked and traced through the region, every pid's id noted. The last report marks the roots no
  heap holds -- answers, kill reasons, CAFs (`@i_cafs` again), foreign handles, callbacks.
- **A copy made during a round** -- a message, a spawn, a promotion -- marks what it leaves in
  place and the pids it carries, so a reference cannot slip past by moving from a process yet to
  report into one that has. A message not yet taken in is read at its owner's report.
- **Reaping**: a finished process whose pid no heap held is gone, record and answer, since nobody
  can join or monitor it again. A failure nobody joined stays, for the report at the end.

One measured trap: marking was right and nothing was freed. A CAF's lazy list, forced a cell at a
time between processes' answers, left one live cell in every block. Promotion now fills two sets of
blocks -- what goes with a process (an answer, a kill's reason, a thunk inside them) and what lives
for the run -- and a thunk's value goes where the thunk is (`shared_mode_of!`).

300,000 processes each answering a 50-element list, joined in batches: the shared region kept holds
at 45 MB from the fourth round on, and the run's peak memory is 179 MB on one worker where it was
335 MB. Five times as many: 195 MB where it was 1.49 GB, and 4.83 s where it was 5.41.
`DREAM_CENSUS_TRACE=1` says each round. `dream/tests/programs/census.dr` crosses a round and then
uses what must survive it: a pid kept throughout, a pid that only travelled in a message, a monitor
set up after, a CAF.

**2026-11-03: two loose ends.**

- **`procs`** spent 113 ms of its time starting 50,000 processes, nearly all of it the kernel's:
  each process's first stack was 32 KB from `malloc`, and the page at its top was a fault of its
  own, 67,000 of them. A first stack is 2 KB now, and a small stack keeps half of itself below the
  guard for what is pushed between two entries (the largest frame in the programs here is 48 bytes).
  Starting them takes 66 ms on one worker, and the whole run is 126-151 ms on 24, from 220: faster
  than it was on one thread before any of this (145).
- **OpenSSL** is looked for as the VM looks for a library on the system: `$DREAM_OPENSSL_LIB`, then
  `$DREAM_LIBRARY_PATH`, the installation's `lib`, the loader, and Nix's profiles. On NixOS, where no
  loader knows of it, a native program using TLS found nothing unless told the file; the error now
  says where it looked.

**2026-11-03: the stress the plan asked for.** `DREAM_TICK_US` sets the tick (10 ms by default,
at least 50 us), and the program suite runs clean with it at 1 ms and 100 us on 2, 3 and 24
workers. It found one thing, in `examples/16_registry`, which polls a registry 500 times for a
server a supervisor is starting: on exactly two workers the server came after 260 to 670 asks
where the VM, and native on any other count, needs two. A worker new to a size of chunk carved a
whole 2 MB slab at once, writing a link into every chunk and faulting in all 512 pages, which held
the supervisor's worker for the length of a tick in the middle of its first message. Slabs, and
the cells messages wait in, are carved a chunk at a time now. Two changes to fairness came with
it: a park that is woken before it sleeps goes to the back of the queue when others are waiting
there, and every 64th receive that could go straight on gives way first if anything is queued,
as the VM does after so many reductions. `DREAM_DUMP` prints every process's state when the first
one fails.
