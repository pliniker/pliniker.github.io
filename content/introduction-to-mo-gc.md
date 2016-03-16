Title: An Experiment in Pauseless Garbage Collection
Date: 2016-03-13 21:00
Category: Rust
Tags: mo-gc, rust, gc
Slug: mo-gc-intro
Authors: Peter Liniker
Summary: Introduction to mo-gc

_Introducing mo-gc, a garbage collector implemented in Rust_

> Mo-gc avoids mutator pauses by writing stack root reference count increments and decrements to a
> journal. The journal is read concurrently by a garbage collection thread that keeps a map of
> objects and their absolute reference counts. The object map is divided into young and mature
> generations and collection is done in parallel using mark and sweep.
>
> This project aims first to be an experiment in the scalability of the journaling approach and
> secondly, if successful, a long term project to build towards language runtimes written in the
> Rust programming language.

## Summary of results

The garbage collector works and the theory is sound, with caveats.

But first, a note on comparing the performance of this implementation directly to other mainstream 
language garbage collectors: at this point this implementation is too immature to warrant direct 
comparisons. The author has not benchmarked any other runtimes since it is very difficult to
compare like for like without establishing contexts for comparison and no contexts have been
chosen yet.

Instead, I will make some general statements about the mo-gc implementation successes and 
its shortcomings and how they might be overcome.

1. The journal itself is a success and appears to scale, at least on x86(32 and 64). Writing to
   the journal adds roughly 25% to the cost of allocating a 64 byte object on the heap which
   seems an acceptable tradeoff for pauselessness.

2. The parallel mark and sweep phases and the journal itself are sufficiently performant that the
   throughput bottleneck in the system is very evident: _processing_ the journal into the object map is
   currently single-threaded because insertion into the map is not concurrent.<br/><br/>
   With a mutator thread allocating new objects in a tight loop, the GC thread's throughput is about
   half the rate at which they are allocated.<br/><br/>
   If object map insertion could be done in parallel on multiple threads, throughput scalability
   would improve greatly.

3. The object map is implemented using a bitmapped trie with compressed nodes and a path cache.
   Indeces are the object addresses and they are mapped to metadata including the object reference
   count. This was the author's first Rust code and should be forgiven.<br/><br/>
   The use of the trie might also be improved on: while there is a trie path cache, on average, 
   each object lookup requires multiple pointer indirections.<br/><br/>
   It may be faster, though possibly more memory hungry, to maintain an array of reference counts and
   a bitmap for mark flags of multiple objects in each leaf value. This would reduce trie pointer
   hops, making insertion and iteration faster.

4. Mo-gc retains the default Rust allocator, jemalloc, rather than implementing its own allocator.
   The object map essentially duplicates jemalloc's internal radix trie, increasing the number of
   clock cycles for dropping dead objects. Maintaining a separate object map also increases memory
   requirements.


```
#!rust
extern crate mo_gc;

use mo_gc::{Gc, GcRoot, GcThread, Trace, TraceStack};
```

## Contents

### Summarize the problem space addressed and mo-gc
### Define the problem spaces
### Describe the specific problem space, specific to Rust as it is today
### Outline how mo-gc addresses the problem
### Details of how mo-gc works with sample code

journal
bitmaptrie
generational
parallel mark and sweep

### Examples of how the mutator uses GcRoot and Gc
### Data structures

Use of `Gc` should be reasonably straightforward. Describe a Vec, tree, queue?

Use of `GcAtomic` is more speculative.

### Remaining problems

While in the mark phase, marking leads the journal, allowing possible gaps in marked objects.
Journal must be read after marking to catch rooted unmarked objects.

Journal is processed on a single thread.

### Future improvements

Parallelize journal processing.

Trie use efficiency improvement: right shift the address more and store a bitmap of multiple
addresses.

### References

[1]: http://researcher.watson.ibm.com/researcher/files/us-bacon/Bacon03Pure.pdf
[2]: http://www.cs.virginia.edu/~cs415/reading/bacon-garbage.pdf
[3]: http://fitzgeraldnick.com/weblog/60/
[4]: https://github.com/Manishearth/rust-gc
[5]: http://blog.rust-lang.org/2015/08/14/Next-year.html
[6]: https://github.com/rust-lang/rust/pull/11399
[7]: https://github.com/rust-lang/rfcs/issues/415
[8]: https://github.com/rust-lang/rust/issues/2997
[9]: http://mechanical-sympathy.blogspot.co.uk/2011/09/single-writer-principle.html
[10]: https://github.com/michaelwoerister/rs-persistent-datastructures
[11]: http://aturon.github.io/blog/2015/08/27/epoch/
[12]: https://www.youtube.com/watch?v=QcwyKLlmXeY
[13]: https://blog.mozilla.org/research/2014/08/26/javascript-servos-only-garbage-collector/
[14]: http://blog.pnkfx.org/blog/2015/10/27/gc-and-rust-part-0-how-does-gc-work/
[15]: http://blog.pnkfx.org/blog/2015/11/10/gc-and-rust-part-1-specing-the-problem/
[16]: http://blog.pnkfx.org/blog/2016/01/01/gc-and-rust-part-2-roots-of-the-problem/
[17]: http://www.hboehm.info/gc/tree.html
