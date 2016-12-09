---
layout: post
title:  "An Experiment in Garbage Collection"
date:   2016-03-13 21:00 EST5EDT
categories: Rust
redirects:
  - /mo-gc-intro.html
---


**Reinventing Garbage Collection Problems from First Principles by Aiming Way High.**

[Mo-gc](https://github.com/pliniker/mo-gc) is an experiment in garbage collection written in
the Rust programming language.

Instead of scanning the stack, the mutator writes reference count
increments and decrements to a journal. The journal is read concurrently by a garbage
collection thread that keeps a map of objects and their absolute reference counts. The object
map is divided into young and mature generations and collection is done with parallellized
mark and sweep phases.

The journal is a type of snapshot-at-beginning write barrier and this project
was an experiment in the feasibility, limitations and scalability of this approach.

In brief conclusion, this project was ambitions and fell short but I learned some of the hard
lessons of garbage collector implementation.

This article traces my thought process and implementation from beginning to time of writing.



### Contents

* [Irrational Exuberance](#ie)
* [Summary of the Design](#des)
* [Motivation: Hosting Languages](#rt)
* [Garbage Collection and Rust](#gcrust)
* [Inside mo-gc](#inmo)
* [Using mo-gc](#usemo)
* [Performance and Behavior](#res)
* [Conclusions](#rem)
* [Further Reading](#read)



### <a name="ie"></a>Irrational Exuberance, or How This Project Got Started

Early in 2015, Nick Fitzgerald published [Oxischeme][25]. With a general interest in programming
languages and runtimes and a specific interest in Rust, I had been following Rust's progress
towards 1.0 with eager anticipation. At the time, Oxischeme was notable as the only
published and documented language runtime written in Rust that could readily be found.

Oxischeme contains a [garbage collector][3] written in Rust because Rust itself has no garbage
collector. Most hobby interpreters are built on runtimes that provide a garbage collector for
free.  Even more interesting, though, Nick's article concluded with a link to David F. Bacon's
(et al) *[A Unified Theory of Garbage Collection][2]*.

This paper was fascinating. I had often wondered at the stark difference in apparent complexity
between reference counting and tracing collectors and how distant they seemed from each other
yet had the same ultimate aims.  This paper made that world smaller.

Given that David F. Bacon is credited with [successful garbage collectors][1] based around some
form of reference counting and given his *Unified Theory*, I decided I could ignore the poor
reputation of reference counting and contemplate it without feeling like it was a well
explored dead end in memory management.

At the end of a week of being highly distracted at all times of day with various mental
visualizations of reference counting combined with tracing I felt I had some sort of idea
that I hadn't seen anywhere before.  [What if][28] a mutator could run pauselessly by
keeping a journal of reference count increments and decrements that a GC thread would
read and reconstruct into the absolute reference count?

Since vowing (probably unreasonably) never to write C or C++ ever again several years earlier,
and since my main competence was in Python, I would have to wait until I felt comfortable enough
in Rust to begin experimenting.

The idea sat patiently on the back seat until one day in August I was struck with irrational
exuberance about it and decided to write a draft [RFC][31] for feedback, as I was, after all,
making this all up in a vacuum, yet excited about an idea I thought realistic.

Preparing the RFC to be taken seriously meant wider reading: mostly Bacon's reference counting
papers and patents, general garbage collection theory and concurrent data structures.

At the time, I thought the mechanism could only work for immutable/persistent data structures;
the most [convincing][34] [feedback][29] [I received][30] was that this would be too restrictive.
Quite likely nobody with any serious garbage collection experience paid any attention to the RFC or
I might have been directed back to the drawing board!

Thinking the mechanism through for mutable object graphs now occupied the back of my mind while
I began work on the basic data structure I would regardless need: a bitmapped vector trie.
Whatever Rust I had played with until now taught me little compared with implementing this data
structure, where I had to come to know unsafe and the borrow checker.

It took until Christmas to get [bitmaptrie][32] to a place where it was sufficiently correct
and featured to begin to use. That seems like a long time. I am a slow but thorough learner.
And I mostly only had late evenings.

The bitmapped vector trie uses word-sized indeces and is therefore `O(log_WORDBITS n)` access.
It includes a last-access path cache which can speed up lookups on spatially dense indexed entries.

My goal for this project was to make the code performant, using parallelism where possible.
The more performant the individual components were, the more the inherent bottlenecks in
the overall system would stand out. In time I added the ability to shard a trie into mutable
sub-tries, each of which would be independently updated in parallel.



### <a name="des"></a>Summary of the Design

* Pauseless: the mutator shouldn't be blocked by the GC thread ever, by writing reference count
  adjustments to a journal - a buffer - rather than being stopped for stack scanning periodically.
* Generational: new objects are kept track of separately from old objects. The advantage is that
  the entire heap shouldn't be traced on every collection, rather just the new object pool can
  be traced often and the entire heap traced infrequently. This is a performance optimization.
* Parallel mark and sweep: examining each object in the heap for what other objects it points to
  can be done by multiple threads; freeing unreferenced objects can be done by multiple threads.



### <a name="rt"></a>Motivation: Hosting Languages

In the previous section I mentioned vowing never to write C or C++ again. Rust exists to address
the very reasons I'd come to dislike those languages.  I also mentioned an interest in programming
languages and runtimes.

If a higher level programming language is not hosted in itself, there is a very high chance that
it is written in C or C++. By a degree of necessity, lower level interaction or optimized
extensions of those runtimes must also be in C or C++, perpetuating the pervasiveness of
these two languages.

I believe that if Rust is to be ultimately pervasive one day, it must itself host runtimes for
languages that are more accessible, just as Python and C are currently a popular combination.
(As an aside, Julia is a [notable outlier][33] that, while the runtime is written in C, does not
necessarily require performance sensitive extensions to be written in C.)

The mo-gc experiment is motivated by the safety benefits of Rust over C and C++ to explore a
programming language runtime written in Rust, with the ultimate aim to spread the safety that
Rust encourages.

Many new programming languages seem to start with a syntax and semantics wishlist, leaving the
runtime with a basic garbage collector as a second-class necessity that will eventually be
optimized.  As a garbage collector is a foundational requirement for most language runtimes, it
may make some sense to begin there rather than deferring the problem of memory management.



### <a name="gcrust"></a>Garbage Collection and Rust

As [Felix S. Klock II][23] has [already][14] [written][15] [a thorough][16] introduction to the
challenges involved in integrating a garbage collector with Rust, I will not repeat what I
cannot improve on.

The primary barrier to writing an effective garbage collector in and/or for Rust
is the current lack of Rust compiler awareness of garbage collection needs. I understand that
this is in the research phase and that some proposals may be announced [this year][5].

The two key features that aren't natively available are stack scanning and type maps. Because
I was planning on using a journal to push stack information to the GC thread, I wouldn't
need stack scanning. I could work around the lack of type maps by giving each type it's
own tracing method.

The third question concerned ergonomics.  I did not necessarily want memory management to be too
distant from the host language. [Oxischeme][3] is hosted in Rust and has an
[arena based mark-and-sweep][25] garbage collector, with different arenas for different object
types. This is fine for the runtime it is integrated with, but far less ergonomic for
more general use in Rust.

As a consequence, I decided to follow the lead of [SpiderMonkey's relationship with Servo][13],
in that smart pointers are required to root and unroot objects. Some ergonomics are sacrificed
here, but the tradeoff is already familiar.



### <a name="inmo"></a>Inside mo-gc

#### Tracing Concurrently

Without type maps to rely on, every object that wishes to participate in being GC managed
must implement a trait:

{% highlight rust %}
unsafe trait Trace {
    fn traversible(&self) -> bool;
    fn trace(&self, stack: &mut TraceStack);
}
{% endhighlight %}

The GC thread does not know the absolute type of every object it is managing, so these methods,
when called from the GC thread, are inevitably virtual function calls.

The `traversible()` method must return `true` if the object may refer to other GC-managed objects.
This method is called from the mutator and the value passed through the journal to the GC as a
bit flag.

By calling `traversible()` on the mutator side where the absolute type is known, the virtual
function call on the GC thread side can be avoided, and optimized away on the mutator side if
the value is a literal, which it generally would be.

This also allows the GC thread to avoid a virtual function call to `trace()` when the
`traversible` flag is `false`.

The `trace()` method takes a parameter of type `TraceStack` which, as its name implies, is the
stack of objects buffered for tracing (or the list of gray objects in a tri-color equivalent
scheme.) The `trace()` method should call `stack.push(object)` for every object that it refers to.

The implementation of `trace()`, since it is called from the GC thread concurrently with the
mutator running, must be thread safe. Any mechanism may be used, even locks if necessary.
Because the thread safeness cannot be guaranteed by the compiler, just as with the `Sync` trait
`Trace` is an unsafe trait.


#### The Journal

The journal behaves as a non-blocking unbounded queue. It is implemented as an unbounded series
of one-shot single-writer SPSC buffers, making it very fast.

Testing on a Xeon E3-1271 gives a throughput of about 500 million two-word objects per second
between a producer thread and a consumer thread, although that is a micro-benchmark and therefore
to be taken as probably real-world unrealistic.

The type that the mutator writes to the journal is almost identical to a `TraitObject` with one
difference: the low pointer bits are used as flags.

{% highlight rust %}
struct Entry {
    ptr: usize,
    vtable: usize
}
{% endhighlight %}

Flags used are:

* `ptr | 01b`: increment reference count by 1
* `ptr | 11b`: increment reference count by 1 for a newly allocated object
* `ptr | 10b`: notify of a newly allocated object without adjusting the reference count
* `vtable | 10b`: object's `traversible()` method returns `true`
* `vtable | 00b`: `traversible()` is `false`

Journal entries are read into a young generation heap map that keeps track of all stack roots.

Reference count decrement entries are not immediately applied, though: they are buffered to be
applied after the current collection (mark and sweep) cycle is completed. This makes this
design essentially [snapshot-at-beginning][27] with new objects automatically marked "black" in the
tri-color notation.


#### The Heap Maps

There are two heap maps, a young and a mature generation, each implemented using a separate
bitmapped vector trie.

The young generation heap map doubles as the root set reference count map.

Collecting the young generation is implemented by sharding the trie into at least as many
immutable parts as there are CPUs available to parallelize tracing in a thread pool. Each shard
is scanned for non-zero reference counted objects and all non-newly-allocated objects (marked black
on allocation).  They form the first set of gray objects, which are traced to find more gray
objects to add to the trace stack.

During marking, each thread has it's own trace stack, avoiding the need to synchronize between
threads, but making it possible that two or more threads might attempt to trace the same object
concurrently.

For sweeping, the heap is sharded mutably across the thread pool, with each shard being swept
concurrently with others.

Since there are two distinct categories of objects in the young generation map: reference counts
for mature objects and counted or uncounted newly allocated objects. Only newly allocated object
entries are candidates for sweeping as the mature heap owns mature objects. This distinction does
not exist in the mature generation.

I had originally thought that since the root set would include objects in the mature generation
that this would suffice as a precise remembered set.  When tracing the young generation, the
root set would simply be all pointers, new or mature, with a positive reference count.

The invariant required in a generational garbage collector is that:

| Every live mature object that points to a live object in the young generation must be discoverable and considered a root. |
|-|

Typically a generational garbage collector will implement a remembered set or a card table that is
updated with a write barrier to discover these roots.

My original assumption does not uphold the invariant since mature generation
objects that are stack roots may point indirectly to young generation objects. My implementation
does not take indirect mature generation roots into consideration, making the remembered set
incomplete.  The result is that some object graph modifications may result in live objects being
freed.  But more on that later.



### <a name="usemo"></a>Using mo-gc

Usage is superficially straightforward, as this basic example demonstrates:

{% highlight rust %}
extern crate mo_gc;

use mo_gc::{GcRoot, GcThread};


fn app() {
    let something = GcRoot::new(String::from("I am a GC owned string"));
    println!("String says {}", *something);
}


fn main() {
    let gc = GcThread::spawn_gc();

    let handle = gc.spawn_app(|| app());

    handle.join().expect("app thread failed");
    gc.join().expect("gc thread failed");
}
{% endhighlight %}

When the time comes to implement a data structure, the `Trace` trait comes into play. The example
below illustrates the basic API usage:

{% highlight rust %}
extern crate mo_gc;

use mo_gc::{Gc, GcRoot, GcThread, Trace, TraceStack};


struct Node {
    next: Gc<Node>,
}


unsafe impl Trace for Node {
    fn traversible(&self) -> bool {
        true
    }

    fn trace(&self, stack: &mut TraceStack) {
        if let Some(ptr) = self.next.as_raw() {
            stack.push_to_trace(&*ptr);
        }
    }
}
{% endhighlight %}

Because the mutator thread runs in parallel with the GC thread, the immediate question that must
be asked is "is this data structure and the `trace()` function thread safe?"

As long as the data structure itself is not mutably aliased, only the `trace()` function's
behavior is significant.  It must essentially provide a snapshot of the data structure's
contents to the GC thread.  At best it is challenging to prove thread safety and because of other
problems described later I did not begin to implement any data structures.



### <a name="res"></a>Performance and Behavior

#### Measures

Points of garbage collection performance interest are:

* maximum mutator latency
* minimum mutator utilization
* GC memory requirement overhead
* GC CPU burden relative to mutator

In the case of mo-gc, maximum latency is close to the speed of allocation.

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
cores at all times.  The GC and mutator threads do spend a significant portion of time contending
in the allocator - the mutator allocating and the GC thread deallocating.

The second test shows a GC performance of 20% the deallocation rate of that in the first test.
This is due to the lack of tuning of when a collection should occur. Currently a collection is
made every time the journal returns non-empty, but in test 2 the number of journal entries per
collection is low, reducing efficiency.

The contention between the mutator and the GC in the allocator is low in test 2, though. Just
how bad the contention is in test 1 is shown by how much more GC CPU time test 1 requires than
test 2.

Overall, the CPU burden relative to the mutator is unscalably high.


#### Qualitative Summary of Performance

1. Since the journal is a form of write barrier, where every rooting, unrooting and new object must
   be journaled, it is undoubtable that this implementation is less efficient than an
   incremental garbage collector where a write barrier is also required, which in turn
   is less efficient than non-incremental stop-the-world where no write barrier is needed.

2. The journal itself appears to scale somewhat, at least with x86's memory ordering. Writing a
   two-word struct to the journal adds roughly 25% to the cost of allocating a 64 byte object on
   the heap.<br><br>
   Since Rust's borrow mechanism may be used to alleviate unnecessary root reference count
   adjustments (just as an `Rc<T>` may be borrowed rather than cloned) in real world applications it
   is possible that the journal write barrier cost may be ameliorated some.

3. Rather than using a custom allocator, the object map is implemented using a bitmapped trie
   with compressed nodes and a path cache.  This is somewhat slower than a custom allocator might
   allow as the trie requires multiple pointer indirections on every access.  A custom allocator
   can use a bitmap, for example, as the mark flags.

4. The parallel mark and sweep phases and the journal itself are sufficiently performant that the
   throughput bottleneck in the system is very evident: _processing_ the journal into the object map.
   With a mutator thread allocating new objects in a tight loop, the GC thread's throughput is about
   half the rate at which they are allocated. This is very unscalable and, in performance terms,
   is the most obviously flawed part of the overall design.

5. Requiring data structures managed by the GC to be concurrent, or at minimum provide a
   concurrency-safe `trace()` implementation, may be fraught with pitfalls.


#### The Journal as a type of Write Barrier

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

This is essentially the problem that [incremental garbage collectors][19] solve with
a [write barriers][20] that sends the pointer value that the mutator is about to overwrite to
a buffer. The GC reads the buffer and marks all objects therein gray. Synchronization is also
required to stop the mutator from adding to the buffer while the GC completes the mark phase.


#### The Remembered Set

If an object in the mature generation is rooted and by way of indirection points at an object in
the young generation, that mature object root is insufficient in mo-gc to result in the young
object being marked.  The young object, if not reachable also in the young generation, will be
freed.

This problem is solved in [generational garbage collectors][27] with a [write barrier][35] that
writes the mature object address to a remembered set.  The remembered set is used as an
additional set of roots when tracing the young generation.



### <a name="rem"></a>Conclusions

First, a question: _can this design be made to work?_

With synchronization points between the mutator and GC threads, yes.  Extending the journal
to include the write barrier functions of generational and incremental garbage collectors
would be sufficient to provide coherence between the mutator and GC threads.

But is it worth it?  While this design cannot be truly pauseless (some synchronization is
always needed), the mutator pauses might still be insignificant enough to make this
design worth considering. However, the performance overhead of maintaining the reference counted
root set data structure is too significant to ignore.  The performance of the
[Very Concurrent Garbage Collector][24] may be instructive.

In conclusion, I aimed way high and missed.  But in aiming so high I experienced the same
problems that have been solved decades ago and I learned why those problems exist and why
the solutions are what they are.  I also learned a great deal of Rust.  Most of all, this
has been a hugely enjoyable and rewarding deep dive into garbage collection.  It was worth it.



# <a name="read"></a>Further Reading

* [Bacon03Pure][1] Bacon et al, A Pure Reference Counting Garbage Collector
* [Bacon2004][2] Bacon et al, A Unified Theory of Garbage Collection
* [Basu2009][36] Abhinaba Basu, Back to basic: Series on dynamic memory management
* [BDWGC][17] Boehm-Demers-Weiser GC, Two-Level Tree Structure for Fast Pointer Lookup
* [Klock2011][26] Felix S Klock II, Scalable Garbage Collection via Remembered Set Summarization and Refinement
* [Klock2015-1][14] Felix S Klock II, GC and Rust Part 0: Garbage Collection Background
* [Klock2015-2][15] Felix S Klock II, GC and Rust Part 1: Specifying the Problem
* [Klock2015-3][16] Felix S Klock II, GC and Rust Part 2: The Roots of the Problem
* [Oxischeme][3] Nick Fitzgerald, Memory Management in Oxischeme
* [Huelsbergen1998][24] Huelsbergen et al, Very Concurrent Mark-&-Sweep Garbage Collection without Fine-Grain Synchronization
* [Lua Wiki][22] The LuaJIT Wiki, Garbage Collector
* [Rust blog][5] Rust in 2016
* [Sasada2015][19] Koichi Sasada, Incremental Garbage Collection in Ruby 2.2
* [Servo][13] Servo blog, JavaScript: Servo’s only garbage collector
* [SpiderMonkey][20] SpiderMonkey Internals, Garbage Collection
* [Wilson92][27] Paul Wilson, Uniprocessor Garbage Collection Techniques

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
[25]: https://github.com/fitzgen/oxischeme
[26]: http://www.ccs.neu.edu/home/pnkfelix/thesis/klock11-diss.pdf
[27]: http://www.cs.rice.edu/~javaplt/311/Readings/wilson92uniprocessor.pdf
[28]: http://www-tc.pbskids.org/apps/media/apps/wild-kratts_1.png
[29]: https://users.rust-lang.org/t/rfc-pauseless-concurrent-garbage-collector/2624
[30]: https://www.reddit.com/r/rust/comments/3ihbl6/rfc_pauseless_concurrent_garbage_collector/
[31]: https://github.com/pliniker/mo-gc/blob/master/doc/Project-RFC.md
[32]: https://github.com/pliniker/bitmaptrie-rs
[33]: http://graydon2.dreamwidth.org/189377.html
[34]: https://botbot.me/mozilla/rust-internals/2015-08-26/?msg=48213031&page=6
[35]: https://blogs.msdn.microsoft.com/abhinaba/2009/03/02/back-to-basics-generational-garbage-collection/
[36]: https://blogs.msdn.microsoft.com/abhinaba/2009/01/25/back-to-basic-series-on-dynamic-memory-management/
