# Native code in direct style

The goal: a native Dream program runs close to what the same program written in C++ does. This is
the design that gets there, why the one before it cannot, and the order it is built in. The AOT
as it is today is [aot.md](aot.md); this replaces its code generator and the core of its runtime,
and keeps everything else -- the image as input, the dialect, the linker, the library.

## Why the code generator as it is cannot

Today a native program is continuation-passing all the way down. No Dream function returns: each
tail-calls the next with the context and a stack pointer of its own (`%p`, `%sp0`), and a frame on
that stack -- an info word and the values still needed -- is the only return address there is.
That is what lets a process park anywhere, move between workers, have its stack grown and be
collected precisely: the stack is data the runtime lays out itself.

The cost is at every place a value is forced. Forcing may run any code at all -- a thunk can
receive a message -- so before a force every live value is stored into a frame, a continuation
function is made to resume at, and the answer comes back through a jump through a pointer. A value
is in memory, not a register, wherever it crosses a force; LLVM cannot optimize across one, since
it is a call it cannot see the end of; and nothing is inlined across one. In `dreams` that was
105,000 continuations and 82,000 thunks for 4,574 functions of the program, 700 MB of IR, half of
it frame stores and loads. The numbers on the native benchmarks follow: `sorts` and `maps` are
slower native than interpreted with the VM's JIT, and native `dreams` spends twice the VM's CPU on
a compile.

Making that code smaller -- sharing identical continuations (done), addressing through typed
pointers (done), fewer thunks -- is worth doing, and is not the gap. The gap is that a force is not
a call.

## The design

**A force is a call.** `seq x (enter v) rest` becomes `x = force(v); rest`, where `force` answers
`v` itself when it is evaluated (one test of its tag and info, inline) and otherwise calls the
thunk's code, which evaluates the body, updates the thunk and returns. A call of a known function
whose answer is needed is an ordinary call. A tail call stays `musttail`, so a loop written as
recursion is still a loop. There are no continuations: what follows a force is the code after the
call, in the same function, with its values in registers.

**Each process has a native stack of its own.** A call that may park -- `recv!`, `join!`, a read
that would block, a shared value another process is evaluating -- saves the callee-saved registers
and the stack pointer and switches to the worker's scheduler stack, as Go switches goroutines;
resuming switches back, and the call returns. A process still moves between workers: its stack is
memory, and nothing on it says which thread it was on. Stacks are reserved large and committed as
touched (`MAP_NORESERVE`), since a native stack cannot be moved once pointers into it may exist; a
recursion deeper than its reservation is a stack overflow, as it is in C++, and is reported as one
by a guard page.

**The collector finds roots on a stack conservatively.** Every word on a process's stack, from its
stack pointer to its top, with the registers saved where it stopped, that could be a pointer into
the process's heap pins the chunk it points into: a pinned chunk is kept where it is, every object
in it is a root, and everything else is copied as now. LLVM keeps whatever it likes in registers
and spills what it likes; none of it needs describing. The heap stays precise -- every object says
what its fields are -- so only the stack is guessed at, and a wrong guess keeps a chunk one
collection longer. (LLVM's statepoints would make the stack precise too, at the price of a
relocation pass over all generated code and a stack-map reader in the runtime; worth measuring
later against how much pinning actually keeps.)

**Preemption is a check at function entry and on loop back-edges**, as now: the guard word, set
above every address by whoever wants the process to stop. Stopping is a switch to the scheduler
stack or a collection, from a call the generated code makes, so whatever is live is already on the
stack where the collector looks.

**Raising unwinds by jumping.** `try!` calls its body through the runtime, which records a handler
-- the stack pointer and saved registers to come back to -- and `raise!` jumps to the innermost one,
as `longjmp` does. Each thunk being forced pushes an update record onto a chain kept per process,
so a raise can leave every thunk it unwinds through raising the same error, as the runtime does
now. Cleanups (`defer!`) are records on the same chain.

**Everything else stays.** Values, objects and their layout, the shared region, promotion and the
census, messages and copying, the library, the dialect the runtime is written in, the linker, the
image as input: none of it knows how code calls code. Natives that cannot park are already plain
calls that return.

## Order

Each stage ends with the native program suite (`dreams/tests/aot_programs.sh`) passing under it,
and with the benchmarks in `benchmark/native` -- beside which C++ versions are added first, so
that "close to C++" is a number.

1. **C++ beside the benchmarks.** `benchmark/native/*.cpp`, the same work, and `run.sh` printing
   the three columns.
2. **Stacks.** A native stack per process, the switch (a few lines of assembly per machine, beside
   `_start`), and the scheduler running a process by switching to it. The CPS code runs on it
   unchanged, which is the test that the switch is right before anything depends on it.
3. **The collector, conservatively.** Pinned chunks in the per-process collector, the stack and the
   saved registers as roots. Run under the CPS code too, where it can only keep more than needed.
   *Done (stage 2):* `dispatch!` runs a process on its own stack (`dream_run_on`, beside `_start`
   in `machine.stacks_text`), and `schedule!` switches back before anything else. A process made
   runnable as it parks is still on its stack until it switches off, so a worker taking it first
   waits for `pcb_on_stack` to clear; without that, `census` crashed one run in two at 24 cores.
   Under the CPS code nothing on the stack is needed after a park, so a process is run again from
   the top. The first thing direct style needs of this is the opposite: a park keeps where the
   stack stood, and the process is resumed there, so that a direct-style caller below CPS code
   that parked is still there when it returns. A frame on the runtime's stack whose code returns
   from the native call is the bridge between the two while both exist.
   *Done (stage 3):* `collect!` reads the process's native stack from where it stands, with the
   callee-saved registers spilled onto it first (`prim.stack_here!`, an inline `asm` whose
   clobbers make the function save them), and every word that falls inside a chunk pins it
   (`pin_range!`, `scan_pinned!`). A parked process's stack is read from `pcb_nsp`, 0 while
   parking leaves nothing there. Walking a pinned chunk object by object asked for a heap that
   can be read that way, which it could not: a chunk now has a segment's header, `[next, size,
   end, 0]`, with `end` written when allocation moves on; a thunk that becomes a two-word hole
   fills the rest of itself (`machine.filled`, `@i_fill`), as a string cut to what `read`
   returned and a bignum trimmed where it is do (`string_cut!`, `big_trimmed!`); and a buffer
   for C is a string's body (`scratch!`), not words with no header. `DREAM_GC_PIN_TEST=1` also
   reads the CPS stack this way, which pins on every program the suite runs, and the suite
   passes under it. Under CPS code the native stack is read only in that mode
   (`@i_native_frames` is 0): read always, the runtime's own stale words pinned whole allocation
   chunks of up to 8 MB, every object in them a root, and a native compile of `mind` went 8%
   slower for nothing. That is the first measure of the risk below, and says pins want blocks
   smaller than allocation chunks before direct style turns this on. What is left under CPS code
   is the fillers' stores, within noise on the benchmarks.

   The native stack's size is the compiler's to choose (`machine.native_stack_of`): measured
   across the suite, the runtime never went deeper than 3.3 KB on it, so a program gets 64 KB
   unless it can reach C that goes deeper -- a foreign function, TLS, the GPU, the resolver --
   and 8 MB then. A process that parks with nothing on its stack gives it back to the worker's
   pool, taken again with no system call; fifty thousand processes in `recv!` had held fifty
   thousand stacks, and `procs` went from 900 ms back to 160. In direct style the size becomes a
   bound computed from each function's frame over what a process can call, where one exists.
4. **The code generator.** `machine.dr` writes direct style from the same core program
   (`core.dr` is untouched): forces and calls as calls, thunks as functions that return, `try!` and
   `raise!` through the runtime. Behind `--aot-direct` until the suite passes, then the default.
   *Built (stage 4), and the default since; `DREAMS_AOT_CPS=1` is the code that jumps:* `machine.function_d` and `dexpr`. Each
   function's direct body (`@..d`) answers its value, or 0 for a failure whose error is in the
   context, as a native answers; each call is followed by a test of that, and a failure goes to
   the `catching` around it or out of the function. Beside each body is a shim under the usual
   symbol, which the runtime jumps to and which calls the body and answers the frame on top or
   unwinds, so the runtime's ten jumps into code are unchanged and infos say where the direct
   body is in a ninth word. Direct code reaches runtime code that answers through frames -- a
   parking native, `raise!`, `apply!` for anything but an exact closure, a shared thunk -- by a
   *bridge*: a frame whose code returns (`frame_bridge!`), below which the call is an ordinary
   call, so that the chain of jumps it starts comes back to the caller with the answer, or with 0
   when an unwinding reaches it. A thunk's body marks it a hole, evaluates and writes its answer
   over it, or an indirection to the raise. What the stage needed beside the generator:

   - *Parking keeps the stack.* `schedule!` switches off a process's stack (`dream_switch`) and
     `dispatch!` switches back into it, so a direct caller below a park is still there.
   - *The context moves.* A process resumed on another worker finds `%p` stale: after any call
     that may have parked, generated code reads the worker's context again from a word of the
     thread's control block glibc keeps for split stacks (`%fs:0x70`, `ctx_of`, written once per
     thread by `note_context!`). On aarch64, with no such word, a process stays on the worker it
     first ran on. Pinned at first, `net` was five times slower.
   - *Repeated and long rests out of line.* The core repeats a `seq` under every branch that
     reaches it, and a `match` is a decision tree; written in line, `show_all` was one function of
     49 MB. A repeated `seq`, or one whose rest is long, is a function of its own called with what
     it needs, and identical ones are one body (`finish`), as continuations were.
   - *Pinning objects, not chunks.* With the native stack read, pinning whole chunks kept every
     collection's allocation chunk, so nothing young died (`tree` spent three quarters of its time
     collecting). Now a chunk a word falls in is walked and only the objects a word points into
     are marked (bit 2 of the info) and kept; the gaps become fillers. Allocation chunks are
     16 KB in direct style, to-space a chain of them, and a collection is asked for when a
     budget's worth, or twice what the last kept, has been allocated (`ctx_gc_at`).
   - *Segmented stacks.* A process starts on a 256 KB slot of an arena (8 MB for a program that
     can reach deep C, and for the first process), a quarter of it its stack of frames, which
     cannot move. A function entered too near the floor is called again on a new segment
     (`segment_call!`, `dream_call_on`), its answer the answer of the call that ran low; the
     collector reads every segment. Fifty thousand parked processes fit under `ulimit -v`, and a
     recursion as deep as a compiler's still runs, overflow being the chain passing 256 MB (1 GB
     for the first process). A bridge checks the stack of frames' floor before it pushes.

   Measured against code that jumps on the same machine (ms, best of three):

   | bench | CPS | direct | C++ |
   |---|---|---|---|
   | tree | 69 | 121 | 106 |
   | maps | 604 | 381 | 41 |
   | sorts | 370 | 330 | 64 |
   | recs | 470 | 521 | 5 |
   | strs | 133 | 117 | 27 |
   | procs | 150 | 259 | - |
   | fanout | 17 | 22 | - |
   | net | 104 | 122 | - |

   And the workload that matters most: native `dreams` compiling `mind` takes 1.81 s in direct
   style against 2.21 s (7.25 s CPU against 7.95; the VM takes 2.84 s), the image byte for byte
   the same, which is why direct style is the default with four of the eight behind.

   What is left between them is the conservative stack: a frame's dead slot still points at
   what it held, and in `tree` that keeps whole subtrees alive through a collection -- 71 MB
   copied where code that jumps copies 16 KB. Precise stack maps (LLVM's statepoints) are the
   answer to that, and the next thing here.
5. **The runtime's own machine functions** -- `enter!`, `apply!`, the parking natives, `spawn!`,
   the update frames -- in direct style, and the CPS ones removed.
6. **Then the gains a C++ compiler has and this does not yet:** strictness analysis, so that most
   arguments are passed evaluated and most thunks are never made; integers and floats unboxed in
   registers where a function's signature or its strictness allows; and tables written as data
   rather than as functions that build them.

   The first of these, for records of floats (2026-11-07), taking `recs` from 77 ms to 45:

   - **`xs.[0]` on a cell in hand is its head** (`core.getting`). It is how `list.map` and
     `list.forced` read an element, and it went through the library's general walk of a list
     (`list_at`), which was a fifth of `recs` on its own and is a few percent of `sorts`.
   - **A record of floats holds their bits.** Kind 18 (`kind_record_f` in rt/main.dr) is a record
     whose fields are raw doubles: the same header -- count, then id -- so that `type_of`, a
     `match` on the record and everything that reads the id see a record, and a collector that
     copies it and does not scan it, as a float. A record is made so when every field is
     evaluated and every one is a float: generated code tests that as it makes one
     (`machine.raw_floats`, inline, so that a float boxed a few instructions before is seen to
     be one) and `record_of!` does the same at run time. Whatever reads a field as a value --
     `match_at!`, `.[i]`, `record_fields!`, a `set` -- boxes it again (`record_word!`), and a
     `set` of anything but a float makes the record ordinary again first. Nothing outside the
     runtime and the code generator knows: the wire, `show`, equality and comparison all go
     through `record_fields!`.
   - **A strict constructor is the record made where it is called** (`core.strict_constructor`):
     `P.make a b c d` on a record whose fields are all strict -- a field typed as a scalar is --
     evaluates its arguments and makes the record in line, rather than calling a function that
     forces them again.
   - **A tree of doubles is done in doubles.** An eager tree (`Rhs.eager`) whose leaves are all
     floats, or fields of a record of them, is done first with nothing but double arithmetic --
     no integer twin computed beside it, no select between the two, no overflow test --
     and only a tree with an integer in it, or a leaf that is not a float when it runs, takes
     the general way (`machine.all_doubles`). Types are gradual, so this is a guard and not a
     promise, the same as the JIT's use of a signature.
   - **A tree forced at once is forced only where it could not be done** (`machine.eagerly_then`).
     The suspension made on the slow path was entered after the join, so the number made on the
     fast one was tested for being evaluated too.
   - **The context is read as memory nothing else can see** (`machine.ctx_of`). As
     `asm sideeffect` it was a write of all memory as far as LLVM knew, and a store just made was
     loaded again on the other side of it.

   Then three that every program has (the same day):

   - **The context in a slot of each function's own** (`%ctxs`, `machine.ctx_of`): `%p` stored at
     entry, the thread's value stored after each call that may have parked, and LLVM's mem2reg
     makes the joins. Read again from the thread in every block after any such call, the heap
     pointer was loaded through a pointer LLVM could not tell was the same one at each allocation.
   - **Collections spaced at three times what survived** (rt `collect!`), as the VM's majors are;
     at twice it, a heap that only grows was copied half a byte for every byte made.
   - **x86-64-v2 as the target CPU** (`aot_object.cpp`), and `prim.popcount` as `llvm.ctpop`: a
     map's slot is a popcount of its bitmap, which on the first x86-64 was a dozen instructions
     at every level a lookup went down.

   | bench | before | after | C++ |
   |---|---|---|---|
   | tree | 121 | 102 | 106 |
   | maps | 405 | 363 | 40 |
   | sorts | 349 | 271 | 62 |
   | recs | 77 | 44 | 5 |
   | strs | 117 | 86 | 27 |

   `maps` is what is furthest: a map path-copied as it is built is a new branch at every level
   for every insert, and the whole of it copied at every collection, where C++ writes one table
   in place. A collector with a nursery, and a map written in place where it is used linearly
   (as a trunk is), are what would close it.

7. **Generations** (2026-11-08). A collection copied a process's whole heap, and a heap that
   lives was copied again at every one: a third of a native self-compile was the collector.
   Now most collections are minor ("generations" in rt/main.dr):

   - **The nursery has an address space of its own**, reserved once (16 GB, less under
     `ulimit -v`, `DREAM_NURSERY_MB`; huge pages where the kernel gives them), and every chunk
     allocation goes on in comes from it. Whether a word is young is a subtraction and a
     comparison (`in_nursery!`). The first version sorted the nursery's chunks and searched them,
     and could not tell a young thunk from an old one as it was updated: 232,000 words
     remembered at every minor collection of `tree`.
   - **What survives is old**: copied to chunks outside the nursery that stay where they are
     until a major collection, when the old have grown to three times what the last major kept,
     and for a census. Segments a message or a spawn was copied into are old from the start.
   - **A write into what may be old is remembered**: the word written, not its object, so that
     an array forced element by element is each element once. Compiled code tests where the
     thunk it updates is, in line, and calls out (`@cold_remember_value`) only for one outside
     the nursery; `let rec` patches and the runtime's own writes (`frame_update!`, the raises,
     `array_store!`) do the same.
   - **A chunk a stack pins stays the nursery's**, and a word of to-space or of an old object
     that points into it is remembered as it is moved (`evacuate_kept_at!`), so the collection
     that does copy it finds the word. A major collection pins in old chunks too, and those go
     back to the old list (`kept_chunks!`): put on the nursery's, the next minor collection
     freed them with what was pinned in them.
   - **The nursery's size follows survival**, per process: four times as large while half of it
     survives, twice while a quarter does, half while a sixteenth or less does, 2 MB to 256 MB,
     and never less than twice the stack, which a collection reads word by word. A fixed 8 MB
     was a win for `maps` and `tree` and a loss of a third for `strs` and `sorts`, whose lists
     live.
   - **`DREAM_GC_VERIFY=1`** checks after each minor collection that nothing old points into the
     nursery at what was not pinned, and names what did: that is how both bugs above were found.
     `DREAM_GC_FULL=1` makes every collection major, to measure against.

   Pin candidates are sorted by radix now, not Shell's sort: a collection that landed in a deep
   recursion read 1.3 million words, and sorting them was most of `strs`.

   | bench | before | after | C++ |
   |---|---|---|---|
   | tree | 102 | 97 | 104 |
   | maps | 363 | 280 | 42 |
   | sorts | 271 | 253 | 63 |
   | recs | 44 | 42 | 5 |
   | strs | 86 | 97 | 28 |
   | native `dreams` compiling `mind` | 1.72 s | 1.50 s | |

   `strs` is where its collections land against its live peak, which a nursery four times as
   large happens to reach.

   What `recs` spends now is the list around the records -- `list.map`'s suspension of each
   element and of the rest, which `list.forced` then walks -- about as much as the arithmetic.
   A strict map, a loop over an array or a trunk that writes as it goes, is what C++'s 5 ms is.

## Risks

- **Conservative pinning keeps too much.** A long-lived pointer on the stack into the nursery's
  chunk pins the chunk, and the collector cannot reclaim the rest of it. Measured by the bytes kept
  in pinned chunks per collection; the answer if it is too much is smaller chunks, then statepoints.
- **Reserved stacks and many processes.** 80,000 processes at 64 MB each is 5 TB of address space,
  which a 47-bit address space holds; committed memory is what each process touched. A process
  that recursed deep once keeps those pages committed until it ends, unless it is given them back.
- **C calling back.** A callback runs on the stack of the process that called C, which is what the
  runtime arranges now with `move_stack!`; with native stacks it is simply that process's stack.
