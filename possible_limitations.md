# Phlex — Possible Limitations
### Exploration, Refutations, and Mitigations

Each limitation is examined against the actual Phlex source code.
Misunderstandings are refuted before mitigations are discussed.

---

## Slide L1.1 — Limitation 1: The Chunked Stream Problem

**Also known as:** overlap-add / overlap-save FFT-based convolution.

### Setting

An "event" data cell holds a long time-series waveform. The waveform is too
large to fit in RAM as a single product, so it is split into overlapping
*fragments* (chunks) stored in a child layer:

```
job
 └── event
       └── fragment:0  fragment:1  fragment:2  ...  fragment:N
```

Each fragment is a contiguous slice of the waveform, typically with an
overlap region at each end so that convolution at the boundary is correct.

### Required computation

FFT-based convolution (or deconvolution) whose impulse-response kernel is
shorter than one fragment but whose support extends across fragment
boundaries. The classic *overlap-add* method requires:

- Processing fragment N together with the saved *tail* from fragment N-1.
- Storing a partial result (tail) for application when processing fragment N+1.
- All fragments must be processed in ascending order: N=0, 1, 2, …

### What the Phlex data-layer model provides

| Need | Phlex primitive | Available? |
|---|---|---|
| One data cell at a time per transform | `transform` | Yes |
| Accumulate all fragments then emit | `fold` at event level | Yes, but all in RAM |
| Access fragment N and N-1 together | sliding-window primitive | **No** |
| Guaranteed fragment delivery order | sequencing node | **No** |
| Save tail between sequential calls | stateful `make<T>()` object | Yes (with caveats) |

### Verdict

This is a **real gap**. The Phlex data model is designed for
cell-independent algorithms. Temporal dependency between sibling cells
requires explicit work-arounds at the algorithm level or new framework
primitives.

**Narration:**
The chunked stream problem is the canonical case where Phlex's single-cell-at-a-time
model is strained. The data must be split into fragments (because it won't fit in
RAM as one product) but the algorithm must span fragment boundaries (because the
physics kernel extends beyond one fragment). These two requirements are in direct
tension with the data-layer hierarchy's guarantee that each transform invocation
sees exactly one data cell's worth of products.

---

## Slide L1.2 — Limitation 1: Available Mechanisms in Phlex Today

### Pattern A: Stateful algorithm object with `make<T>()`

Register a class whose member function is called once per fragment. The
object holds the tail buffer as mutable state across calls.

```cpp
// Register a stateful overlap-add filter
auto obj = g.make<OvlapAdd>(kernel, fragment_size, overlap_size);
obj.transform("conv_step", &OvlapAdd::process_fragment,
              concurrency::serial);   // REQUIRED — see L1.3
```

Inside `OvlapAdd::process_fragment`:

```cpp
product_store_const_ptr OvlapAdd::process_fragment(product_store_const_ptr const& store)
{
    auto h = store->get_handle<Waveform>(frag_query);
    Waveform result = convolve_with_overlap(*h, tail_);  // uses saved tail
    tail_ = extract_tail(result);                        // save for next call
    return make_store_with(store->index(), result);
}
```

- `concurrency::serial` ensures at most one invocation at a time (mutual exclusion).
- **Caveat:** serial does not guarantee delivery order — see Slide L1.3.

### Pattern B: Fold with in-memory accumulation

A `fold` partitioned at the event level accumulates all fragments, then
emits a single result when flushed.

```cpp
g.fold("full_conv", "event",
    [&kernel](ConvState& s, auto const& store) {
        s.append(*store.get_handle<Waveform>(q));
    },
    []{ return ConvState{}; },  // init per event
    "convolved");
// flush fires once all fragments arrive → emit result
```

- Ordering: the fold waits for all fragments before emitting — **order irrelevant**.
- **Fatal limitation:** all fragments must fit in RAM simultaneously. This defeats
  the entire purpose of chunking for large events. Not viable for the motivating case.

### Pattern C: Layered unfold + fold pipeline

Unfold each fragment into fine-grained `fft_block` grandchildren; transform
per block; fold blocks back into the fragment result.

```
event
 └── fragment:N  (unfold creates per-fragment children)
       └── fft_block:0  fft_block:1  ...
```

This decomposes computation finely but does not eliminate the inter-fragment
tail problem. The tail from fragment N to N+1 still requires Pattern A at the
fragment level.

**Narration:**
Pattern A is the most practical today but requires the algorithm author to implement
their own ordering buffer (Slide L1.3). Pattern B is clean but impractical for large
events. Pattern C is a useful decomposition that reduces the per-block computation
burden but still reduces to Pattern A at the fragment boundary. No single pattern is
fully satisfactory without a framework-level sequencing guarantee.

---

## Slide L1.3 — Limitation 1: The Index-Ordering Problem

### Key finding: `concurrency::serial` ≠ ordered delivery

`concurrency::serial` in TBB's `flow::graph` sets the node's concurrency
limit to 1. This guarantees **mutual exclusion** — at most one invocation
runs at a time. It does **not** guarantee that invocations execute in the
order messages were delivered to the node.

The `index_router` (`phlex/core/index_router.hpp`) delivers indices to
provider input ports via TBB graph edges with no ordering constraint:

```
Driver yields:  fragment:0, fragment:1, fragment:2  (in this order)
index_router → provider → transform → OvlapAdd::process_fragment
    │
    └── TBB scheduler may reorder: fragment:2 arrives first at OvlapAdd
```

There is no sequencing node, priority queue, or ordered buffer anywhere in
the `index_router` or any declared algorithm node.

### Severity

For overlap-add, **out-of-order processing produces wrong results silently**.
If fragment 2 arrives before fragment 1:
- The tail saved from fragment 2 is applied to fragment 3 instead of tail from 1.
- Fragment 1 is then processed with stale or zero tail.
- No assertion or exception is raised.

### Mitigation at the algorithm level

The algorithm object can implement its own reordering buffer:

```cpp
void OvlapAdd::process_fragment(product_store_const_ptr const& store)
{
    size_t n = store->index()->number();
    pending_[n] = store;          // buffer out-of-order arrivals

    // drain in-order as far as possible
    while (pending_.count(next_expected_)) {
        auto& s = pending_.at(next_expected_);
        do_overlap_add(s, tail_);
        tail_ = extract_tail(...);
        pending_.erase(next_expected_++);
    }
}
```

This makes correctness independent of delivery order at the cost of:
- Memory: pending buffer may hold up to N-1 out-of-order fragments.
- Latency: output for fragment K is delayed until all of 0..K have arrived.

### In practice: does TBB actually reorder?

For a simple serial chain — driver → index_router → provider → transform —
TBB may happen to deliver messages in FIFO order in practice, because the
serial transform processes one message before accepting the next. But this
is **undocumented and not guaranteed**. Relying on it is fragile and
version-dependent.

**Narration:**
The ordering issue is subtle because it is invisible during normal testing
(TBB often happens to be FIFO in simple topologies) but can manifest under
load or after a TBB version change. The safe approach is always to implement
the in-order drain buffer in the algorithm object. This is boilerplate that
every chunked-stream algorithm must repeat, which motivates a framework-level
solution.

---

## Slide L1.4 — Limitation 1: Proposed Framework Enhancements

Two new framework primitives would make chunked-stream algorithms safe and
natural in Phlex.

### Enhancement 1: Sequencing node

A new node type `sequenced_transform` that wraps a standard transform with
a per-parent ordered delivery buffer. It re-orders child-layer messages by
`data_cell_index::number()` before invoking the algorithm, flushing the
buffer in ascending order. TBB already provides `sequencer_node` for exactly
this purpose.

```
index_router → provider → sequenced_transform
                              ├── internal buffer: {0: pending, 1: ready, 2: pending}
                              └── delivers: 0, then 1, then 2 to algorithm body
```

API sketch:
```cpp
obj.sequenced_transform("conv_step", &OvlapAdd::process_fragment,
                        concurrency::serial);
// guarantees algorithm body receives fragments in ascending index order
// per parent event cell
```

- Eliminates algorithm-level sorting.
- The buffer is keyed by `(parent_hash, number)` and is flushed when the
  parent's flush message arrives (when all children have been processed).
- No semantic change to the rest of the graph.

### Enhancement 2: Sliding-window fold

A new fold variant holding a window of W consecutive cells and invoking the
algorithm once per window position, advancing by stride S. Emits results
at the **child layer** (same layer as inputs — currently unsupported fanout pattern).

```
fragment:0 ─┐
fragment:1 ─┼─► window_fold(W=2, S=1) → result:0  (fragments 0,1)
fragment:2 ─┤                         → result:1  (fragments 1,2)
fragment:3 ─┘                         → result:2  (fragments 2,3)
```

For overlap-add: W=2 (current + previous), S=1 (advance one fragment at
a time). The algorithm body receives both fragments and the implicit ordering.

Requires Enhancement 1 (ordered delivery) as a prerequisite.

### Summary

| Approach | Works today? | Caveats |
|---|---|---|
| Stateful object + `serial` concurrency | With risk | No ordering guarantee |
| Stateful object + in-algorithm sort buffer | Yes | Algorithm boilerplate |
| Fold (all fragments in RAM) | Not viable | Defeats chunking |
| Sequencing node (proposed) | Future | Framework change |
| Sliding-window fold (proposed) | Future | Requires sequencing node |

**Narration:**
Both proposed enhancements are well-defined and composable with the existing
framework. The sequencing node is the lower-risk addition — it is essentially
a TBB `sequencer_node` wrapper with Phlex's message types and a flush-aware
buffer. The sliding-window fold builds on it and addresses the broader class of
stencil computations that are common in signal processing. Neither requires
changes to the data-layer hierarchy model, the product storage system, or the
graph assembly machinery.

---

## Slide L2.1 — Limitation 2: Hierarchy-Algorithm Collusion (Stated Concern)

### The concern

When an algorithm uses `unfold` to create child data cells in a new layer
(e.g., `"fragment"`), every other part of the system that defines or
validates the hierarchy must also know about `"fragment"`. If true, this
would require tight *collusion* between:

- The **driver plugin**, which supplies the `fixed_hierarchy`.
- The **algorithm plugin** that unfolds into the new layer.
- Any **configuration layer** that assembles the workflow at runtime.

### Motivating example

```
Driver declares fixed_hierarchy:
    fixed_hierarchy{{"run"}, {"run", "event"}}

Algorithm "splitter" unfolds "event" → "my-special-layer-of-parts"

Algorithm "process-part" queries:
    product_query{.creator = "splitter",
                  .layer   = "my-special-layer-of-parts"}
```

**Questions to resolve:**

1. Must `"my-special-layer-of-parts"` appear in the driver's `fixed_hierarchy`?
2. If not, what does the framework actually validate — and when?
3. What is the minimal coordination required between plugins?

**Narration:**
The concern is well-motivated: in a large experiment framework, the driver,
algorithm, and configuration might be written by different teams or loaded as
separate shared libraries at runtime. If every unfold child layer had to be
pre-declared in the driver's fixed_hierarchy, adding a new algorithm would
require coordinating a change to the driver — a significant coupling. The next
slide shows that this coupling is largely absent.

---

## Slide L2.2 — Limitation 2: Refutation — Unfold Bypasses `fixed_hierarchy`

### Key finding: this concern is largely a non-issue

An `unfold` creates child indices by calling `data_cell_index::make_child()`
**directly**, bypassing `data_cell_cursor::yield_child()` — the only path that
calls `fixed_hierarchy::validate()`.

From `declared_unfold.hpp:170`:
```cpp
auto new_id = unfolded_id->make_child(child_layer(), counter);
// ↑ direct call: no fixed_hierarchy::validate() invoked
```

Compare to the driver path (`fixed_hierarchy.cpp:68-75`):
```cpp
data_cell_cursor data_cell_cursor::yield_child(...) const
{
    auto child = index_->make_child(layer_name, number);
    hierarchy_.validate(child);   // ← driver path validates
    driver_.yield(child);
    return data_cell_cursor{child, hierarchy_, driver_};
}
```

### Two distinct hierarchy objects in `framework_graph`

```cpp
// framework_graph.hpp:157-158
fixed_hierarchy      fixed_hierarchy_;   // schema — validates driver yields ONLY
data_layer_hierarchy hierarchy_{};       // observer — counts ALL seen layers, no validation
```

The `hierarchy_node_` TBB node (framework_graph.cpp:41-46) receives indices from
**both** the driver source and unfold output port, and calls only
`hierarchy_.increment_count(index)` — a counting operation with no schema check:

```cpp
hierarchy_node_{graph_, tbb::flow::unlimited,
    [this](data_cell_index_ptr const& index) -> tbb::flow::continue_msg {
        hierarchy_.increment_count(index);   // data_layer_hierarchy — no validation
        return {};
    }}
```

The `index_router` has **no reference** to `fixed_hierarchy` at all. It routes
by `layer_hash()` to whatever provider ports have been registered for that hash.

### Conclusion

The driver's `fixed_hierarchy` needs to list **only the layers the driver
itself yields**. Unfold child layers do not need to appear there. The unfold
dynamically extends the live hierarchy at runtime, and Phlex accepts this
without complaint.

**Narration:**
This is a deliberate design choice: `fixed_hierarchy` is a schema for the *driver*,
not a global registry of all possible layers. Unfolds are the sanctioned mechanism
for generating layers that were not part of the original driver contract. The
`data_layer_hierarchy` observer records what actually appeared at runtime —
including unfold-generated layers — and this can be queried after execution via
`framework_graph::seen_cell_count()`. The two hierarchy objects serve completely
different purposes and it is important not to conflate them.

---

## Slide L2.3 — Limitation 2: What Collusion IS Real

Although `fixed_hierarchy` does not constrain unfold child layers, a different
form of collusion **does** exist and is unavoidable.

### The string-name contract

The unfold plugin registers its child layer name as a bare string at setup time:

```cpp
// Algorithm plugin "splitter"
g.unfold<Splitter>("splitter", pred, unf,
                   "my-special-layer-of-parts");   // ← string literal
```

Any downstream algorithm that consumes from that layer must use the **identical**
string in its `product_query`:

```cpp
// Algorithm plugin "process-part"
product_query{.creator = "splitter",
              .layer   = "my-special-layer-of-parts"}   // ← must match exactly
```

If the strings differ, `edge_maker` finds no producer for the query and reports
a configuration error at `finalize()` time — before the first data cell is emitted:

```
Configuration errors:
  - No producer found for query {creator="splitter", layer="my-special-layer-of-parts2"}
```

This is a **hard error at startup**, not a silent runtime failure.

### Flush-source collusion (automatic)

A fold consuming an unfold's child layer must receive flush messages from the
**unfold's own flusher**, not the graph-wide flusher. Phlex wires this
automatically at `finalize()` (framework_graph.cpp:150-172):

```cpp
// Automatic: framework matches unfold child layer to fold flush port
for (product_query const& pq : n->input()) {
    if (auto it = unfold_flushers.find(pq.layer); it != unfold_flushers.end()) {
        flushers.insert(it->second);    // ← unfold's flusher, not global
    } else {
        flushers.insert(&index_router_.flusher());
    }
}
```

The user does not wire this manually. The layer-name string is the key for the
lookup, so the same string-name contract covers it.

### Summary of what IS and IS NOT required

| Coordination needed | Required? | Who catches a violation |
|---|---|---|
| Child layer in driver's `fixed_hierarchy` | **No** | N/A — not enforced |
| Child layer string matches in unfold and consumer queries | **Yes** | `edge_maker` at `finalize()` — hard error |
| Child layer flush source wired manually | **No** | Automatic from string match |
| Child layer declared to `layer_generator` | **No** | `layer_generator` is for driver layers only |

**Narration:**
The real collusion is the shared string constant. In a well-structured codebase
this belongs in a single header that both the unfold plugin and the consumer plugin
include — something like `layer_names.hpp` with `constexpr char k_fragment[] = "fragment"`.
This is idiomatic C++ practice for shared constants and requires no framework support
beyond what already exists. The fact that `finalize()` catches mismatches as hard
errors before execution begins means failures are not silent or late.

---

## Slide L2.4 — Limitation 2: Framework Support Summary

### What Phlex enforces automatically

| Mechanism | Where | Triggered by |
|---|---|---|
| Driver layer validation | `data_cell_cursor::yield_child()` | Each driver `yield_child()` call |
| Unresolved consumer query → hard error | `edge_maker` at `finalize()` | Mismatched layer/creator/suffix string |
| Unfold flush-source wiring | `framework_graph::finalize()` | Layer-name match between unfold and fold |
| Runtime layer accounting | `data_layer_hierarchy::increment_count()` | Every index passing through `hierarchy_node_` |

### Plugin separation of concerns

Phlex enforces at the type level which registration methods each plugin
type can access:

```
PHLEX_REGISTER_PROVIDERS    → source_graph_proxy  → provide() only
PHLEX_REGISTER_ALGORITHMS   → module_graph_proxy  → fold / transform / unfold / observe / predicate
                                                     (provide() is NOT accessible)
```

This prevents a module plugin from accidentally acting as a data source, and
prevents a source plugin from registering processing algorithms.

### What the configuration layer must assure

The one thing Phlex does not enforce is the string constant shared between the
unfold plugin and its consumers. The recommended practice:

1. Define all layer name constants in a shared header (`layer_names.hpp`).
2. Use the same constant in the `unfold()` call and in all downstream
   `product_query` structs.
3. Treat a `finalize()` configuration error as a build-time problem — it
   should appear in integration tests before any experiment data is processed.

**Narration:**
Limitation 2 is substantially weaker than the stated concern suggests. The framework
does the heavy lifting — it catches unresolved queries as hard errors at startup,
it wires flush sources automatically, and it cleanly separates source plugins from
algorithm plugins. The remaining collusion (a shared string constant) is the
irreducible minimum necessary in any data-flow system where node outputs and
inputs must be matched by name. Phlex makes this failure mode visible and early.

---

## Slide L3.1 — Limitation 3: The Event Stream Pattern

### Setting

Multiple independent hardware streams each produce time-stamped *data units*.
Each unit spans a time interval $[t_\text{start}, t_\text{end})$. Between
units there are gaps of varying duration. There is no synchronisation between
streams other than a shared clock.

```
Stream A: |──A0──|   |──A1──|      |────A2────|  |─A3─|
Stream B:   |─B0─|  |──B1──|  |─B2─|            |──B3──|
Stream C: |───C0───|    |─C1─|    |───C2───|   |──C3──|
          ──────────────────────────────────────────────►  time
```

Interval durations, gap durations, and the number of units per stream are
all variable and statistically independent across streams and samples.

### Three primary operations needed

**Operation 1 — Merge streams:** Combine N independently-ordered streams into
a single time-ordered sequence (by unit start time). Output is a flat sequence
of units from all streams, ordered chronologically.

**Operation 2 — Merge overlapping units:** When two units from any stream(s)
overlap in time, combine them into one longer unit. Output has no overlapping
intervals.

**Operation 3 — Fragment to fixed blocks:** Split each (possibly large) unit
into fixed-duration sub-units. Produces a *chunked stream with gaps* — the
Limitation 1 pattern. Gaps between original units propagate as gaps between
block sequences.

### Fundamental gap in Phlex's data model

Phlex encodes data-cell identity as a bare `size_t` number with no temporal
semantics. There is no timestamp field in `data_cell_index`, `product_store`,
or any message type. The `number_` field (data_cell_index.hpp:48) is purely a
structural position label.

All three operations require *comparison of data cells by a real-valued time
key*. This comparison must be implemented entirely in user algorithm code, with
no framework-level support for time ordering.

**Narration:**
The event stream pattern is ubiquitous in streaming detector readout systems where
hardware modules produce self-triggered data: each module fires independently when
its channel crosses a threshold, producing a time-stamped fragment of unknown
duration. The three operations described here are the standard preprocessing steps
needed to turn this raw stream into the physics-meaningful "events" that
experiment-level algorithms expect. Phlex's batch-per-cell model is a good fit
for the downstream physics, but strained for this upstream stream-processing stage.

---

## Slide L3.2 — Limitation 3: Phlex Assessment per Operation

### Operation 1: Merge N streams into one time-ordered sequence

**Phlex mechanism available:** A `fold` partitioned at the job (or run) level
can accumulate all stream data cells and sort them on flush.

```cpp
g.fold("merge_streams", "job",
    [](MergeState& s, auto const& store) {
        auto interval = store.get_handle<TimeInterval>(q);
        s.units.push_back({*interval, store});   // accumulate
    },
    []{ return MergeState{}; },
    "merged_sequence");
// On flush: sort s.units by t_start, emit ordered sequence
```

**Limitations:**
- All stream units from all streams must fit in RAM simultaneously — a fold
  accumulates before emitting.
- Output is one product at the job level, not a streaming sequence. Downstream
  algorithms cannot start until all input is consumed.
- No incremental output; no backpressure mechanism.

### Operation 2: Merge overlapping units

Overlap detection requires comparing time intervals between pairs of data cells.
No Phlex primitive compares two cells by a user-defined key. Must be implemented
inside the same fold accumulator as Operation 1:

```cpp
// After sorting in the fold's flush:
std::vector<MergedUnit> merge_overlaps(std::vector<Unit> sorted_units)
{
    // standard interval-merge algorithm
}
```

**Limitations:** Same as Operation 1 — all data in RAM, batch output only.

### Operation 3: Fragment to fixed blocks

**Best fit in current Phlex.** An `unfold` on each merged unit creates
fixed-size block children:

```cpp
g.unfold<BlockSplitter>("fragment", pred_has_more_blocks, emit_next_block,
                        "fragment");
// unfold iterates: while pred(obj, state) → emit one block child cell
```

The `BlockSplitter` constructor receives the merged unit's `TimeInterval` and
waveform data via handles. The unfold iterates until all fixed-size blocks are
emitted. This naturally produces a chunked stream with gaps — Limitation 1.

**Limitation:** the input unit must fit in RAM to be an unfold input product.
If individual stream units are too large, even the unfold's input is problematic.

### Summary table

| Operation | Phlex mechanism | Viable? | Key limitation |
|---|---|---|---|
| Merge N streams (offline) | `fold` + sort in flush | With constraints | All data in RAM; batch output |
| Merge N streams (online/streaming) | None | **No** | No incremental fold output |
| Overlap detection | Algorithm in fold | With constraints | All data in RAM |
| Fragment to fixed blocks | `unfold` | **Yes** | Input unit must fit in RAM |
| Ordered delivery of blocks | None native | **No** | Limitation 1 ordering problem |

**Narration:**
Operations 1 and 2 are expressible in Phlex today but only for bounded datasets
where all stream data fits in memory. Operation 3 maps naturally to `unfold` and
is the strongest point of fit. The combination of all three — merge, overlap-merge,
fragment — works for offline processing of moderate-sized datasets but is not viable
for online streaming or for datasets where individual stream units already exceed
available RAM.

---

## Slide L3.3 — Limitation 3: Working Approaches Within Current Phlex

### Approach A: Timestamp-in-product + fold (offline, bounded data)

1. Driver yields one data cell per stream unit, with the stream identifier
   encoded in the layer name and the unit sequence number as the cell number.
2. Provider reads each unit, stores a `TimeInterval{t_start, t_end}` product
   and the raw waveform in the stream data cell.
3. A fold at the job level accumulates all stream cells. On flush it:
   - Sorts by `t_start`.
   - Merges overlapping intervals.
   - Emits merged "event" child cells (via the fold output, or via a
     subsequent unfold on the merged result).
4. A second unfold on each merged event creates fixed-size fragment cells
   → Limitation 1 territory.

```
Driver:  streamA:0, streamA:1, streamB:0, streamB:1, ...
             ↓ provider populates TimeInterval + Waveform products
fold("merge", "job"):
    flush → sort, merge overlaps → emit event:0, event:1, ...
             ↓ unfold("fragment", "event")
    fragment:0, fragment:1, ... per event
```

**Viable when:** all stream units from all streams fit in job-level RAM.
Suitable for offline reprocessing of a bounded recorded dataset.

### Approach B: Pre-sorted driver (two-pass architecture)

1. Pass 1 (metadata): Driver reads only timestamps from all streams.
   Performs the merge and overlap-detection externally (before Phlex execution).
   Produces a pre-computed event list: `[(t_start, t_end, source_units), ...]`.
2. Pass 2 (data): Driver yields pre-assigned event indices in time order.
   Providers receive event indices and serve the relevant waveform segments.

```
Pass 1 (external):  read all timestamps → compute merged event list
Pass 2 (Phlex):     driver yields event:0, event:1, ...
                    provider("event") → serves pre-computed waveform slice
                    unfold → fragment cells
```

**Advantage:** all ordering is guaranteed by the driver; Phlex algorithms stay
simple and stateless. The ordering problem from Limitation 1 is avoided because
the driver controls the fragment sequence explicitly.

**Limitation:** requires two-pass access to the data; couples the driver plugin
to all stream sources; not applicable to live/online processing.

**Narration:**
Approach B is the pragmatic choice for offline data processing in HEP, where
data is already stored and can be read twice. The pre-sorting step can be
implemented as a separate lightweight tool that produces an index file, and the
Phlex driver simply reads that index file. This pattern trades the elegance of
a single-pass pipeline for the reliability of having ordering guaranteed before
the graph executes. The Phlex graph then runs with maximum parallelism because
no algorithm has temporal dependencies.

---

## Slide L3.4 — Limitation 3: Proposed Framework Enhancements

Two framework enhancements would bring the event stream pattern into Phlex's
native capability.

### Enhancement 1: Temporal key on data cells

Add an optional `time_interval` metadata field to `data_cell_index` or
define a framework-recognized product type that carries time information.
Phlex primitives could then exploit this key for ordering and overlap detection.

```cpp
// Proposed: driver yields cells with time metadata
auto unit = job.yield_child("stream_unit", {.number=42, .t_start=1.23, .t_end=1.57});
```

This would enable a `temporal_fold` variant:

```cpp
// Proposed: fold that triggers on time overlap, not just layer flush
g.temporal_fold("merge", "job",
    [](MergeState& s, auto const& store) { ... },
    [](TimeInterval const& a, TimeInterval const& b) { return a.overlaps(b); },
    "merged_event");
```

The fold emits an output each time the leading edge of the time window advances
beyond the end of the oldest buffered unit — an incremental rather than
all-at-once output.

### Enhancement 2: Streaming fold / generator

The fundamental limitation of the current fold is that it emits only on a global
flush. A *streaming fold* would emit incrementally as the "causal horizon"
advances: once all units with `t_start < T` have arrived, the fold can safely
emit any merged event that ends before `T`, without waiting for later units.

This requires:
- A weaker flush model: "emit when leading-edge advances" rather than "emit when
  all children are done."
- An ordered-delivery guarantee (from Limitation 1 Enhancement 1) upstream of
  the fold.
- A watermark concept: a signal from the driver that no unit with
  `t_start < T` will arrive in the future.

### Relationship between the three limitations

```
Enhancement needed:
  Limitation 1 → sequencing node (ordered delivery by index number)
  Limitation 3 → temporal key + streaming fold (ordered delivery by time)

  These are the same root problem at different levels of abstraction:
  both require an ordering guarantee that TBB's flow graph does not provide.
```

A general solution — an **ordered-delivery node** parameterized by a
user-supplied comparison key — would address both limitations.

**Narration:**
The temporal key enhancement is the more ambitious of the two, as it touches the
core data model. But the design is well-precedented: Apache Flink's event-time
watermark model and Google Dataflow's windowing API address exactly this problem
for general streaming computations. Phlex could adopt a similar model scaled to
HEP use cases: the watermark is the beam trigger time (or a rolling time window),
and the streaming fold emits reconstructed events as the trigger advances. The
key insight from those systems is that incremental emission requires the framework
to track what is "safe to emit" based on upstream progress — which is precisely
what the Limitation 1 sequencing node provides at the fragment level.

---

## Slide L4 — Overall Limitation Summary

### The three limitations in context

```
Chunked stream (L1)     Event stream (L3)
       │                       │
       │ ordering problem       │ time-ordering + streaming problem
       │                       │
       └─────────┬─────────────┘
                 │
         SHARED ROOT CAUSE:
         Phlex data-layer model assigns
         cells a bare size_t number with
         no ordering semantics and no
         time semantics.  TBB flow::graph
         makes no delivery-order guarantee.
                 │
        ┌────────┴────────┐
        │                 │
   Algorithm-level    Framework-level
   workaround          enhancement
   (sort buffer)    (sequencing node /
                     temporal fold)

Hierarchy collusion (L2)
  └── Largely a non-issue: unfold bypasses fixed_hierarchy;
      only real requirement is a shared string constant
      caught at finalize() time.
```

### Summary table

| Limitation | Severity | Best approach today | Proposed enhancement |
|---|---|---|---|
| **L1: Chunked stream** | Moderate — algorithm-level solution exists but requires boilerplate | Stateful object + in-algorithm sort buffer; `concurrency::serial` | Sequencing node; sliding-window fold |
| **L2: Hierarchy collusion** | Low — largely a non-issue | Shared layer-name constant in a header; `finalize()` catches mismatches | None needed; current design is adequate |
| **L3: Event stream** | High for online streaming; moderate for offline bounded data | Pre-sorted driver (offline) or fold+sort (bounded in-memory) | Temporal key on data cells; streaming fold with watermark |

### What the limitations share

All three limitations involve *ordering* or *comparison* of data cells by a
key that is not the structural `(layer, number)` pair:

- **L1** needs ordering by `number` within a layer (currently unguaranteed).
- **L3** needs ordering by a real-valued timestamp (currently absent from the model).
- **L2** is the exception: it does not require ordering, and is well-handled by the
  existing framework.

A general mitigation strategy: add an **optional sort key** to `data_cell_index`
(an integer sequence number or a floating-point timestamp), and add a
**sequencing node** primitive that delivers messages in ascending key order to the
algorithm body. This single addition would resolve both L1 and L3 at a modest
cost in framework complexity, without changing the product storage model, the
graph assembly machinery, or the driver contract.

**Narration:**
The two genuine limitations (L1 and L3) have the same architectural root: Phlex
was designed for cell-independent, order-insensitive algorithms, and the TBB
flow graph underlying it makes no ordering guarantees. This is the right default
for the majority of HEP reconstruction algorithms, which are embarrassingly
parallel across events. The limitations arise specifically in the signal-processing
preprocessing layer where temporal ordering is physically meaningful. A targeted
addition — a sequencing node and an optional time-interval field — would extend
Phlex's reach into this domain without compromising the clean data-layer hierarchy
model that makes the rest of the framework work so well.
