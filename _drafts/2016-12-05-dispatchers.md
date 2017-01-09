---
layout: post
title:  "Virtual Machine Dispatch Experiments in Rust"
date:   2016-01-23 12:00 EST5EDT
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

The results are tabluated and graphed in [this Google Sheet](https://docs.google.com/spreadsheets/d/1qbBt1NgvmLLmYxHlPRZNsXybivQIDVUAdsCNGKmNhos/edit#gid=0). Read on for an explanation!


# Introduction

[Computed gotos][1] are an occasionally requested feature of Rust for optimizing interpreter virtual
machines and finite state machines.  A Google search will turn up numerous discussions on interpreted
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

Instructions are fixed 32 bits wide with the low 8 bits forming the operator and the higher sets of
8 or 16 bits forming register or literal operands.

The code in `vm.rs` is deliberately designed to be dispatch-method agnostic: no default method is
provided, merely the memory model and instruction function definitions. This separation of concerns
should cost no overhead in the world of Rust's cost-free abstractions.


### The Three Tests

All three tests are coded in [fixture.rs](https://github.com/pliniker/dispatchers/blob/master/src/fixture.rs)
as hand-coded bytecode sequences for the virtual machine.


#### Nested Loop

This test is comprised of one loop inside another. The instruction sequence is very short and
utterly predictable. *The performance of this test should give a baseline performance-high
for CPUS in which they should be able to predict every indirect branch.*


#### Longer Repetitive

This test is only slightly less predictable than *Nested Loop* but the instruction sequence is
somewhat longer. It is essentially *Nested Loop* unrolled a handfull of times with some NOP
instructions added in different patterns among each unroll instance.

This test should fit somewhere inbetween *Nested Loop* and *Unpredictable* in that while it
*is* predictable, it also requires more than basic indirect branch prediction.


#### Unpredictable

The core of this test is the use of a pseudorandom number generator. On the roll of the pseudo-dice
various sections of code in the loop will be skipped or included. This should make the overall
instruction sequence essentially unpredictable to any branch predictor.

*This test should demonstrate the low point of performance for each CPU with frequent pipeline flushes.*

Direct comparison of this test to the other two tests is complicated by the use of the random
number generator in that there may be overhead in using it that the other two tests do not include.


### Single Match Dispatch

[switch.rs](https://github.com/pliniker/dispatchers/blob/master/src/switch.rs) compiles to a
[jump table](https://github.com/pliniker/dispatchers/blob/master/emitted_asm/switch_x86_64.s)
implementation:

{% highlight asm %}
```asm`
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
```
{% endhighlight %}

What is notable about this assembly listing is that LLVM has viewed the VM instruction code
and dispatch loop as a whole, allocating registers efficiently. Compare against the later
tail call dispatch test.


### Single Match Unrolled Loop Dispatch

explain


### Tail Call Dispatch

The tail-call optimized code in threaded.rs produces this pattern but as TCO is not
a guaranteed feature, some builds such as 32bit x86 and debug builds do not convert
the tail calls to jumps resulting in recursion stack overflow.

Another disadvantage is that LLVM treats each opcode function independently of the
others, including return value overhead, whereas the switch based code can inline
all opcode functions and optimize them as one unit, making much better use of registers.


### Computed Goto Dispatch

explain


## Test Results

[See Google Sheets document](https://docs.google.com/spreadsheets/d/1qbBt1NgvmLLmYxHlPRZNsXybivQIDVUAdsCNGKmNhos/edit#gid=0)


## Conclusions

TCO dispatch comes with function-call overhead and the inability of LLVM to holistically optimize
all interpreter instruction methods, often largely negating any benefit of threaded dispatch.
In addition, Rust and LLVM do not TC-optimize for 32bit x86 or debug builds, making this currently
a non-option.

In my opinion it should be possible to encapsulate threaded dispatch in macros that could be
imported from a crate. Because inline assembly is required, this cannot currently be done
in stable Rust.

On Haswell and newer Intel architectures, dispatch method is no longer a significant performance
differentiator. On low-power architectures - ARM, Intel and AMD - it continues to make a difference.


## References

* [Computed goto for efficient dispatch tables][1] - Eli Bendersky, 2012
* [How can I approach the performance of C interpreter that uses computed gotos?][2] - Discussion on Rust Users forum, 2016
* [Gotos in restricted functions][3] - Discussion on Rust Internals forum, 2016
* [Pretty State Machine Patterns in Rust][4] - Andrew Hobden, 2016
* [The Structure and Performance of Efficient Interpreters][5] - Ertl and Gregg, 2003
* [Branch Prediction and the Performance of Interpreters][6]- Rohou, Swamy and Seznec, 2015
* [LuaJIT 2 beta 3 is out: Support both x32 & x64][7] - Mike Pall, Discussion on Reddit, 2010

[1]: http://eli.thegreenplace.net/2012/07/12/computed-goto-for-efficient-dispatch-tables
[2]: http://users.rust-lang.org/t/how-can-i-approach-the-performance-of-c-interpreter-that-uses-computed-gotos/6261/4
[3]: https://internals.rust-lang.org/t/gotos-in-restricted-functions/4393
[4]: https://hoverbear.org/2016/10/12/rust-state-machine-pattern/
[5]: http://www.jilp.org/vol5/v5paper12.pdf
[6]: https://hal.inria.fr/hal-01100647/document
[7]: https://www.reddit.com/r/programming/comments/badl2/luajit_2_beta_3_is_out_support_both_x32_x64/c0lrus0/
[8]: https://github.com/rust-lang/rust/issues/14375
