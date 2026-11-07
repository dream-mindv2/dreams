# The AOT compiler

`dreams --aot -o app FILE` (and `mind build --aot`, `[build] aot = true`) makes
a native executable that needs no interpreter and no `libdream.so`. This is a
design, and a log of how far it has got; nothing below is built until the log
at the end says so.

## What is fixed, and what is not

The input is a `.dream` image, and **the image's meaning is the only thing the
AOT shares with the VM**: what a program prints and which errors it raises. Its
representation of values, objects, frames, thunks, processes and collection are
the VM's own business and are deliberately not inherited. Nothing here is
chosen because `value.hpp` or `interp.cpp` does it that way. The oracle is the
recorded output of `dream/tests/programs` and `examples/`, not the VM's insides.

Three decisions were made by asking:

- **The runtime is compiled Dream wherever it can be.** Collector, scheduler, IO,
  bignums, regex and the rest are Dream source. C++ is allowed only for what
  actually needs it, and the burden of proof is on the C++: being there already
  in the VM is not a reason.
- **Code generation goes through LLVM IR, as text, written by Dream.** The VM's
  own LLVM turns that into an object file (a native on `std.vm`), so a user
  needs no clang.
- **Dream writes the executable.** No system linker.

## The pipeline

```
.dream image -> aot.image (read) -> aot.core (typed, lambda-lifted IR)
             -> analyses (strictness, unboxing, escape)
             -> aot.llvm (IR text) -> vm native (object) -> aot.link (executable)
```

The VM's nodes are a program to be analysed, not a template to expand. Flags
such as `STRICT` and hints such as `ITYP` are inputs to the analyses.

## What a build keeps

A native program is mostly the runtime and the library, and those are the same in every
program, so a build makes them once and keeps them in `DREAMS_AOT_CACHE` (`~/.cache/dream/aot`
by default; `0` for none):

- **The library part** (`machine.lib_part`, `lib-*.wire`): the whole library translated and
  written first and by itself, so its atoms, strings and symbols are numbered the same for every
  program, with the state the program's translation goes on from and the runtime as the dialect
  translates it. Keyed by the compiler, the library, the runtime and the machine.
- **Compiled parts** (`*.o`): the runtime and the library stand between `; dream: cached`
  markers in the IR, and the splitter gives them parts of their own, the same text each time,
  kept under the SHA-256 of their text, LLVM's version and the level (dream/src/aot_object.cpp).
- **The kept objects merged** (`link.merged_part`, `merged-*.wire`): read and numbered once,
  first, so a link reads and merges only the program's own objects after them.

Every function and datum is a section of its own, and the linker lays out only what is reached
from the sections that are not (`live_sections`), so an executable holds what it uses of all
that: `01_basics` is 390 KB. A warm build of a small example is about a second and a half on the
VM, against two before and nine seconds of LLVM's CPU on one core before parts.

## The execution model

An STG-style machine, because laziness, cheap processes and unbounded recursion
are the three things a generated program must do, and this makes all three
ordinary:

- **Every heap object starts with a pointer to static info**: its entry code and
  its pointer layout. Entering a value is a jump. The collector reads layouts
  from the info and has no switch over object kinds, so a new kind of closure
  costs the collector nothing.
- **A thunk or closure is flat**: its code and exactly the values it reads. No
  frames exist on the heap, so a suspension cannot pin what it does not read.
- **Each process has its own growable stack**, separate from the machine stack
  and holding only activation records with their own info. Every generated
  function is `tailcc` and every call to generated code is `musttail`, so the
  machine stack never grows. Roots are therefore exact, and parking a process is
  saving a stack pointer.
- **Every generated function has one signature, all in registers.** Growing a
  `tailcc` function's stack-argument area through `musttail` is not safe: on LLVM
  21 x86-64 at `-O2`, a function that grew it on one path adjusted `rsp` on the
  other path without the matching `sub`, and the program exited with a corrupt
  status after printing the right answer. With no stack arguments there is no
  area to grow, and that case exits cleanly. Six words is what x86-64's `tailcc`
  has in registers, so it is the limit on both architectures; what does not fit
  goes on the process stack.
- **A native is generated code.** Nothing forces by nesting: an operation that
  needs a value forced pushes a return and enters it, so a blocked or preempted
  process needs no retry protocol.
- **Unboxed where the analysis proves it.** A worker takes raw integers and
  doubles in registers when strictness and the checks allow; its wrapper is what
  unknown callers reach. Integer overflow still reaches bignums.

## The runtime dialect

A collector cannot allocate, and cannot be lazy. Runtime source is therefore
written in a dialect of Dream: ordinary syntax, compiled by `dreams` to an image,
then by the AOT with different rules. Every value is a raw 64-bit word, evaluation
is eager, calls are direct, and memory is reached through a host module of
primitives (`load64`, `store64`, ..) that only the AOT implements. The AOT refuses
anything in it that would allocate or suspend: a list, a closure, a thunk. Using
a host module means no VM or seed change is needed to add a primitive.

Library code that does not need this (bignums, regex, formatting) is ordinary
Dream.

## What does not carry over

- **`vm.open_image!`, `eval_image!` and `image .. from ..` load bytecode at run
  time**, and there is no interpreter. A program using them is refused with a
  diagnostic. This includes `dreams` itself, which runs `comp` that way.
- **C++ reaches a binary only if the program uses it.** A program that imports
  nothing needing C++ contains none, so `aot/link.dr` will have to take more than
  one object, and a program that does use it still needs no `libdream.so`.
- **libc stays shared**, as it does for the release VM: `std.ffi` needs `dlopen`,
  and macOS allows nothing else.
- **`dream --debug`, `--profile` and `--stats`** do not apply to a binary.

## Order of work

Each step ends with more of `dream/tests/programs` passing under the AOT, which
is the measure of progress.

1. The object native, the executable writer, and the dialect: a program with no
   runtime prints and exits.
2. The collector and the core machine: thunks, closures, integers, strings, lists.
3. Records, unions, maps, floats, bignums, errors; the builtins table.
4. Processes, the scheduler and non-blocking IO.
5. The analyses: strictness, unboxing.
6. `std.os`, `std.net`, `std.tls`, `std.ffi`, then `std.tensor`. Each native is
   asked whether it needs C++. The expected answers are the outside libraries
   (OpenSSL, SChannel, OpenCL, GTK) and possibly the tensor kernels, whose AVX2
   inner loops are to be measured in Dream before being kept in C++.
7. `mind build --aot`, a manifest setting, macOS and aarch64.

## Log

**2026-11-01: step 1.** `dreams --aot` and `mind build --aot` (`aot = true` in
`[build]` or a profile) work, for the runtime dialect only: `aot/image.dr` reads
an image, `aot/dialect.dr` generates IR, `vm.llvm_object!` (dream/src/aot_object.cpp)
makes the object, and `aot/link.dr` writes the executable, x86-64 Linux only. Held
to its behaviour by `dreams/tests/aot.sh`. **Ordinary Dream does not compile yet**:
it is refused, function by function. There is no runtime, no collector and no
heap; the design above for those is untried.

**2026-11-01: step 2, in part.** Ordinary Dream compiles and runs: `aot/core.dr`
makes evaluation explicit, `aot/machine.dr` writes the IR, `rt/main.dr` is the
collector and the machine in the dialect, and `rt/lib.dr` is the builtins that force
what they are given, in ordinary Dream. Thunks, closures, partial application,
lists, strings, a semispace collector and a 2,000,000-deep recursion work. Not yet:
`try!`, floats, bignums, arrays by index, maps, records beyond allocating them, and
processes. A program using one is refused by name. `dreams/tests/aot_programs.sh`
says how many recorded programs pass, and lists what stops the rest.

One thing the first run taught: an object's `code` is what *entering* it does, and a
closure entered as a value must answer itself. Applying it is a separate field. With
one field, forcing a captured function ran its body with no arguments.

It is not an optimizing compiler yet: every lazy argument is a thunk, as there is no
strictness analysis. `fib 30` takes about what the VM takes.

**2026-11-01: every recorded program.** All 97 programs in `dream/tests/programs` and
`examples/` that have recorded output build native and print what they should
(`dreams/tests/aot_programs.sh`; `share_release` is left out, because it asks about an area
of the VM's that one heap has no use for). The runtime grew floats, bignums, maps, records,
errors with traces, processes on a scheduler, files, sockets, child processes, crypto, trunks,
regex, the wire format, tensors, and TLS over a `dlopen`ed OpenSSL.

**2026-11-01: FFI.** `std.ffi` and `std.foreign` work with no libffi: a C call is generated code
loading registers (`prim.ffi_word!`, `ffi_double!`), a callback is a stub written at run time. A
binary needs libc and libm and nothing else. `dream/tests/ffi/run.sh` holds it to the VM's output.
Only x86-64's calling convention is written.

**2026-11-01: the first analyses.** Each measured alone against the commit before it, with the
workloads of `benchmark/benchmark` (ms, best of three, no supercompiler):

| | fib | sum | collatz | pi | strbuild | mapfilter | bytescan |
|---|---|---|---|---|---|---|---|
| VM (JIT) | 40 | 43 | 64 | 28 | 33 | 22 | 49 |
| before any of this | 84 | 267 | 146 | 200 | 112 | 13 | 116 |
| now | 14 | 35 | 42 | 39 | 73 | 2 | 15 |

and with programs shaped like programs, whose output agrees with the VM's:

| | tree | maps | sorts | recs | strs | procs |
|---|---|---|---|---|---|---|
| VM (JIT) | 691 | 598 | 358 | 745 | 201 | 938 |
| now | 72 | 631 | 528 | 511 | 169 | 144 |

What made the difference, largest first:

- **Strictness** (`strict_masks`, `forced_by` in `aot/core.dr`): a mask per pure function of the
  parameters every path forces, as a greatest fixed point, seen through known local closures
  (`closure_calls`) and builtins. A caller evaluates those arguments, a function forces them on
  entry, and a local that what follows must force is evaluated where it is bound. The cost is
  which of two errors a call with two raising arguments shows. What may perform effects is
  excluded, by the image's marks: the function's flag and, for a lambda, its body node's
  `F_IMPURE`, as the VM's `callee_is_impure` reads them.
- **Asking before entering**: a value already evaluated continues in line with no frame stored
  (`inline_budget`). `entry_force` keeps one copy of a body by re-entering with the value, and
  `Gen.conts` keeps one continuation per `seq`, without which a chain doubled at every link.
- **Reused heap memory** (`take_chunk!`, `round_chunk!`): page faults were a tenth of a run.
- **In-line allocation and cold slow paths**: a call to a slow path made a whole function save
  the callee-saved registers on entry, so those calls are `preserve_mostcc` (`cold_text`).
- **Cheap eagerness** (`Rhs.speculate`): small-integer arithmetic on evaluated operands is done
  rather than suspended, and falls back to the suspension when it is not small.
- **Floats in registers** (`stays_unboxed`): an escape analysis decides whether a float gets a box.
- **Direct calls**: a known closure (`call_closure`), and an unknown one given exactly its arity
  checked in line, without the stack `apply!` takes its arguments on.

Trap: once a function stops allocating, LLVM makes a self-call a real loop and lifts the safepoint's
load out of it, and the process can no longer be killed or collected. That load is volatile.

Found by the second table and not by the first: the scheduler walked every process on every switch
(`procs` was 8.1 s; now a list of those with a timer or descriptor), a process had a 256 MB mapping
where this design says a growable stack (now 32 KB, doubling, `move_stack!`), and `list.sort`
was a lazy merge with a generic comparison (`sorts` was 19.9 s; `sort_prim!` for integer or string keys).

Not done: passing unboxed floats or integers between functions (a worker/wrapper split, which is what
`pi` still lacks), returning records in registers, omitting a thunk's update when it can only be
entered once, stack allocation of what does not escape, and a generational collector, which is what
`maps` and anything with a large live heap would want. Native ran on **one OS thread** then;
it uses every core now (`aot-parallel.md`).

**2026-11-01: released as toolchain v0.3.10** (dreams 0.2.4, std 0.3.4, mind 0.3.5, lucid 0.1.4). `--aot`
works from the Linux x86-64 tarball. It does not yet work on Linux aarch64 or macOS, whose toolchains
carry it only to say so: the linker, the C calls and the runtime's system numbers are x86-64 Linux's.

**Build time and the rest of `std.os`.** A hello-world build went from 7.2 s to 3.9 s and 713 KB to
508 KB. The runtime's two images are kept between builds in `~/.cache/dreams` whatever the working
directory (`cache.shared_key`), since they were most of the cost and never change, and `equal` matches
on one type rather than a pair, which had been a third of the code. `os.replace!` and the `pty_*`
natives are in, so nothing is refused now but what loads bytecode at run time.

**Many threads.** `aot-parallel.md` is the plan and its log: M:N green processes, a heap per process
rather than a stop-the-world collector, no language-level async. A heap per process and workers on every core are built; the log there says what is left.

**2026-11-03: join points, floats across calls, thunks entered once.** Three of the "not done" above,
in `aot/machine.dr`, each A/B'd against the commit before:

- **Join points.** A `seq` whose inner expression cannot leave the function -- only binds, choices,
  raises and answers, which is what a small inlined function often is -- no longer pushes a frame
  and comes back through it. It is compiled in line, each answer a branch to one block whose phi
  takes the value, a double if every branch has one. `num.to_float` in a loop was a frame, an
  indirect jump and a box each time.
- **Workers.** A function whose first three parameters include floats -- used as an operand of
  float arithmetic with another float -- gets a worker, `@..w`, taking those as doubles. A call with
  doubles in hand goes to the worker; the function proper asks at its entry whether its arguments
  are floats and goes on in the worker if so, which is how a closure call or a retry gets there. The
  collector never sees a double: only registers carry them, the worker's safepoint boxes them and
  runs the function proper again, and a frame boxes what it keeps (`store_live`).
- **Thunks entered once.** A thunk whose variable is used once on any path, and that use forces it
  or hands it to a parameter used so in turn (a greatest fixed point over the program), is made with
  a second entry that does not push the update frame or write the hole. Before, updates were up to
  5% of a run (`tree`, `strs`).

| ms, in-program | fib | sum | collatz | pi | strbuild | mapfilter | bytescan |
|---|---|---|---|---|---|---|---|
| before | 18 | 39 | 42 | 38 | 72 | 2 | 16 |
| now | 14 | 25 | 30 | 19 | 67 | 2 | 16 |

`pi` now beats the VM's JIT (28). A self-recursive loop carrying two floats went from 171 ms to 97,
against the VM's 147. Of the programs in `benchmark/native`: `tree` 74 to 65, `sorts`, `recs` and
`strs` 2-3% faster, `maps` the same.

Not built, and why: **returning records in registers** and **stack allocation of what does not
escape**. No program measured here returns a record that is not then stored in a list or a tree,
which needs it on the heap anyway, and what does not escape is mostly floats, which stay in
registers already. Stack allocation would also break the rule `move_stack!` relies on, that nothing
holds an address on a stack.

**2026-11-03: Linux aarch64.** `dreams --aot --target aarch64` (or on an aarch64 machine, nothing at
all) writes an aarch64 executable. What differs is small and named (`aot/target.dr`):

- the triple, `_start` (glibc's own `start.S`), `yield` for `pause`, and the callback's entry and
  stub: eight integer registers rather than six, the record in x16, and the instruction cache
  flushed after a stub is written (`dream_flush_code`), which x86-64 does not need;
- in the runtime, by `prim.arch ()`, a constant LLVM folds: `struct stat`'s mode at 16 rather than
  24, and `struct epoll_event` sixteen bytes rather than a packed twelve;
- an acquire fence where an indirection is followed (`code_ind!`), since a shared thunk's value is
  read after its info and aarch64, unlike x86-64, may reorder two loads;
- in the writer, aarch64's relocations, which patch fields of instructions, an import's stub of
  `adrp`, `ldr` and `br`, and 64 KB pages for a kernel that has them.

A VM writes for another machine only when built with `-DDREAM_AOT_CROSS=ON`, which links both
targets' code generators; a release VM writes for its own. `dreams/tests/aot_cross.sh` runs every
recorded program, the FFI test against the C sample library cross-compiled, and both TLS suites,
built for aarch64 on x86-64 and run under qemu: all pass. qemu on x86-64 keeps x86-64's memory order,
so the fences are exercised only on aarch64 itself.

Found on the way, in the compiler: a `match` of guarded arms lowered everything after a guarded arm
twice, once for its guard failing and once for its pattern, so eighteen of them overflowed the stack.
A pattern that cannot fail (`k if k == ..`) has no second path now (`always_matches` in lower.dr).
