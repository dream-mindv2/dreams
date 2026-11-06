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
4. **The code generator.** `machine.dr` writes direct style from the same core program
   (`core.dr` is untouched): forces and calls as calls, thunks as functions that return, `try!` and
   `raise!` through the runtime. Behind `--aot-direct` until the suite passes, then the default.
5. **The runtime's own machine functions** -- `enter!`, `apply!`, the parking natives, `spawn!`,
   the update frames -- in direct style, and the CPS ones removed.
6. **Then the gains a C++ compiler has and this does not yet:** strictness analysis, so that most
   arguments are passed evaluated and most thunks are never made; integers and floats unboxed in
   registers where a function's signature or its strictness allows; and tables written as data
   rather than as functions that build them.

## Risks

- **Conservative pinning keeps too much.** A long-lived pointer on the stack into the nursery's
  chunk pins the chunk, and the collector cannot reclaim the rest of it. Measured by the bytes kept
  in pinned chunks per collection; the answer if it is too much is smaller chunks, then statepoints.
- **Reserved stacks and many processes.** 80,000 processes at 64 MB each is 5 TB of address space,
  which a 47-bit address space holds; committed memory is what each process touched. A process
  that recursed deep once keeps those pages committed until it ends, unless it is given them back.
- **C calling back.** A callback runs on the stack of the process that called C, which is what the
  runtime arranges now with `move_stack!`; with native stacks it is simply that process's stack.
