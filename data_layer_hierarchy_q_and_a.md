# Phlex Data-Layer Hierarchy — Q&A Slides

Each slide answers one or more questions from the review of the original deck.
Corrections to original slides are called out explicitly.

---

## Slide Q1a — Correction to Slide 1: Is "job" a Special Layer?

**Question:** Is it true that "job" is special and not subject to user choice?
And is it true that there is no data cell or index for the "job" layer?

### The "job" root is hardcoded by the framework

**Correction to Slide 1:** The original slide states "The hierarchy is not fixed by
the framework — users define the layers and their nesting for each workflow."
This is partially inaccurate.

The root layer named **"job"** is hardcoded by the framework and is **not** subject
to user choice. Users define all layers *below* job, but the root is always "job".

Evidence in `phlex/model/data_cell_index.cpp:39`:
```cpp
// Default constructor — only ever called by data_cell_index::job()
data_cell_index::data_cell_index()
    : layer_name_{"job"}, layer_hash_{layer_name_.hash()} {}
```

The static factory returns a **singleton**:
```cpp
data_cell_index_ptr data_cell_index::job()
{
    static data_cell_index_ptr job_index{new data_cell_index};
    return job_index;                 // same pointer every call
}
```

The `fixed_hierarchy` constructor always seeds its hash set with the job hash,
regardless of what paths the user supplies (`fixed_hierarchy.cpp:47`):
```cpp
identifier const job{"job"};
std::set<std::size_t> hashes{job.hash()};  // job is always present
```

And `fixed_hierarchy::validate()` only checks whether the layer-path hash is in the
set; "job" always passes because its hash is always in the set.

### There IS a data_cell_index for job

**Correction to Slide 1:** The original deck (and a possible prior understanding)
suggested there is no index for the job layer. This is **incorrect**.

`data_cell_index::job()` returns a real `data_cell_index` (wrapped in a
`shared_ptr`). The framework calls `fixed_hierarchy::yield_job()` to emit this
index to the async driver at the start of execution:

```cpp
// fixed_hierarchy.cpp:101-107
data_cell_cursor fixed_hierarchy::yield_job(async_driver<data_cell_index_ptr>& d) const
{
    auto job = data_cell_index::job();
    d.yield(job);                          // job index IS emitted
    return data_cell_cursor{job, *this, d};
}
```

The job index travels through the `index_router` like any other index. If a provider
declares "job" as its layer, it receives this index and can produce job-level products.

### Summary of corrections

| Claim in Slide 1 | Verdict | Correction |
|---|---|---|
| "Users define the layers and their nesting" | Partially false | Users define layers *below* job; "job" root is always supplied by the framework |
| "There is no data cell or index for job" | False | `data_cell_index::job()` returns a real, singleton index; it is yielded and routed |

**Narration:**
The "job" layer is the one special node the framework always provides. Users cannot
rename it, skip it, or create a workflow without it. It serves as the single root
of every hierarchy tree. An important consequence is that there is always exactly
one job data cell per framework execution, and algorithms can produce job-level
products just as they produce event- or run-level products.

---

## Slide Q1b — Correction to Slide 1: Clarifying "Route Data"

**Question:** Slide 1 says output belongs to "exactly one node" but also that the
framework "routes data between layers." These seem contradictory. What does "route"
mean here?

### Two distinct routing concepts

The word "route" in Slide 1 conflates two separate mechanisms that operate on
different objects:

#### 1. Index routing — what the `index_router` actually does

```
Driver yields data_cell_index_ptr
           │
           ▼
      index_router
      (dispatches by layer_hash)
       /        \
      ▼          ▼
 provider    provider
 (layer A)  (layer B)
```

The `index_router` routes **indices** (`data_cell_index_ptr`), not products.
It inspects the `layer_hash()` of each yielded index and forwards it to provider
input ports that are registered for that layer. Products do not exist yet at this
point.

#### 2. Message routing — statically wired TBB graph edges

Once a provider creates a `product_store` and wraps it in a `message`, that message
travels along **pre-wired, static TBB flow-graph edges**. There is no dynamic routing
of messages. The edges are established at startup by `edge_maker` (based on
`product_query` matching) and do not change during execution.

```
provider("input", "event")
        │  message{store, id}
        ▼
  [static TBB edge]
        │
        ▼
 transform("double_it")
        │  message{new store, id}
        ▼
  [static TBB edge]
        │
        ▼
 fold("fold_add") ← flush_message when partition complete
```

### Correction

**Slide 1** should read:

> "The framework routes **indices** between layers: the `index_router` dispatches
> each emitted `data_cell_index` to provider nodes that are registered for that
> layer. Products, once created, travel as messages along statically wired graph
> edges established at startup. A product belongs to exactly one data cell and
> does not move — it lives in the `product_store` for that cell."

**Narration:**
The original word "route data" is misleading because data (products) never move —
they are immutably placed in a `product_store` and accessed via handles. What the
framework routes are *indices*: the lightweight identity tokens that tell providers
"a new data cell of your layer exists — produce its products now." Keeping these
two concepts separate — index routing (dynamic) vs. message flow (static) — is
key to understanding the framework's execution model.

---

## Slide Q2 — Slide 2: Building `fixed_hierarchy` from a Function or Configuration

**Question:** A presentation showed a hierarchy produced by a function given user
configuration. Is this feature present in the source?

### YES — the `layer_generator` plugin provides this

The `plugins/layer_generator.hpp` class builds both a `fixed_hierarchy` and a
compatible driver from a programmatic specification, avoiding the need to write the
literal initializer list by hand.

```cpp
// plugins/layer_generator.hpp:46-75
layer_generator gen;
gen.add_layer("spill", {"job",   16});      // 16 spill cells per job
gen.add_layer("CRU",   {"spill", 256});     // 256 CRU cells per spill
gen.add_layer("run",   {"job",   16});      // 16 run cells per job
gen.add_layer("APA",   {"run",   150, 1});  // 150 APA cells per run, starting at 1
```

`add_layer(name, layer_spec)` records a `layer_spec`:

```cpp
struct layer_spec {
    std::string parent_layer_name;
    std::size_t total_per_parent_data_cell;
    std::size_t starting_value = 0;  // first index number emitted
};
```

After all layers are added, two things can be derived:

```cpp
fixed_hierarchy h = gen.hierarchy();        // schema for validation
driver_bundle   b = driver_for_test(gen);   // driver that yields all cells
```

The `hierarchy()` method builds the `fixed_hierarchy` from the recorded layer paths.
The `driver_for_test()` helper (layer_generator.hpp:78-83) wraps both:

```cpp
inline driver_bundle driver_for_test(layer_generator& generator)
{
    driver_proxy const proxy{};
    return proxy.driver(
        generator.hierarchy(),                            // schema
        [&generator](data_cell_cursor const& job) {      // driver callable
            generator(job);                              // emits all cells
        });
}
```

### Relationship to the two-constructor `fixed_hierarchy`

`fixed_hierarchy` already accepts either an `initializer_list` or a
`vector<vector<string>>` of layer paths (fixed_hierarchy.hpp:45-46), so any code
that builds a `vector<vector<string>>` from configuration (YAML, JSON, command-line,
etc.) can construct a `fixed_hierarchy` from it. The `layer_generator` is the
provided implementation of this pattern in the `plugins/` directory.

**Narration:**
The `layer_generator` is the configuration-driven hierarchy factory. In a real
experiment, a driver plugin would typically read from a data source (a file, a
network stream) to determine how many runs and events are available, build a
`layer_generator` or equivalent, and use it to emit exactly the indices that
correspond to available data. The `layer_spec::starting_value` field supports
non-zero-based numbering, which is common when detector identifiers (APAs, CRUs)
have hardware-assigned numbers.

---

## Slide Q3 — Slide 6: How `PHLEX_REGISTER_ALGORITHMS` Relates to `declared_*` and `products_consumer`

**Question:** Developer examples show algorithms as bare functions passed to a CPP
macro. How do these macros relate to `declared_observer()` and `products_consumer`
inheritance?

### The macro creates a plugin entry-point function

`PHLEX_REGISTER_ALGORITHMS` (`phlex/module.hpp:39-41`) expands to:

```cpp
// What PHLEX_REGISTER_ALGORITHMS(my_module, config) expands to:
static void create(module_graph_proxy<void_tag>& my_module, configuration const& config);
BOOST_DLL_ALIAS(create, create_module)   // Boost.DLL dynamic-loading hook
void create(module_graph_proxy<void_tag>& my_module, configuration const& config)
{
    // ← user's code body goes here
}
```

The macro does **not** wrap any user function in a class. It creates a free function
whose body is the user's code. `BOOST_DLL_ALIAS` makes this function loadable as a
shared library plugin.

### The proxy chain: macro → graph_proxy → glue → declared_*

The `module_graph_proxy<void_tag>` passed into the user's function exposes
registration methods (`fold`, `observe`, `predicate`, `transform`, `unfold`).
These delegate through several layers:

```
User code: my_module.observe("print", my_func)
                │
                ▼
  module_graph_proxy (phlex/module.hpp:17-32)
  inherits graph_proxy<void_tag>
                │
                ▼
  graph_proxy<T>::observe() (phlex/core/graph_proxy.hpp:75-77)
  creates glue<T> and calls glue.observe()
                │
                ▼
  glue<T>::observe() (phlex/core/glue.hpp)
  constructs observer_node<AlgorithmBits>
                │
                ▼
  observer_node<AlgorithmBits> (phlex/core/declared_observer.hpp:49+)
  inherits declared_observer
  inherits products_consumer
```

### User-facing API vs internal classes

| User sees | Internal class created | Inherits |
|---|---|---|
| `module.observe(name, f)` | `observer_node<Bits>` | `declared_observer` → `products_consumer` |
| `module.transform(name, f)` | `transform_node<Bits>` | `declared_transform` → `products_consumer` |
| `module.fold(name, f)` | `fold_node<Bits, Init>` | `declared_fold` → `products_consumer` |
| `module.unfold<S>(name, p, f, layer)` | `unfold_node<S, P, F>` | `declared_unfold` → `products_consumer` |
| `module.predicate(name, f)` | `predicate_node<Bits>` | `declared_predicate` → `products_consumer` |

The `products_consumer` base class stores the `product_queries` and provides the
`port()` method that `edge_maker` uses to connect upstream outputs to this node's
TBB input port. The user never touches `products_consumer` directly.

### Object-bound algorithms with `make<T>`

For stateful algorithms — where the function is a member of a class — the user
first calls `module.make<MyAlgo>(ctor_args)` which constructs an instance and
returns a `graph_proxy<MyAlgo>`. Member functions are then registered on that proxy:

```cpp
// phlex/core/graph_proxy.hpp:52-57
template <typename U, typename... Args>
graph_proxy<U> make(Args&&... args)
{
    return graph_proxy<U>{config_, graph_, nodes_,
                          std::make_shared<U>(std::forward<Args>(args)...), errors_};
}
```

**Narration:**
The macro is purely a Boost.DLL plugin-registration mechanism. It does not touch
algorithm logic at all — it just creates the C-linkage entry point that the
framework's dynamic loader calls when it loads the shared library. Once the entry
point is called, the user registers algorithms by calling methods on the provided
proxy object, and those method calls create the `declared_*` node objects that
inherit from `products_consumer`. The inheritance is hidden completely from the
user.

---

## Slide Q4 — Slide 7: How Unfold Indices Lead to Provider Population

**Question:** After an unfold emits `data_cell_index_ptr` values, how do those
lead to product population in the child data cells? And when and why is an unfold
invoked — it has no visible `product_queries` in the example?

### Unfold DOES have input product queries

The `declared_unfold` constructor takes `product_queries input_products`
(`declared_unfold.hpp:62`), and `unfold_node` stores them in the inherited
`products_consumer` base class. The user-facing `graph_proxy::unfold<Splitter>()`
call derives the input queries from the **constructor parameter types of the
`Splitter` class**:

```cpp
// Constructor parameter types of the Splitter class become the product queries.
// If Splitter(handle<int> const& h) then the unfold needs an int product as input.
using input_args = constructor_parameter_types<Splitter>;
```

The Splitter object is constructed fresh for each parent data cell, receiving its
inputs as handle arguments extracted from the product store.

### The unfold execution loop

The unfold node is triggered when it receives a `message` from its upstream
(wired by `edge_maker` based on the Splitter's constructor types). Its body
(`declared_unfold.hpp:107-186`) runs a predicate/unfold loop:

```cpp
std::size_t counter = 0;
auto running_value = obj.initial_value();
while (std::invoke(predicate, obj, running_value)) {
    // create a child data_cell_index
    auto new_id = unfolded_id->make_child(child_layer(), counter);

    // call the unfold function → returns (next_value, products)
    auto [next_value, prods] = std::invoke(unfold, obj, running_value, *new_id);

    // wrap products in a child product_store
    auto child = generator.make_child_for(counter++, std::move(prods));

    // emit the child product_store as a message (port 0)
    tbb::flow::output_port<0>(unfold_).try_put({.store = child, .id = ...});

    // emit the child data_cell_index (port 1)
    tbb::flow::output_port<1>(unfold_).try_put(child->index());

    running_value = next_value;
}
// emit a flush_message after all children are generated
flusher_.try_put({.index = store->index(), .counts = g.flush_result(), ...});
```

### How the child index reaches providers

```
unfold node
  ├── port 0: message{child_store} ──► downstream transform/observer/fold nodes
  └── port 1: data_cell_index_ptr ──► hierarchy_node_ ──► index_router ──► providers
```

In `framework_graph.cpp:178-180`:
```cpp
make_edge(src_, hierarchy_node_);          // driver source → hierarchy node
for (auto& [_, node] : nodes_.unfolds) {
    make_edge(node->output_index_port(), hierarchy_node_);  // unfold → hierarchy node
}
```

Both the driver source AND unfold output feed into the same `hierarchy_node_`.
The `hierarchy_node_` feeds the `index_router_`. The router dispatches child
indices to any provider registered for the child layer name.

### Flush signal

After emitting all child cells, the unfold emits a `flush_message` via its own
`flusher_` (not the graph-wide flusher). Fold nodes that consume the unfold's
child layer are wired to this per-unfold flusher, so they know when all children
of a given parent have been generated.

**Narration:**
An unfold is both a product producer AND an index emitter. Its first output port
behaves like a transform — it sends messages containing child product stores to
downstream algorithm nodes that need child-layer data. Its second output port
behaves like a driver extension — it feeds new indices into the hierarchy node
so providers can produce additional products for those child cells if needed.
The two ports work in concert: algorithms that read only from the unfold's output
stores use port 0; algorithms (including providers) that are wired via the index
router use port 1.

---

## Slide Q5 — Slide 8: Rules for Driver Index Sequences

**Question:** What rules, if any, apply to the sequence of indices yielded at any
layer? Can there be gaps? Can they be out of order? Can they repeat with a common
parent?

### What the framework validates

`data_cell_cursor::yield_child()` calls `fixed_hierarchy::validate()` on the new
index before yielding it. The validate function checks only one thing:

```cpp
// fixed_hierarchy.cpp:89-99
void fixed_hierarchy::validate(data_cell_index_ptr const& index) const
{
    if (layer_hashes_.empty()) { return; }
    if (std::ranges::binary_search(layer_hashes_, index->layer_hash())) {
        return;  // ← only checks layer membership
    }
    throw std::runtime_error(
        fmt::format("Layer {} is not part of the fixed hierarchy.", index->layer_path()));
}
```

The validation checks only the **layer name** (via layer hash). It does **not**
check:
- The numeric value of the cell number
- Whether numbers are contiguous
- Whether numbers are ascending
- Whether the same number has been yielded before

### Summary of driver index rules

| Property | Enforced? | Notes |
|---|---|---|
| Layer must be in `fixed_hierarchy` | **Yes** — hard error | Only rule enforced by the framework |
| Cell numbers must be contiguous | No | Gaps are allowed |
| Cell numbers must be in order | No | Out-of-order is allowed |
| Same `(parent, layer, number)` must not repeat | No | Not prevented by framework |

### Consequences of repetition

`data_cell_index` equality is based on the hash of
`(parent_hash, layer_hash, number)` (`data_cell_index.cpp:49`). If the driver
yields the same `(layer, number)` combination twice under the same parent, the two
resulting indices will be **equal** (same hash). This can cause undefined behavior
in the `index_router`'s internal routing structures and in `fold_node`'s
accumulation map (which is keyed by index hash). **Repetition is the driver
author's responsibility to avoid.**

### What `layer_generator` does

The test utility `layer_generator` always yields indices
`[starting_value, starting_value + total_per_parent_data_cell)` in ascending order,
in a nested loop over parents. This is a convention, not a framework requirement.

**Narration:**
The framework is deliberately permissive about index ordering and gaps. A driver
reading from a live detector might not know the total event count in advance, might
skip bad runs, or might yield events out of timestamp order depending on how data
arrives. All of these are valid as long as each yielded `(parent, layer, number)`
triple is unique within the execution. The absence of a uniqueness check in the
framework means the user bears responsibility for not repeating indices; repetition
is a latent bug, not an immediate error.

---

## Slide Q6 — Slide 8: How Does a Driver Know the Range of Available Indices?

**Question:** The driver example iterates a fixed range. Is it correct that a
provider populates a data cell using its index as a key? If so, how does the driver
know which indices the provider's data source contains?

### Yes — the provider uses the index as a data lookup key

A provider function receives a `data_cell_index const&` and uses its `.number()`
(and optionally `.parent()` indices) to look up data in an external source:

```cpp
// Provider reading from a notional file
declared_provider("input", "event",
    [&my_file](data_cell_index const& idx) {
        auto run_num   = idx.parent("run")->number();
        auto event_num = idx.number();
        return my_file.read_event(run_num, event_num);   // index is the key
    },
    /*suffix=*/ "waveform");
```

### The driver-provider coordination problem

The framework provides **no built-in mechanism** for the provider to communicate
available indices back to the driver. The driver must independently know the valid
range. There are two common patterns:

#### Pattern A: Driver interrogates the data source

```
Driver startup:
  open file / stream
  query: "how many runs? how many events per run?"
  yield exactly those indices
Provider:
  receives only valid indices (driver never asks for ones that don't exist)
```

This is the standard pattern. The driver opens the same (or a sibling) data source
at job start, determines the available range, and yields only indices that are valid.

#### Pattern B: `layer_generator` encapsulates both sides

```
layer_generator gen;
gen.add_layer("event", {"run", n_events_per_run});

driver_bundle b = driver_for_test(gen);   // driver yields 0..n_events_per_run-1
// Provider independently knows n_events_per_run from same config
```

`layer_generator` centralizes the count so driver and provider share the same
specification, avoiding mismatch.

### No pull-based coordination

The framework does not support a "pull" model where a provider requests its own
indices. Indices always flow from driver → index_router → provider, never from
provider → driver. In real experiment plugins the driver and provider are typically
authored together, sharing access to the same file-handle or metadata object so
the driver can emit exactly the indices for which data exists.

**Narration:**
This is a genuine design responsibility placed on plugin authors. The index number
is just a `size_t` — it has whatever meaning the author assigns. For a file with
sequential records it is a record number. For a detector with hardware-assigned
identifiers it is the hardware ID. The provider and driver must agree on this
convention. The framework enforces only that the layer name is valid; the semantic
meaning of the number is entirely up to the plugin.

---

## Slide Q7 — Fanin and Fanout Patterns: Cross-Layer and Same-Layer

**Question:** Fold is a fanin pattern and unfold is a fanout. Both operate between
parent and child layers. Are there fanin/fanout patterns that operate within the
same layer?

### Cross-layer patterns (the primary model)

| Pattern | Mechanism | Direction |
|---|---|---|
| Fanin (reduce) | `fold` with `partition` layer | Many child cells → one parent cell |
| Fanout (expand) | `unfold` | One parent cell → many child cells |

These are the fundamental Phlex multi-cell patterns. Both require a layer boundary.

### Same-layer "fanin": multiple inputs to one algorithm at the same layer

An algorithm (observer, transform, fold) can declare **multiple product queries
all pointing to the same layer**. The `multilayer_join_node` handles this:

```cpp
// From hierarchical_nodes.cpp:114-116
g.observe("print_result", print_result, concurrency::unlimited)
    .input_family(
        product_query{.creator = "scale",        .layer = "run"},
        product_query{.creator = "get_the_time", .layer = "run"}
    );
```

Both inputs are at the `"run"` layer. The join synchronizes them by **message ID**
(i.e., both products must come from the **same run data cell**). This is
**fanin-from-same-layer** but it is not reducing N cells to one — it is combining
N *products* from the *same* cell.

True same-layer reduction (accumulating across N *different* cells of the same
layer into one output cell) requires a `fold` with the parent as the partition,
which by definition crosses a layer boundary.

### Same-layer "fanout": one input, multiple outputs at same layer

A `transform` produces exactly one new `product_store` per invocation — that store
belongs to the same data cell as its input. A single transform can add multiple
products to that store (via multiple suffixes), but they all belong to the same
data cell. This is **same-cell multiple-output**, not same-layer fanout across cells.

True same-layer fanout (one cell producing N sibling cells at the same layer) is
**not directly supported**. An `unfold` always creates children at a new, deeper
layer, not siblings at the same layer.

### Pattern summary

```
Cross-layer fanin:   N child cells ──fold──► 1 parent cell
Cross-layer fanout:  1 parent cell ──unfold──► N child cells

Same-layer join:     product A )
                     product B )──join──► same cell, downstream algorithm
                     (same cell, different algorithms)

Same-cell multi-out: 1 cell → transform → {suffix_A, suffix_B, ...} in same store

NOT supported natively:
  Same-layer fanin across cells: cell0, cell1, cell2 → algorithm → cell_x
  (workaround: fold to parent, but output lives at parent level)
  Same-layer fanout: cell_x → algorithm → cell0, cell1, cell2
  (unfold only produces a new child layer, not siblings)
```

**Narration:**
Phlex's data model makes same-layer accumulation (reducing sibling cells into one
sibling cell) awkward because the output of a fold always lives at the parent layer.
This is a deliberate simplification: it keeps the data ownership tree acyclic and
makes flush/completion semantics tractable. Workflows that need a same-layer result
typically promote the result up to the parent (where it logically belongs anyway)
rather than trying to put it at the same level as the inputs.

---

## Slide Q8 — Multi-Cell Consuming Algorithms and the Overlap-Add / Convolution Case

**Question:** How does Phlex support algorithms that must consume products from
multiple data cells and produce products across multiple data cells? Specifically,
an FFT-based convolution using overlap-add or overlap-save that needs access to
more than one "fragment" cell at a time and must save partial results across
invocations.

### The core constraint

The Phlex data model enforces a strict rule: **each algorithm invocation receives
the product stores of exactly the data cells it was wired to receive in a single
message or join-message.** A transform or observer sees one cell at a time (plus any
joined cells from other layers declared in its input queries). A fold accumulates
across cells but only emits at partition boundaries.

There is **no native sliding-window primitive** — no way to ask the framework "give
me cells N, N+1, and N+2 together in one invocation."

### Available mechanisms and their limitations

#### 1. Stateful algorithm object (mutable state)

The `make<T>()` API binds an algorithm object to a proxy. Member functions can
accumulate state across calls:

```cpp
// module_graph_proxy<void_tag>
auto obj = my_module.make<OvlapAddFilter>(kernel);
obj.transform("overlap_add_step", &OvlapAddFilter::process_fragment);
```

`OvlapAddFilter::process_fragment` is called once per fragment cell. The object can
hold a tail buffer that it prepends to each fragment's data, compute the FFT
convolution, save the new tail, and emit the main body. **Limitation:** TBB may
invoke this on any thread, but because the object is shared across calls the user
must handle concurrency. Setting `concurrency::serial` forces sequential execution
and makes this safe.

```
Fragment 0 → process_fragment → output_0 + tail_0 (saved in object)
Fragment 1 → process_fragment → output_1 + tail_1 (uses tail_0, saves tail_1)
Fragment 2 → process_fragment → output_2 + tail_2 (uses tail_1, saves tail_2)
```

**Ordering issue:** The framework does not guarantee that fragments arrive in index
order. The algorithm object must buffer or sort if order matters.

#### 2. Fold + stateful accumulation

A `fold` partitioned at the "event" level accumulates all fragments, then emits a
result when flushed:

```cpp
g.fold("conv_fold", "event",
    [](OvlapState& state, fragment_message const& frag) {
        state.accumulate(frag);   // store fragment data
    },
    []{ return OvlapState{}; },   // init per event
    "convolved_event");
```

The fold emits once per event after all fragments are processed. **Limitation:**
all fragments must fit in memory simultaneously, which the question explicitly
rules out.

#### 3. Sub-fragment unfold + stateful transform (overlap-add in layers)

A more Phlex-idiomatic approach uses the hierarchy to encode the algorithm's
internal stages:

```
event
  └── fragment (child layer)
         └── fft_block (grandchild layer, from unfold)
```

1. An unfold at the fragment layer creates `fft_block` children that are the
   overlap-add sub-blocks.
2. A transform at the fft_block layer does the FFT, stores the block result.
3. A fold at the fragment layer combines fft_block results.
4. The stateful overlap (tail) is stored in the algorithm object across fragment
   invocations.

**This still requires the tail buffer to be passed between sequential fragment
invocations** — see mechanism 1 for the ordering caveat.

### Honest assessment of limitations

| Need | Phlex support | Notes |
|---|---|---|
| One algorithm sees multiple sibling cells | Not native | Requires stateful object + serial concurrency |
| Guaranteed in-order delivery | Not native | Index router does not sequence; user must sort |
| Partial results saved between invocations | Via mutable algorithm object (`make<T>`) | Works; requires serial concurrency |
| Output spanning multiple cells at same layer | Not supported | Use child layer + fold to parent |
| Streaming window (N cells buffered at once) | Not native | Must implement in algorithm object |

**Narration:**
The data-layer model is designed for embarrassingly parallel, cell-independent
algorithms. Algorithms that have temporal dependencies between cells — like
overlap-add convolution — must implement their own buffering inside a stateful
algorithm object and explicitly constrain concurrency to serial. The framework
provides the infrastructure (cell identity, product storage, flush signals) but
does not assist with sequencing or windowing. For the specific convolution case,
the most Phlex-compatible design keeps the long-memory state inside the algorithm
object and uses the hierarchy only to demarcate the output granularity — the
fragment cell that produced the output, not the internal processing blocks.

---

## Slide Q9 — Big Picture: All Phlex Types in Text

This slide shows the complete type map — what each key type contains, points to,
and is used by.

### Identity and naming types

```
identifier
  stores   : std::string (shared), std::uint64_t hash
  used by  : data_cell_index (layer_name_), algorithm_name (plugin_, algorithm_),
             product_specification (suffix_), product_query (creator, layer, suffix)
  note     : all name-like things are identifiers; "layer_name", "suffix",
             "plugin", "alg" are roles, not distinct types

algorithm_name
  stores   : identifier plugin_, identifier algorithm_
  used by  : product_specification (qualifier_), product_store (source_),
             declared_* nodes (name_)
```

### Hierarchy and index types

```
fixed_hierarchy
  stores   : std::vector<std::size_t> layer_hashes_  (sorted, binary-searchable)
  used by  : data_cell_cursor (hierarchy_), driver_bundle, framework_graph
  creates  : data_cell_cursor via yield_job()

data_cell_index                             (always held via shared_ptr)
  stores   : data_cell_index_ptr parent_, identifier layer_name_, size_t number_
             size_t layer_hash_, size_t hash_, size_t depth_
  factory  : data_cell_index::job() → singleton root
             parent.make_child(name, number) → new child
  used by  : product_store (id_), message (via product_store), handle (id_)
             data_cell_cursor (index_), index_router (routing key)

data_cell_cursor
  stores   : data_cell_index_ptr, fixed_hierarchy const& (borrowed),
             async_driver<data_cell_index_ptr>& (borrowed)
  creates  : child data_cell_cursor via yield_child()
  used by  : driver callable (received as argument)
  note     : cursor is ephemeral; it is a driver-time wrapper only
```

### Product storage types

```
product_base                                (abstract, heap-allocated)
  interface: address() → void const*,  type_info() → type_info const&

product<T>  inherits product_base
  stores   : T obj  (the actual typed value)
  owned by : products map (via unique_ptr<product_base>)

product_specification
  stores   : algorithm_name qualifier_, identifier suffix_, type_id type_
  role     : key in the products map within product_store

product_store                               (always held via shared_ptr)
  stores   : products (unordered_map<product_specification, unique_ptr<product_base>>)
             data_cell_index_ptr id_,  algorithm_name source_
  owned by : message (product_store_const_ptr store)
  used by  : handle<T> (borrows pointer to product and index)
```

### Query and access types

```
product_query
  stores   : identifier creator, layer, suffix; type_id type; optional stage
  used by  : products_consumer (input_products_), declared_*::constructor
             edge_maker (to find matching output ports at graph-build time)
  method   : match(product_specification) → bool

handle<T>
  stores   : T const* product_, data_cell_index const* id_
             identifier creator_plugin_, creator_algorithm_, suffix_
  created  : product_store::get_handle<T>(product_query)
  used by  : algorithm bodies (via operator*(), operator->(), suffix(), layer(), index())
  note     : handle is a read-only view; it borrows from the store's lifetime
```

### Message types (TBB flow-graph currency)

```
index_message
  stores   : data_cell_index_ptr index, size_t msg_id, bool cache
  flows    : driver → index_router → provider input ports

message
  stores   : product_store_const_ptr store, size_t id
  flows    : provider → transform/fold/observer/unfold nodes (static TBB edges)

flush_message
  stores   : data_cell_index_ptr index, flush_counts_ptr counts, size_t original_id
  flows    : flusher_t → fold flush_port (triggers fold emission)
```

### Graph and execution types

```
node_catalog
  owns     : maps of declared_provider_ptr, declared_transform_ptr,
             declared_fold_ptr, declared_unfold_ptr, declared_observer_ptr,
             declared_predicate_ptr, declared_output_ptr

declared_provider   (does NOT inherit products_consumer)
  TBB ports: receiver<index_message> input,  sender<message> output
  invoked  : once per index_message from index_router

declared_transform / declared_observer / declared_predicate  (inherit products_consumer)
  TBB ports: receiver<message> input (via join),  sender<message> output (transform only)

declared_fold  (inherits products_consumer)
  TBB ports: receiver<message> input, receiver<flush_message> flush_port
             sender<message> output
  state    : per-partition accumulator map, keyed by parent index hash

declared_unfold  (inherits products_consumer)
  TBB ports: receiver<message> input,
             sender<message> output (port 0 — child product stores),
             sender<data_cell_index_ptr> output_index_port (port 1 — child indices)

index_router
  receives : data_cell_index_ptr (from driver src_ and unfold output_index_port)
  dispatches: by layer_hash → provider input ports and multilayer join slots

framework_graph
  owns     : node_catalog, index_router, fixed_hierarchy,
             tbb::flow::graph, input_node<data_cell_index_ptr> src_
  wires    : edge_maker connects all declared nodes at finalize() time
```

**Narration:**
The type map shows three orthogonal concerns that Phlex keeps cleanly separated:
*naming* (identifiers and specifications), *identity* (indices and cursors), and
*storage* (stores, products, handles). Messages glue these together at runtime:
an `index_message` carries only identity; a `message` carries a store (identity +
storage); a `flush_message` carries identity plus a completion signal. The graph
types operate entirely on messages; the algorithm bodies operate on handles; the
driver operates on cursors. A user can understand any one of these layers without
understanding the others.

---

## Slide Q10 — Big Picture: Type Relationship Diagram

```
╔════════════════════════════════════════════════════════════════════════════════╗
║  PHLEX TYPE RELATIONSHIPS                                                      ║
╚════════════════════════════════════════════════════════════════════════════════╝

 NAMING LAYER
 ┌─────────────┐    used as    ┌──────────────────────────────────────┐
 │  identifier │ ──────────►  │  layer_name  suffix  plugin  alg     │
 │  (string +  │               │  (all identifier, different roles)   │
 │   hash)     │               └──────────────────────────────────────┘
 └──────┬──────┘
        │ composes
        ▼
 ┌──────────────────┐    ┌───────────────────────────────────┐
 │  algorithm_name  │    │  product_specification            │
 │  plugin + alg    │◄───│  algorithm_name  suffix  type_id  │
 └──────────────────┘    └─────────────────┬─────────────────┘
                                           │ key in
                                           ▼
 HIERARCHY LAYER                   ┌──────────────────────────────┐
 ┌─────────────────┐               │  product_store               │
 │ fixed_hierarchy │               │  products: spec → product<T> │
 │ vector<hashes>  │               │  id: data_cell_index_ptr     │
 └────────┬────────┘               │  source: algorithm_name      │
          │validates                └──────────┬──────────────────┘
          │                                    │ owned by
          ▼                                    ▼
 ┌───────────────────────────────┐   ┌──────────────────────────┐
 │  data_cell_index   (shared)   │   │  product<T>              │
 │  layer_name: identifier       │   │  (inherits product_base) │
 │  number: size_t               │   │  obj: T                  │
 │  parent: data_cell_index_ptr  │   └──────────────────────────┘
 │  hash: size_t                 │
 └──────┬───────────────┬────────┘
        │                │
        │ wraps           │ ref in
        ▼                 ▼
 ┌─────────────────┐   ┌──────────────────────────────────────┐
 │ data_cell_cursor│   │  handle<T>                           │
 │ index           │   │  T const*  product_                  │
 │ fixed_hierarchy │   │  data_cell_index const*  id_         │
 │ async_driver    │   │  identifier suffix_, layer_          │
 └────────┬────────┘   └──────────────────────────────────────┘
          │                         ▲
          │ yield_child()            │ get_handle<T>()
          ▼                         │
 ┌─────────────────┐   ┌────────────┴────────────────────────┐
 │  async_driver   │   │  product_query                      │
 │  yields indices │   │  creator  layer  suffix  type_id    │
 └────────┬────────┘   └──────────┬──────────────────────────┘
          │                        │ matched by edge_maker at startup
          ▼                        ▼
 EXECUTION LAYER

 driver_bundle ──── calls ──► fixed_hierarchy::yield_job()
      │                              │ emits job index
      │                              ▼
      │                       data_cell_index  (job root)
      │                              │
      │                    ┌─────────┴──────────────────┐
      │                    │       index_router          │
      │                    │  map: layer_hash → ports    │◄── unfold output_index_port
      │                    └─────────┬──────────────────-┘
      │                              │ dispatches by layer
      │                     ┌────────┴────────┐
      │                     ▼                  ▼
      │            ┌─────────────────┐  ┌─────────────────┐
      │            │ declared_       │  │  declared_       │
      │            │ provider A      │  │  provider B      │
      │            │ (layer "event") │  │  (layer "run")   │
      │            └────────┬────────┘  └────────┬─────────┘
      │                     │ message             │ message
      │               ┌─────┴──────┐        ┌────┴──────┐
      │               │ transform  │        │   fold    │◄── flush_message
      │               └─────┬──────┘        └────┬──────┘
      │                     │ message             │ message
      │               ┌─────▼──────┐        ┌────▼──────┐
      │               │  observer  │        │  observer │
      │               └────────────┘        └───────────┘
      │
      │                              OR
      │
      └─► unfold ──────────────────────────────────────────┐
           │ port 0: message{child_store}                   │
           │     └──► downstream consumers of child layer   │
           │ port 1: data_cell_index_ptr (child)            │
           └──────────────────────────────────────► index_router (feeds providers)

 node_catalog owns:  providers, transforms, folds, unfolds, observers, predicates
 framework_graph owns: node_catalog, index_router, fixed_hierarchy, tbb::flow::graph

────────────────────────────────────────────────────────────────────────────────
 MESSAGE TYPE SUMMARY

  index_message  ──►  provider input_port
                      (data_cell_index_ptr + msg_id)

  message        ──►  transform/fold/observer/unfold input
                      (product_store_const_ptr + id)

  flush_message  ──►  fold flush_port
                      (data_cell_index_ptr + counts + original_id)
────────────────────────────────────────────────────────────────────────────────
```

**Narration:**
Reading the diagram from top to bottom traces the flow of control and data through
a Phlex job. The naming layer (identifiers, algorithm_names, product_specifications)
is orthogonal infrastructure that labels everything else. The hierarchy layer
(fixed_hierarchy, data_cell_index, data_cell_cursor) defines structure and validates
it at emission time. The execution layer (index_router, declared nodes, messages)
is the TBB-backed runtime. The three layers interact at well-defined points:
`yield_child` bridges naming and hierarchy; `index_router` bridges hierarchy and
execution; `handle<T>` bridges storage and algorithm bodies. Understanding where
each boundary lies is the key to diagnosing configuration errors (naming layer),
hierarchy mismatches (hierarchy layer), and runtime data-flow problems (execution
layer).
