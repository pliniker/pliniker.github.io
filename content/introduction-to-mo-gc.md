Title: mo-gc, a garbage collector for runtimes in Rust
Date: 2016-03-13 21:00
Category: Rust
Tags: mo-gc, rust, gc
Slug: mo-gc-intro
Authors: Peter Liniker
Summary: Introduction to mo-gc

# An Experiment in Pauseless Garbage Collection

A pauseless, concurrent, generational, parallel mark-and-sweep garbage collector in Rust.

That's a mouthful.

```
#!rust
extern crate mo_gc;
use mo_gc::{Gc, GcRoot, GcThread, Trace, TraceStack};
```

## Summarize the problem space addressed and mo-gc
## Define the problem spaces
## Describe the specific problem space, specific to Rust as it is today
## Outline how mo-gc addresses the problem
## Details of how mo-gc works with sample code

journal
bitmaptrie
generational
parallel mark and sweep

## Examples of how the mutator uses GcRoot and Gc
## Data structures

Use of `Gc` should be reasonably straightforward. Describe a Vec, tree, queue?

Use of `GcAtomic` is more speculative.

## Remaining problems

Journal must be read after marking to catch rooted unmarked objects.

Journal is processed on a single thread.

## Future improvements

Trie use efficiency improvement: right shift the address more and store a bitmap of multiple
addresses.

## References

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

include boehm links
