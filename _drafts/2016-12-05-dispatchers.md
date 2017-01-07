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
same virtual machine, in turn run on **n** different CPUs.

These CPUS are:

* ARM Cortex-A57
* Intel Atom N450
* Intel Core2 Duo T8300
* Intel Exxxx
* AMD yyyy

The contents of this section are as follows:

* The Virtual Machine
* The Three Tests
* Single Match Dispatch
* Single Match Unrolled Loop Dispatch
* Tail Call Dispatch
* Computed Goto Dispatch


### The Virtual Machine

### The Three Tests

All three tests are coded in [fixture.rs](https://github.com/pliniker/dispatchers/blob/master/src/fixture.rs)
as hand-coded bytecode sequences for the virtual machine.


### Single Match Dispatch

[switch.rs](https://github.com/pliniker/dispatchers/blob/master/src/switch.rs) compiles to a
[jump table](https://github.com/pliniker/dispatchers/blob/master/emitted_asm/switch_x86_64.s)
implementation:

{% highlight asm %}
```asm`
.LBB0_5:                                # beginning of dispatch loop
    movq    32(%rsp), %rdi              # load address of program Vec
    movl    (%rdi,%rsi,4), %eax         # rsi contains pc; fetch next opcode
    movl    %eax, %ecx                  # eax contains opcode; extract operator byte
    decb    %cl                         # adjust for jump table indexing
    movzbl  %cl, %ecx
    cmpb    $11, %cl                    # bounds check on jump table index
    ja      .LBB0_50
    movslq  (%r8,%rcx,4), %rcx          # r8 contains address of jump table .LJTI0_0
    addq    %r8, %rcx                   # convert offset rcx into an absolute address
    jmpq    *%rcx                       # indirect branch to instruction code
# ....
.LBB0_14:                               # instruction code for OP\_JMP
    shrl    $16, %eax                   # extract branch target adddress
    movq    %rax, %rsi                  # assign to pc
    jmp    .LBB0_46                     # go to the bottom of loop
# ....
.LBB0_45:                               # other instructions just increment the pc
    incq    %rsi
.LBB0_46:                               # bottom of the loop
    incq    %rbx                        # rbx contains counter
    movq    %rbx, 24(%rsp)              # writing the counter back to it's stack location
    cmpq    %rsi, %rdx                  # bounds check on program Vec access
    ja      .LBB0_5                     # all good? start loop over
# ....
.LJTI0_0:                               # jump table
    .long   .LBB0_14-.LJTI0_0
    .long   .LBB0_7-.LJTI0_0
    .long   .LBB0_18-.LJTI0_0
    .long   .LBB0_19-.LJTI0_0
    .long   .LBB0_12-.LJTI0_0
    .long   .LBB0_26-.LJTI0_0
    .long   .LBB0_27-.LJTI0_0
    .long   .LBB0_24-.LJTI0_0
    .long   .LBB0_32-.LJTI0_0
    .long   .LBB0_15-.LJTI0_0
    .long   .LBB0_28-.LJTI0_0
    .long   .LBB0_10-.LJTI0_0
```
{% endhighlight %}

What is notable about this code is that LLVM has optimized it very reasonably. It has viewed
the dispatch routine and the inlined VM instruction code as a whole and allocated registers
appropriately. The little overhead in this example (adjusting the opcode value for indexing into
the jump table by `decb %cl` and storing the counter back to it's stack address with
`movq %rbx, 24(%rsp)`) could be eliminated by some minor source code adjustments. I'm not a
pipeline and superscalar expert so I don't think I could hand code this [any better][7].


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
