# Native on many threads: the plan

Status: **a plan; none of this is built.** Native still runs on one OS thread
(`rt/main.dr`, "processes"). Read `aot.md` first. This was written from a reading of the
runtime, without a prototype, so the costs below are predictions to be measured.

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
