Title: Write Barrier and Arena Internal Discussion
Date: 2016-03-23 21:00
Category: Rust
Tags: mo-gc, rust, gc
Slug: mo-gc-ideas
Authors: Peter Liniker
Summary: Mo-gc ideas


## The Journal

Is this necessary when other write barriers may suffice? Yes and no.

Given a `GcRoot<Environment>` where objects are added and removed from the `Environment` instance,
the journal as roots reference counter is largely unneeded. Except for the initial `GcRoot<...>`.

All this is achieving though is pushing the burden of maintaining the root set on to the mutator,
though it may be the implementation reality for a hosted language.

The journal, then, as a per-mutator SPSC queue of reference count adjustments (though not new
objects) is basically necessary.



## Arenas

Object sizes should be fixed to one size fits all types (yes, wasteful, but easier than dealing
with fragmentation up front.)

This is like Ruby's allocator. Similarly, there are bit fields for marking and object presence.

Arenas have additional data structures that are updated by a write barrier. The write barrier
may additionally block the mutator if the arena being updated requires synchronization with
the mutator.

Do objects need to be marked black or white on allocation?

* Because the journal represents snapshot-at-beginning behavior, new objects should be marked
  black on allocation.
* If they are marked white, the write barrier would take effect during the mark phase if a
  new object is attached to an existing object but otherwise there is nothing to root the object.


### Sequential Store Buffer

Each arena gets it's own SSB for objects that may be missed during tracing.

Every pointer value that is overwritten is pushed on to the SSB of the arena it is associated
with.

### Remembered Set

Every arena has a remembered set to store references to objects in other arenas that may point
to objects in this arena.

Every object that has another pointer written to it is added to the remembered set for the
arena that the pointer is associated with.



## Phases

Each arena iterates through three phases. It can only be in one phase at any time.

### Mutator/Allocation

During this phase, the arena can only receive new objects, it cannot be marked or swept. The
arena-local heap structure is mutable in both objects allocated and object relationships.

| Invariant: |
|------------|



### Marking

Marking can only be done on an arena not in allocation or sweeping. The mutator may update
relationships betwen objects in the arena during this phase.

The roots, SSB and remembered set must be traced to find live objects in the arena.

| Invariant: every live object must be discovered. All white objects that the mutator may add a reference to from a black or gray object during tracing must be marked. |
|---------------------------------------------------------------------------------------------|

As a result of this invariant, the GC must synchronize with the mutator during this phase.
Once the roots have been traced, the SSB and remembered set are frozen and traced, blocking any
mutator thread that has triggered a write barrier that will add to the SSB or remembered set.

Any blocked mutators are unblocked once the mark phase has completed.


### Sweeping

Sweeping can be done on every arena that is in neither allocation nor marking phases. This means
that no new objects can be allocated in it at this time, but live objects may still be mutated.

| Invariant: every object that is live must be marked. |
|------------------------------------------------------|

Only unmarked objects will be deallocated.

Once an arena has been swept it is returned to the allocation phase.
