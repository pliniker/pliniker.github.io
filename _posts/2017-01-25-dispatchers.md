---
layout: post
title:  "Virtual Machine Dispatch Experiments in Rust"
date:   2017-01-25 23:00 EST5EDT
categories: Rust
---

### tl;dr

Computed gotos or tail calls may give a worthwhile advantage on older or low-power architectures
when implementing an FSM or a VM dispatch loop. There are a lot of these around, ARM processors
being ubiquitous. The performance improvement over a single match statement could be up to 20%.

On Haswell and later wide-issue Intel CPUs, it is [claimed][6] that branch predictor performance reduces
the advantage of distributed dispatch points over a single switch and this experiment confirms this.
On such hardware, a single Rust `match` expression will be almost insdistinguishable in performance over
computed gotos or tail calls.

At this time there is no portable way to produce computed gotos or tail call optimization in compiled
machine code from Rust.  This experiment investigates what is possible, even if non-portable or unsafe.

The results are tabluated and graphed in
[this Google Sheet](https://docs.google.com/spreadsheets/d/1qbBt1NgvmLLmYxHlPRZNsXybivQIDVUAdsCNGKmNhos/edit#gid=0).
The project code itself is hosted [on Github](https://github.com/pliniker/dispatchers).

Read on for an explanation!


# Introduction

See the [Wikipedia page][9] for an overview of the higher level topic "Threaded Code."

[Computed gotos][1] are an occasionally requested feature of Rust for implementing threaded interpreters
and finite state machines. A Google search will turn up numerous discussions on interpreted
language mailing lists on converting to computed goto dispatch. GCC and clang both support computed
gotos as an extension to the C language. As a systems language in the same space, it does not seem
unreasonable to wish for support in Rust.

An alternative to explicit computed gotos is exploiting tail call optimization, invoking a jump
instruction to enter the subsequent state or instruction function.

Rust provides neither guaranteed tail calls nor computed gotos.

When computed gotos and optimized tail calls are unavailable, the fallback standard is to use
switch/match statements. It must be noted that a switch/match compiles to a single computed goto,
but it cannot be used to jump to arbitrary points in a function as with the full Computed Gotos
feature.

For a single switch/match, the [most cited][5] paper on the topic describes a worst case 100%
branch predictor prediction failure rate under VM dispatch circumstances, at least for now-old
CPU implementations.

I thought I'd conduct some experiments to get first hand experience of the performance
advantages of computed gotos, and to find out what is possible in Rust.


# Experimental Setup

The experiment consists of three tests executed across four dispatch methods, each implementing the
same virtual machine instruction set, in turn run on five different CPUs.

These CPUS are:

| CPU | System | OS | Architecture/code-name |
|-----|--------|----|------------------------|
| ARM Cortex-A57 | Qualcomm MSM8992 in my Nexus 5x | Android 7.0 | ARM aarch64 |
| Intel Atom N450 | my old HP netbook from 2009 | Ubuntu 16.04 | Intel Pineview |
| Intel Core2 Duo T8300 | my old Dell D830 from 2008 | Ubuntu 16.04 | Intel Penryn |
| Intel Xeon E5-2666 | an EC2 c4.large | Ubuntu 16.04 | Intel Haswell |
| AMD A4-6210 | my HP-21 from 2014 | Windows 10 | AMD Beema |


The next two subsections, *The Virtual Machine* and *The Three Tests* describe the
minimal language VM instruction set and memory model and the three sets of opcode
sequences that exercise branch prediction in different ways respectively.

Following those are the explanations of the four different dispatch methods:
*Single Match Dispatch*, *Single Match Unrolled Loop Dispatch*, *Tail Call Dispatch*
and *Computed Goto Dispatch*.


### The Virtual Machine

The VM is implemented in [vm.rs](https://github.com/pliniker/dispatchers/blob/master/src/vm.rs). Since
dispatch performance is the focus of the experiment, the features supported by the VM are
far below what would be required to implement a useful programming language.

The instruction set allows for a handful of arithmetic operations, comparisons, branches and a
pseudorandom number generator.

Instructions support three types: Integer, Boolean and None. Because of the simplicity of the instruction
set, the None value is also used as an error type. It is not used in the tests.

The memory model is a 256 slot register set. No stack, no heap.

"Bytecode" instructions are fixed 32 bits wide with the low 8 bits forming the operator and the
higher sets of 8 or 16 bits forming register or literal operands.

The code in `vm.rs` is deliberately designed to be dispatch-method agnostic: no default method is
provided, merely the memory model and instruction function definitions. This separation of concerns
should cost no overhead in the world of Rust's cost-free abstractions.


### The Three Tests

All three tests are coded in [fixture.rs](https://github.com/pliniker/dispatchers/blob/master/src/fixture.rs)
as hand-coded bytecode sequences for the virtual machine.


#### Nested Loop

[`fn nested_loop()`](https://github.com/pliniker/dispatchers/blob/master/src/fixture.rs:29)

This test is comprised of one loop inside another. The instruction sequence is very short and
utterly predictable. *The performance of this test should give a baseline performance-high
for CPUS in which they should be able to predict every indirect branch.*


#### Longer Repetitive

[`fn longer_repetitive()`](https://github.com/pliniker/dispatchers/blob/master/src/fixture.rs:59)

This test is only slightly less predictable than *Nested Loop* but the instruction sequence is
somewhat longer. It is essentially *Nested Loop* unrolled a handfull of times with some NOP
instructions added in different patterns among each unroll instance.

This test should fit somewhere inbetween *Nested Loop* and *Unpredictable* in that while it
*is* predictable, it also requires more than basic indirect branch prediction.


#### Unpredictable

[`fn unpredictable()`](https://github.com/pliniker/dispatchers/blob/master/src/fixture.rs:133)

The core of this test is the use of a pseudorandom number generator. On the roll of the pseudo-dice
various sections of code in the loop will be skipped or included. This should make the overall
instruction sequence essentially unpredictable to any branch predictor.

*This test should demonstrate the low point of performance for each CPU with frequent pipeline flushes.*

Direct comparison of this test to the other two tests is complicated by the use of the random
number generator in that there may be overhead in using it that the other two tests do not include.


### Single Match Dispatch

[switch.rs](https://github.com/pliniker/dispatchers/blob/master/src/switch.rs) compiles to a
[jump table](https://github.com/pliniker/dispatchers/blob/master/emitted_asm/switch_x86_64.s)
implementation. For these inline examples I'll pull the x86_64 assembly. The aarch64 assembly
is comparable in instruction type and count; the x86 assembly relies on the stack a bit more
due to the lack of registers.

{% highlight asm %}
#
# Top of the dispatch loop
#
.LBB0_57
    movq    8(%rsp), %rdi
    movl    (%rdi,%r12,4), %ecx
    movzbl  %cl, %eax
    cmpb    $13, %al
    ja      .LBB0_58
    movslq  (%r13,%rax,4), %rax
    addq    %r13, %rax
    jmpq    *%rax
# ...
# OP_JMP, just one of the instruction routines
#
.LBB0_32:
    shrl    $16, %ecx
    movq    %rcx, %r12
    jmp     .LBB0_54
# ...
# Bottom of the dispatch loop
#
.LBB0_53:
    incq    %r12
.LBB0_54:
    incq    %rbx
    cmpq    %r12, %r8
    ja      .LBB0_57
# ....
# The jump table
#
.LJTI0_0:
    .long   .LBB0_32-.LJTI0_0
    .long   .LBB0_8-.LJTI0_0
    .long   .LBB0_29-.LJTI0_0
    .long   .LBB0_24-.LJTI0_0
    .long   .LBB0_30-.LJTI0_0
    .long   .LBB0_23-.LJTI0_0
    .long   .LBB0_28-.LJTI0_0
    .long   .LBB0_58-.LJTI0_0
    .long   .LBB0_58-.LJTI0_0
    .long   .LBB0_58-.LJTI0_0
    .long   .LBB0_11-.LJTI0_0
    .long   .LBB0_14-.LJTI0_0
    .long   .LBB0_40-.LJTI0_0
    .long   .LBB0_33-.LJTI0_0
{% endhighlight %}

LLVM has viewed the VM instruction code and dispatch loop as a whole, allocating registers
efficiently across the whole function.


### Single Match Unrolled Loop Dispatch

[unrollswitch.rs](https://github.com/pliniker/dispatchers/blob/master/src/unrollswitch.rs)
compiles to a series of [jump tables](https://github.com/pliniker/dispatchers/blob/master/emitted_asm/unrollswitch_x86_64.s).
This is identical to the *Single Match* dispatch test, except the loop is unrolled a handful
of times. In addition, when a VM branch instruction is executed and the branch is taken,
control flow jumps to the top of the loop. My idea here was that under tight bytecode loop
conditions, this could effectively unroll the bytecode loop too. The huge disadvantage is
that the VM instruction code is duplicated the number of times of the unroll count. This
cannot be good for the instruction cache hit rate, or certainly would not be for an
interpreter with a high operator count.


### Tail Call Dispatch

LLVM as called by rustc produces TCO assembly for x86_64, arm and aarch64, but only for
release builds. x86 builds will hit the stack limit and could not be included in the
results.

[threaded.rs](https://github.com/pliniker/dispatchers/blob/master/src/threaded.rs) compiles
to a single jump table shared by all the VM instruction functions:

{% highlight asm %}
op_jmp:
    pushq   %rax
    movl    %esi, %eax
    shrl    $16, %eax
    movq    280(%rdi), %rdx
    cmpq    %rax, %rdx
    jbe     .LBB1_3
    movq    264(%rdi), %rdx
    movl    (%rdx,%rax,4), %edx
    movzbl  %dl, %esi
    cmpl    $32, %esi
    jae     .LBB1_4
    movq    8(%rdi,%rsi,8), %r8
    incq    %rcx
    movl    %edx, %esi
    movq    %rax, %rdx
    popq    %rax
    jmpq    *%r8
{% endhighlight %}

As suggested in [this forum discussion][2], we should get six registers for parameter passing
on x86_64. We're using four, keeping `opcode`, `PC` and `counter` off the stack, which is
at least consistent with `switch.rs` and the other implementations. There's a good chance
we could do better but I'm not sure how to go about it.

What is notable is the overhead of pushing and popping `rax` on and off the stack and that LLVM
treats each function as a separate unit with calling convention constraints.


### Computed Goto Dispatch

For this experiment, I wanted to see if I could create a computed goto environment close
to what is possible in [clang and gcc][1]. In order to do that I would have to resort to inline
assembly and, sadly, nightly rustc.

In my first attempt I used inline assembly to populate a jump table with label addresses and
insert `jmp` instructions after each VM instruction block. This produced segmentation faults.
After studying the assembly output from rustc for a while I realized that LLVM could not
intelligently understand that the `jmp` instructions would affect code flow: it was allocating
registers throughout the function with the assumption that code flow would fall all the way
through to the end of the function in sequence. Register allocation varied throughout the
function but my `jmp` instructions disrupted the allocation flow.

The fix for this in [threadedasm.rs](https://github.com/pliniker/dispatchers/blob/master/src/threadedasm.rs)
is to introduce constraints. Each VM instruction block of code must be
prefixed and postfixed with register constraints, pinning variables to specific variables
to keep the allocation flow consistent no matter where in the function a `jmp` instruction
goes.

{% highlight rust %}
#[cfg(target_arch = "x86_64")]
macro_rules! dispatch {
    ($vm:expr, $pc:expr, $opcode:expr, $jumptable:expr, $counter:expr) => {
        $counter += 1;
        let addr = $jumptable[operator($opcode) as usize];

        unsafe {
            // the inputs of this asm block force these locals to be in the
            // specified registers
            asm!("jmpq *$0"
                 :
                 : "r"(addr), "{r8d}"($counter), "{ecx}"($opcode), "{rdx}"($pc)
                 :
                 : "volatile"
            );
        }
    }
}
{% endhighlight %}

The optimized assembly output is the most compact of any of the dispatch methods and
overall, this code outperforms the other methods.

{% highlight asm %}
goto_jmp:
    movl    %ecx, %eax
    shrl    $16, %eax
    movq    24(%r12), %rdx
    cmpq    %rax, %rdx
    jbe     .LBB0_72
    movq    8(%r12), %rcx
    movl    (%rcx,%rax,4), %ecx
    movzbl  %cl, %esi
    cmpl    $31, %esi
    ja      .LBB0_67
    incq    %r8
    movq    24(%rsp,%rsi,8), %rsi
    movq    %rax, %rdx
    jmpq    *%rsi
{% endhighlight %}


## Test Results

Result data is tabulated and charted in
[this Google Sheets document](https://docs.google.com/spreadsheets/d/1qbBt1NgvmLLmYxHlPRZNsXybivQIDVUAdsCNGKmNhos/edit#gid=0).

With apologies for the quality of the embedded chart images due to Google Sheets limitations,
the chart that best illustrates the data is _ImprovementOverSwitch_. Do check out the link
above to interact with the spreadsheet and charts directly.

![Improvement over Switch](https://docs.google.com/spreadsheets/d/1qbBt1NgvmLLmYxHlPRZNsXybivQIDVUAdsCNGKmNhos/pubchart?oid=484835110&format=image){:class="img-responsive"}

This chart illustrates the ratio of VM instructions per second of each other dispatch method
against `switch.rs`, normalizing the performance of `switch.rs` for each test to 1.0.

The `unrollswitch.rs` figures are shown in shades of blue, `threaded.rs` in yellow and
`threadedasm.rs` in shades of green.

* In summary, `threadedasm.rs` performs best overall with `unrollswitch.rs` also doing well,
though it is assumed that that is largely because the virtual machine is very small and
fits into I-cache.
* Taking the _Unpredictable_ test as most real-world-lie, on Haswell and newer Intel architectures,
dispatch method is not significant performance differentiator. On low-power architectures - ARM,
Intel and AMD - it continues to make a difference.

Again, go to the spreadsheet to see this chart directly for a better view; this next chart
illustrates the absolute performance of each method and test in cycles per VM instruction.
Color coding remains the same as the earlier chart.

![Cycles per VM instruction](https://docs.google.com/spreadsheets/d/1qbBt1NgvmLLmYxHlPRZNsXybivQIDVUAdsCNGKmNhos/pubchart?oid=605750577&format=image){:class="img-responsive"}

* In each case, _Unpredictable_ results are consistently worse than _Nested Loop_. It is
illustrative to compare _Longer Repetitive_ results for `threadedasm.rs` to the other two tests,
though: the Intel CPUs have identical performance patterns, showing a stepping up in cycle count
from _Nested Loop_ to _Longer Repetitive_ to _Unpredictable_ whereas ARM and AMD results
show _Longer Repetitive_ performing similarly to or worse than _Unpredictable_.
* I am not sure what this means, but it may be possible to say that Intel has deliberately
targeted branch prediction optimization at threaded code indirect jump patterns, whereas ARM
and AMD branch predictors may have simpler indirect branch pattern recognition.


## Conclusions

Tail call dispatch comes with function-call instruction overhead that varies by architecture.
It is also possibly hindered by the inability of LLVM to holistically optimize
all interpreter instruction functions. These combine to add a few instructions of overhead
compared to the inline-assembly single-function `threadedasm.rs` code.
In addition, Rust and LLVM do not TC-optimize for 32bit
x86 or debug builds, making this a non-option as long as Rust does not explicitly support TCO.

If the FSM or VM is particularly small, unrolling the dispatch loop may be an option as it does
give a performance increase under _Unpredictable_ circumstances.

With respect to computed gotos for threaded dispatch, in my opinion it should be possible to
encapsulate the inline assembly in macros that could be imported from a crate. Because inline
assembly is required, this cannot currently be done in stable Rust. Compiler support beyond
inline assembly and possibly procedural macros should not be required.

It seems there may be [some work][10] involved before inline assembly can be stabilized.

If targeting modern high-performance Intel architectures, dispatch method may make little
difference. Any other architecture, however, may benefit from dispatch method optimization.


## Further Reading

* [Computed goto for efficient dispatch tables][1] - Eli Bendersky, 2012
* [How can I approach the performance of C interpreter that uses computed gotos?][2] - Discussion on Rust Users forum, 2016
* [Gotos in restricted functions][3] - Discussion on Rust Internals forum, 2016
* [The Structure and Performance of Efficient Interpreters][5] - Ertl and Gregg, 2003
* [Branch Prediction and the Performance of Interpreters][6]- Rohou, Swamy and Seznec, 2015
* [LuaJIT 2 beta 3 is out: Support both x32 & x64][7] - Mike Pall, Discussion on Reddit, 2010
* [Threaded Code][9] - Wikipedia article
* [Github rust-lang/rust][10] - AA-inline-assembly tagged issues

[1]: http://eli.thegreenplace.net/2012/07/12/computed-goto-for-efficient-dispatch-tables
[2]: http://users.rust-lang.org/t/how-can-i-approach-the-performance-of-c-interpreter-that-uses-computed-gotos/6261/4
[3]: https://internals.rust-lang.org/t/gotos-in-restricted-functions/4393
[5]: http://www.jilp.org/vol5/v5paper12.pdf
[6]: https://hal.inria.fr/hal-01100647/document
[7]: https://www.reddit.com/r/programming/comments/badl2/luajit_2_beta_3_is_out_support_both_x32_x64/c0lrus0/
[8]: https://github.com/rust-lang/rust/issues/14375
[9]: https://en.wikipedia.org/wiki/Threaded_code
[10]: https://github.com/rust-lang/rust/issues?q=is%3Aopen+is%3Aissue+label%3AA-inline-assembly
