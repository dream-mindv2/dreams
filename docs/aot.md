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
