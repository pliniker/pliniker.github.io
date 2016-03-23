Title: An Experiment in Garbage Collection
Date: 2016-03-13 21:00
Category: Rust
Tags: mo-gc, rust, gc
Slug: mo-gc-intro
Authors: Peter Liniker
Summary: Introduction to mo-gc



**Preliminary results for [mo-gc](https://github.com/pliniker/mo-gc), a garbage collector
written in Rust.**

> Mo-gc is an experiment in garbage collection written in the Rust programming language.
>
> Instead of scanning the stack, the mutator writes reference count
> increments and decrements to a journal. The journal is read concurrently by a garbage
> collection thread that keeps a map of objects and their absolute reference counts. The object
> map is divided into young and mature generations and collection is done with parallellized
> mark and sweep phases.
>
> The journal is a type of snapshot-at-beginning write barrier and this project
> is an experiment in the feasibility, limitations and scalability of this approach.
>
> A second aspect of the experiment is to gauge the possible performance of a GC in and for
> Rust that does not depend on rustc, Rust runtime or LLVM awareness of a GC.



# Contents

* [Motivation: Hosting Languages](#rt)
* [Garbage Collection and Rust](#gcrust)
* [Inside mo-gc](#inmo)
* [Using mo-gc](#usemo)
* [Implementing Data Structures](#ds)
* [Summary of Results](#res)
* [Coherence](#conc)
* [Throughput](#thro)
* [Next Directions](#rem)
* [Further Reading](#read)



### <a name="rt"></a>Motivation: Hosting Languages

If a higher level programming language is not hosted in itself, there is a very high chance that
it is written in C or C++. By a degree of necessity, lower level interaction or optimized
extensions of those runtimes must also be in C or C++, perpetuating the pervasiveness of
these two languages.

Mo-gc is motivated by the safety benefits of Rust over C and C++ to explore a programming
language runtime written in Rust. Having familiar and attractive dynamic or scripting languages
written in Rust may lead to wider Rust adoption, spreading the safety.

A garbage collector is a fundamental requirement for most languages. It makes some sense to begin
there rather than deferring the problem of memory management.



### <a name="gcrust"></a>Garbage Collection and Rust

As [pnkfelix][23] has [already][14] [written][15] [a thorough][16] introduction to the
challenges involved in integrating a garbage collector with Rust, I will not repeat what I
cannot improve on. The primary barrier to writing an effective garbage collector in and/or for Rust
is the current lack of Rust compiler awareness of garbage collection needs. It is understood that
this is in the research phase and that some proposals may be announced [this year][5].

Partially because it is not available but also somewhat to keep a runtime as
unobtrusive and as lightweight as possible, mo-gc chooses to avoid the use of GC support. Most
notably this means avoiding the standard technique of stop-the-world stack-scanning.

On the one hand, we have decided not to be reliant on non-existent compiler GC support.

On the other hand, we do not necessarily want memory management that is too distant from the host
language. [Oxischeme][3] is hosted in Rust and has an [arena based mark-and-sweep][25] garbage
collector, with different arenas for different object types. This makes it suitable for the
runtime it is integrated with, but far less ergonomic for more general use in Rust.

As a consequence, mo-gc is analagous to [SpiderMonkey's relationship with Servo][13], in that
smart pointers are required to root and unroot objects. Some ergonomics are sacrificed here, but
the tradeoff is established and currently accepted in Servo. A further benefit is that
GC-managed objects and pure Rust compile-time managed objects are clearly delineated.


#### Tracing Concurrently

Because we do not have type maps to rely on, every object that wishes to participate
in being GC managed must implement a trait:

```
#!rust
unsafe trait Trace {
    fn traversible(&self) -> bool;
    fn trace(&self, stack: &mut TraceStack);
}
```

The GC thread does not know the absolute type of every object it is managing so these methods,
when called from the GC thread, are inevitably virtual function calls.

The `traversible()` method must return `true` if the object may refer to other GC-managed objects.
This method is called from the mutator and the value passed through the journal to the GC. This
is an optimization that allows the GC to avoid making the call to `trace()` if the `TRAVERSIBLE`
bit is not set, saving an unnecessary virtual function call. On the mutator side, since the type
is known at compile-time and the return value of `traversible()` is a literal, the function call
can be largely optimized away.

The `trace()` method takes a parameter of type `TraceStack` which, as its name implies, is the
stack of objects buffered for tracing (or the list of gray objects in a tri-color equivalent
scheme.) The `trace()` method should call `stack.push(object)` for every object that it refers to.

The implementation of `trace()`, since it is called from the GC thread concurrently with the
mutator running, must be thread safe. Any mechanism may be used, even locks if necessary.
Because the thread safeness cannot be guaranteed by the compiler, just as with the `Sync` trait
`Trace` is an unsafe trait.



### <a name="inmo"></a>Inside mo-gc

Since Rust's borrow mechanism may be used to alleviate unnecessary root reference count
adjustments (just as an `Rc<T>` may be borrowed rather than cloned) in real world applications it
is possible that the journal write barrier cost may be ameliorated some.

#### The Journal

The journal behaves as a non-blocking unbounded queue. It is implemented as an unbounded series
of one-shot single-writer SPSC buffers, making it very fast.

Testing on a Xeon E3-1271 gives a throughput of about 500 million two-word objects per second.

Reference count increments from the journal are read into a heap map while decrements are pushed
into a buffer to be applied after the current collection cycle is complete. This is a major
contributor to this GC design being snapshot-at-beginning.


#### The Heap Maps

Each heap map - young and mature generation - is implemented using a bitmapped vector trie. This
gives access of `O(log 32)` on 32 bit systems and `O(log 64)` on 64 bit systems, though on 64 bit
systems the trie depth is greater than on 32 bit systems.


#### The Young Generation

The young generation heap map doubles as the root set reference count map. Collecting the young
generation is done by sharding the map into at least as many parts as there are CPUs available
to parallelize tracing on. Each shard is scanned for roots, which are non-zero reference counted
objects. They form the first set of gray objects, which are traced to find more gray objects to
add to the trace stack. Each thread has it's own trace stack, making it possible that two or more
threads might attempt to trace the same object concurrently.


#### Marking and Sweeping

Both marking and sweeping are multi-threaded, with work spread across all available CPUs by default.


### <a name="usemo"></a>Using mo-gc

Usage is superficially straightforward, excepting the coherence issues detailed later.

```
#!rust
extern crate mo_gc;

use mo_gc::{GcRoot, GcThread};


fn app() {
    let something = GcRoot::new(String::from("look ma! I have no defined lifetime!"));
    println!("String says {}", *something);
}


fn main() {
    let gc = GcThread::spawn_gc();

    let handle = gc.spawn_app(|| app());

    handle.join().expect("app thread failed");
    gc.join().expect("gc thread failed");
}
```



### <a name="ds"></a>Implementing Data structures

Because of coherence issues detailed later, it is not yet appropriate to experiment with complex
data structures.


### <a name="res"></a>Summary of Results

#### Measures

Points of general garbage collection interest are:

* maximum mutator latency
* minimum mutator utilization
* GC memory requirement overhead
* GC CPU burden relative to mutator

In the case of mo-gc, maximum latency is close to the speed of allocation. As to the other
measures, they have yet to be taken and in particular, MMU and GC CPU burden are highly
dependent on the use-case.

A brief list of test cases and their descriptions is given here:

| Test | Description                                                   |
|------|---------------------------------------------------------------|
| 1    | tight loop allocating 25,000,000 8-byte objects               |
| 2    | as test 1 but with 50ms pause every 4096 allocations |

Some rudimentary results, conducted on an 8-core Xeon E3-1271, are listed below:

| Test | Allocs/sec | Mut wall-clock | GC deallocs/sec | GC CPU time |
|------|------------|----------------|-----------------|-------------|
| 1    | 22,400,000 | 1115ms         | 10,200,000      | 2460ms      |
| 2    | 81,000     | 30,800ms       | 2,000,000       | 1200ms      |

In the first test case, the mutator gets near 100% of a CPU as the GC is not running on all eight
cores at all times.

The second test shows a GC performance of 20% that in the first test. This is due to the
lack of tuning of when a collection should occur. Currently a collection is made every time
the journal returns non-empty, but in test 2 the number of journal entries per collection
is low.


#### Qualitative Summary of Performance

1. Since the journal is a form of write barrier, where every rooting, unrooting and new object must
   be journaled, it is undoubtable that this implementation is less efficient than an
   incremental garbage collector where a write barrier is also required, which in turn
   is less efficient than non-incremental stop-the-world where no write barrier is needed.

2. The journal itself is a success and appears to scale, at least on x86(32 and 64). Writing a
   two-word struct to the journal adds roughly 25% to the cost of allocating a 64 byte object on
   the heap.

3. The parallel mark and sweep phases and the journal itself are sufficiently performant that the
   throughput bottleneck in the system is very evident: _processing_ the journal into the object map is
   currently single-threaded because insertion into the map is not concurrent.<br/><br/>
   With a mutator thread allocating new objects in a tight loop, the GC thread's throughput is about
   half the rate at which they are allocated.<br/><br/>
   If object map insertion could be done in parallel on multiple threads, throughput scalability
   would improve greatly.

4. The object map is implemented using a bitmapped trie with compressed nodes and a path cache.
   Indeces are the object addresses and they are mapped to metadata including the object reference
   count. This was the author's first Rust code and should be forgiven.<br/><br/>
   The use of the trie might also be improved on: while there is a trie path cache, on average,
   each object lookup requires multiple pointer indirections.

5. Mo-gc retains the default Rust allocator, jemalloc, rather than implementing its own allocator.
   The object map essentially duplicates jemalloc's internal radix trie, increasing the number of
   clock cycles for dropping dead objects. Maintaining a separate object map also increases memory
   requirements.

6. Coherence issues between the mutator and GC threads detailed in the next section.



### <a name="conc"></a>Coherence

In brief, the limitations of the current implementation of the journal as a write barrier as
described below are the same set of problems that are overcome by an incremental garbage
collector's write barrier.


#### Journal as Write Barrier

There is a use-after-free condition in the current implementation where, during the mark phase of
collection, the mutator reads a pointer from the heap, roots it, and then overwrites the
heap location with a new pointer or null before the heap location has been traced. The object
pointed to has been rooted and a journal entry been written, but the mark phase is not reading
the journal at this point. The sweep phase will then drop the object leaving the mutator in
a use-after-free state.

This means that the mutator threads cannot currently use mo-gc in it's present
form as fully general purpose, or rather that data structures must be persistent or designed
to avoid this scenario.

The fix is not obvious. At first it may seem that we just need to read journal entries
that were written during the mark phase and trace those too. But we end up back where we started,
as that itself is a mark phase and we then need to repeat the operation potentially indefinitely.

The problem that must be solved looks like this:

1. object `LittleCatA` contains a reference to `LittleCatB`, which in turn refers to `LittleCatC`
   all the way through in a linked list to `LittleCatZ`
2. the mutator has rooted `LittleCatA`
3. the GC enters the mark phase and begins tracing objects
4. before `LittleCatA` is traced, the pointer to `LittleCatB` is popped off and replaced with
   `null`
5. the mutator roots `LittleCatB` by writing an entry to the journal
6. the GC traces `LittleCatA` and finds nothing inside
7. the GC enters the sweep phase, dropping `LittleCatB` all the way through `LittleCatZ`

This is essentially a similar type of problem that [incremental garbage collectors][19] solve with
tri-color marking and [write barriers][20] on objects.

We need a synchronization point other than the reference count journal. A secondary write
barrier, a sequential store buffer, may fulfill this function. It may be necessary to make
writes to the SSB blocking while the mark phase is draining it.

This write barrier must send the pointer value that the mutator is about to overwrite to the SSB.

Additionally, a bit in the pointed-at object header might be set so that the mutator can avoid
the SSB overhead if it needs to send that object through the write barrier again. The sweep phase
would be responsible for resetting the flag - a gray flag.


#### The Remembered Set

If an object in the mature space is rooted and by way of indirection points at an object in the
young generation, that mature object root is insufficient in the current implementation to mark
the young object. The young object, if not reachable only in the young generation, will be
dropped.

A further write barrier feature must generate a reliable remembered set.

Without a custom allocator, this cannot be optimized into a card table.

With a custom allocator, the remembered set can be maintained per arena.


### <a name="thro"></a>Throughput

#### Journal Processing

The journal is currently processed in `YoungHeap::read_journals()` on a single thread only,
as the object map must be updated or inserted for each journal entry and insertion into
`bitmaptrie::Trie` cannot be done concurrently. This makes `Trie::set()` the single point of
GC throughput limitation, causing journal processing to consume most of the GC linear time.

If `Trie::set()` might be made thread-safe, throughput can be made to improve significantly and
the GC will begin to scale. This may be an unrealistic expectation for the current non-concurrent
trie implementation though.

A more approachable design may be to give each mutator thread its own young
generation object map. In this case the GC thread pool could process journals in parallel. However,
when tracing, each mutator thread's root set would be needed to trace all the other
object maps. This would allow a parallel approach but would be less efficient overall.

Giving each mutator thread its own young generation may pave the way to integrating a custom
allocator in a [heap-partitioned][26] design, which will be discussed later.

Currently, two words are written to the journal for every entry. The second word is the vtable,
which is unnecessary overhead. The vtable could be added to an object header, making journal
entries only one word.


#### A QoS Approach

Most garbage collectors have to pause the mutator periodically, even if for only a few milliseconds.

If the GC is struggling to keep up with a mutator that is allocating large numbers of objects very
quickly, a quality of service style mechanism might be considered where the mutator's allocation
rate is throttled. This would hopefully be a last-resort option.


#### Heap Map Optimizations

The heap map, implemented with `bitmaptrie::Trie`, is at worst `O(log usize_width)` for lookup and
insertion. It is path cached to improve lookups based on the previous lookup rather than starting
at the root every time. Each node is also compressed, to minimize memory requirements.

It may be faster, though possibly more memory hungry, to maintain an array of reference counts and
a bitmap for mark flags of multiple objects in each leaf value. For example:

```
#!rust
struct ObjectMetaArray {
    mark_flags: BitField[N],
    refcounts: [u32; N],
    vtables: [usize; N],
}
```

where `N` is a number of word-aligned addresses mapped to the array.  This would reduce trie
pointer hops, making insertion and iteration faster, but would increase memory use due to the
array being uncompressed.

Alternatively, the bitmapped trie might be replaced with a data structure more typical for this
purpose: a radix trie. It is not clear what magnitude of potential speedup is available here.


#### Custom Allocator

As mentioned in the section _Journal Processing_, this overall architecture may be
conducive to a partitioned-heap allocator and a [corresponding collection approach][26].

The possible advantages could be:

* Rotating journal buffers is already analagous to rotating heap partitions. Integrating the
  journal with a partitioned-heap allocation buffer per mutator thread may increase the efficiency
  both on the mutator and the GC thread sides.

* Sweeping only allocation buffers that are not being allocated to by a mutator would reduce thread
  contention: the current implementation on top of mo-gc can create contention between the sweep
  phase and the mutator when the mutator is allocating and the sweeper is dropping.

The downside of such an allocator is that since we cannot do heap compaction we will have to
take fragmentation into account when considering total memory use.



### <a name"rem"></a>Next Directions

The coherency and throughput issues make the current implementation impractical for use and must
be addressed.

The summary of options to investigate is:

* Partitioned heap: arena allocator with per-arena sequential store buffers; per-arena journals?
* Mark one arena at a time; mark is complete when tracing roots is complete and SSB is empty.
* Journal efficiency: one word per entry instead of two, move vtable to object header.
* Explore alternatives to bitmaptrie for root set: a random-access heap data structure? Rust's
  BTreeMap?


# <a name="read"></a>Further Reading

* [Bacon2004][2] Bacon et al, A Unified Theory of Garbage Collection
* [bdwgc][17] Boehm-Demers-Weiser GC, Two-Level Tree Structure for Fast Pointer Lookup
* [Klock2011][26] Felix S Klock II, Scalable Garbage Collection via Remembered Set
  Summarization and Refinement
* [Oxischeme][3] Nick Fitzgerald, Memory Management in Oxischeme
* [Rust blog][5] Rust in 2016
* [Servo][13] Servo blog, JavaScript: Servo’s only garbage collector

[1]: http://researcher.watson.ibm.com/researcher/files/us-bacon/Bacon03Pure.pdf
[2]: http://www.cs.virginia.edu/~cs415/reading/bacon-garbage.pdf
[3]: http://fitzgeraldnick.com/weblog/60/
[4]: https://github.com/Manishearth/rust-gc
[5]: http://blog.rust-lang.org/2015/08/14/Next-year.html
[6]: https://github.com/rust-lang/rust/pull/11399
[7]: https://github.com/rust-lang/rfcs/issues/415
[8]: https://github.com/rust-lang/rust/issues/2997
[11]: http://aturon.github.io/blog/2015/08/27/epoch/
[13]: https://blog.mozilla.org/research/2014/08/26/javascript-servos-only-garbage-collector/
[14]: http://blog.pnkfx.org/blog/2015/10/27/gc-and-rust-part-0-how-does-gc-work/
[15]: http://blog.pnkfx.org/blog/2015/11/10/gc-and-rust-part-1-specing-the-problem/
[16]: http://blog.pnkfx.org/blog/2016/01/01/gc-and-rust-part-2-roots-of-the-problem/
[17]: http://www.hboehm.info/gc/tree.html
[18]: http://felix-lang.org/share/src/packages/gc.fdoc
[19]: https://engineering.heroku.com/blogs/2015-02-04-incremental-gc/
[20]: https://developer.mozilla.org/en-US/docs/Mozilla/Projects/SpiderMonkey/Internals/Garbage_collection
[21]: http://llvm.org/docs/GarbageCollection.html
[22]: http://wiki.luajit.org/New-Garbage-Collector
[23]: https://github.com/pnkfelix
[24]: http://doc.cat-v.org/inferno/concurrent_gc/concurrent_gc.pdf
[25]: https://github.com/fitzgen
[26]: http://www.ccs.neu.edu/home/pnkfelix/thesis/klock11-diss.pdf
[27]: http://www.cs.rice.edu/~javaplt/311/Readings/wilson92uniprocessor.pdf
