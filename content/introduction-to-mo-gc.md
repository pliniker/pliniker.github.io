Title: An Experiment in Pauseless Garbage Collection
Date: 2016-03-13 21:00
Category: Rust
Tags: mo-gc, rust, gc
Slug: mo-gc-intro
Authors: Peter Liniker
Summary: Introduction to mo-gc


**Using [mo-gc](https://github.com/pliniker/mo-gc), a garbage collector implemented in Rust.**

> Mo-gc avoids mutator pauses by writing stack root reference count increments and decrements to a
> journal. The journal is read concurrently by a garbage collection thread that keeps a map of
> objects and their absolute reference counts. The object map is divided into young and mature
> generations and collection is done in parallel using mark and sweep.
>
> The journal is a type of write barrier and this project is an experiment in the feasibility,
> limitations and scalability of the journaling approach.


# Contents

* [Language Runtimes](#rt)
* [Garbage Collection and Rust](#gcrust)
* [Inside mo-gc](#inmo)
* [Using mo-gc](#usemo)
* [Implementing Data Structures](#ds)
* [Summary of Results](#res)
* [Journal as Write Barrier](#conc)
* [Improving Throughput](#thro)
* [Concluding Remarks](#rem)


### <a name="rt"></a>Language Runtimes

* motivation: C/C++ runtimes
* integration issues: pauses, concurrency, GIL

### <a name="gcrust"></a>Garbage Collection and Rust

I will not attempt to repeat in entirety that which Felix S Klock has already written on integrating
garbage collection with Rust.

* stack roots
* heap roots
* tracing
* spidermonkey


### <a name="inmo"></a>Inside mo-gc

Since the journal is a form of write barrier, where every rooting, unrooting and new object must
be journaled, it is undoubtable that overall, this implementation is less efficient than an
incremental, generational garbage collector where a write barrier is also required, which in turn
is less efficient than non-incremental stop-the-world where no write barrier is needed.

Since Rust's borrow mechanism may be used to alleviate unnecessary root reference count
adjustments (just as an `Rc<T>` may be borrowed rather than cloned) in real world applications it
is possible that the journal write barrier effect may be lessened.

* journal
* bitmaptrie
* generational
* parallel mark and sweep


### <a name="usemo"></a>Using mo-gc

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

Use of `Gc` should be reasonably straightforward. Describe a Vec, tree, queue?

Use of `GcAtomic` is more speculative.


### <a name="res"></a>Summary of Results

#### How does this Compare?

At this point this implementation is too immature to warrant direct comparisons to other
mainstream language runtimes.

The author has not benchmarked any other runtimes since it is very difficult to
compare like for like without establishing contexts for comparison.

Establishing comparison contexts is something to do in future and the purpose would be, not
to build a better garbage collector than everybody else, but to discover where this implementation
can be improved and what use cases it is suitable or unsuitable for.

Points of general garbage collection interest are:

* maximum mutator latency
* minimum mutator utilization
* GC memory requirement overhead
* GC CPU burden relative to mutator

In the case of mo-gc, maximum latency is close to the speed of allocation. As to the other
measures, they have yet to be taken and in particular, MMU and GC CPU burden are highly
dependent on the use-case.

#### Implementation Status

The garbage collector works and the theory is sound, with current implementation caveats:

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
   each object lookup requires multiple pointer indirections.

4. Mo-gc retains the default Rust allocator, jemalloc, rather than implementing its own allocator.
   The object map essentially duplicates jemalloc's internal radix trie, increasing the number of
   clock cycles for dropping dead objects. Maintaining a separate object map also increases memory
   requirements.

5. Use-after-free conditions detailed in the next section.

### <a name="conc"></a>Journal as Write Barrier

The limitations of the journal as a write barrier are evident in two premature object deallocation
scenarios.

#### The First

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
three-color marking and [write barriers][20] on objects.

It may be that an additional form of write barrier on each object that marks it 'grey' when
a reference to it is mutated can solve this problem.

#### The Second

If an object in the mature space is rooted and by way of indirection points at an object in the
young generation, that mature object root is insufficient in the current implementation to mark
the young object. The young object, if not reachable only in the young generation, will be
dropped.

In this case, an additional write barrier will only delay the drop but the inherent problem
remains.

The root set must include the object in the mature generation that holds the pointer to the
young object.


### <a name="thro"></a>Improving Throughput

#### Journal Processing

The journal is currently processed in `YoungHeap::read_journals()` on a single thread only,
as the object map must be updated or inserted for each journal entry and insertion into
`bitmaptrie::Trie` cannot be done concurrently. This makes `Trie::set()` the single point of
GC throughput limitation, causing journal processing to consume most of the GC linear time.

If `Trie::set()` can be made thread-safe, throughput can be made to improve significantly and
the GC will begin to scale. This may be unrealistic for a non-concurrent trie
implementation though.

An alternative to making `Trie::set()` thread-safe may be to give each mutator thread its own young
generation object map. In this case the GC thread pool could process journals in parallel. However,
when tracing, each mutator thread's root set would be needed to trace all the other
object maps. This would allow a parallel approach but would be less efficient overall.

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

Another alternative used in the [Felix][18] language garbage collector, which has somewhat in
common with mo-gc, is a Judy array, though it's complexity and apparent inflexibility may be
prohibitive.


### <a name"rem"></a>Concluding Remarks

It is my hope that with sufficient optimization, mo-gc or a future relative might be taken
seriously as a foundational component of language runtimes hosted in Rust.

The throughput issue currently makes it a non-contender except perhaps for low allocation-intensity
applications but with the appropriate data structure I believe it can be addressed.

The mark/journal race condition can be designed around but the fact that it prevents this from
being used as a fully general-purpose GC will hinder this project unless it can be solved.


# References

* [Bacon2003][1] Bacon et al, A Pure Reference Counting Garbage Collector
* [Bacon2004][2] Bacon et al, A Unified Theory of Garbage Collection
* [bdwgc][17] Boehm-Demers-Weiser GC: Two-Level Tree Structure for Fast Pointer Lookup
* [crossbeam][11] Aaron Turon, Lock-freedom without garbage collection
* [Oxischeme][3] Nick Fitzgerald, Memory Management in Oxischeme
* [Manishearth/rust-gc][4] Manish Goregaokar, rust-gc project
* [michaelwoerister/rs-persistent-datastructures][10] Michael Woerister, HAMT in Rust
* [Rust blog][5] Rust in 2016
* [rust-lang/rust#11399][6] Add garbage collector to std::gc
* [rust-lang/rfcs#415][7] Garbage collection
* [rust-lang/rust#2997][8] Tracing GC in rust
* [Servo][13] Servo blog, JavaScript: Servo’s only garbage collector
* [Shenandoah][12] Shenandoah, a low-pause GC for the JVM

[1]: http://researcher.watson.ibm.com/researcher/files/us-bacon/Bacon03Pure.pdf
[2]: http://www.cs.virginia.edu/~cs415/reading/bacon-garbage.pdf
[3]: http://fitzgeraldnick.com/weblog/60/
[4]: https://github.com/Manishearth/rust-gc
[5]: http://blog.rust-lang.org/2015/08/14/Next-year.html
[6]: https://github.com/rust-lang/rust/pull/11399
[7]: https://github.com/rust-lang/rfcs/issues/415
[8]: https://github.com/rust-lang/rust/issues/2997
[10]: https://github.com/michaelwoerister/rs-persistent-datastructures
[11]: http://aturon.github.io/blog/2015/08/27/epoch/
[12]: https://www.youtube.com/watch?v=QcwyKLlmXeY
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
