# Phlex Data-Layer Hierarchy
### A 10-Slide Overview

---

## Slide 1: What Is the Data-Layer Hierarchy?

```
                    job
                   /   \
               run:0   run:1
               /   \      \
           ev:0  ev:1    ev:0
```

The data-layer hierarchy is Phlex's structured namespace for data produced during
a workflow execution. It is a **tree of scopes** — job, run, event, spill, APA, etc.
— where each node in the tree is a **data cell**: one concrete instance of a layer.

Every piece of data in a Phlex job lives at a specific node in this tree.
An algorithm that produces event-level data writes into the data cell for that
event; an algorithm that accumulates over a run writes into the run-level data cell.
The hierarchy is not fixed by the framework — users define the layers and their
nesting for each workflow.

**Key source files:**
- `phlex/model/data_cell_index.hpp` — identity of a data cell
- `phlex/model/fixed_hierarchy.hpp` — schema of allowed layer nesting
- `phlex/model/product_store.hpp` — per-data-cell product container

**Narration:**
The data-layer hierarchy is the backbone of all data management in Phlex. Think of
it as a filesystem path but for data scopes: `/job/run:0/event:5` names a specific
event. Every product — every piece of output from an algorithm — belongs to exactly
one node in this tree. The framework knows how to route data between layers because
the hierarchy defines the parent-child relationships between scopes.

---

## Slide 2: Defining the Hierarchy — `fixed_hierarchy`

```cpp
// Example: allowed nesting paths
fixed_hierarchy h{{
    {"run"},          // job → run is valid
    {"run", "event"}, // job → run → event is valid
}};
```

A `fixed_hierarchy` object specifies which layer-nesting paths are legal for a given
workflow. It is built from an initializer list of path vectors, each vector naming a
chain of layers from the job root downward.

### What it enforces
- A layer may only be yielded as a child of its declared parent.
- The hierarchy is validated at driver setup time, not at runtime.
- Multiple independent sub-trees are allowed (e.g., a run branch and a spill branch
  both hanging from the job root).

### `data_cell_cursor` — the driver's view of the hierarchy

```cpp
// data_cell_cursor wraps a data_cell_index and validates yields
cursor.yield_child("event", 5);  // returns child cursor for event #5
```

During execution the driver receives a `data_cell_cursor` for the job-level cell.
It calls `yield_child(layer_name, number)` to produce child cells. The cursor
validates that the requested layer is a legal child of the current one per the
`fixed_hierarchy`, then hands the new `data_cell_index` to the framework for routing.

**Narration:**
Before any data flows, the framework needs to know the shape of the hierarchy. The
`fixed_hierarchy` object is that schema. It prevents drivers from accidentally
emitting cells in illegal positions (e.g., an event that has no parent run). The
`data_cell_cursor` wraps this validation in a safe API: you cannot yield a child
unless the schema allows it.

---

## Slide 3: Data Cells — Identity and Storage

Every node in the hierarchy is a **data cell**. A data cell has two parts:

### 3a. Identity: `data_cell_index`

```
data_cell_index {
    parent ptr    → pointer to parent data_cell_index (null at job root)
    layer name    → identifier for the layer (e.g., "event")
    cell number   → integer label within the parent (e.g., 5)
    layer hash    → hash of the layer name alone
    full hash     → hash of the entire path (parent hash + layer + number)
    depth         → distance from job root
}
```

`data_cell_index` is **immutable and hashable**. Two indices with the same path
hash are equal. The factory methods are:

```cpp
auto job   = data_cell_index::job();
auto run0  = job.make_child("run", 0);
auto evt5  = run0.make_child("event", 5);
```

### 3b. Storage: `product_store`

```
product_store {
    algorithm_name  source        // which algorithm owns this store
    data_cell_index_ptr index     // which data cell
    products        store         // map<product_specification, unique_ptr<product_base>>
}
```

A `product_store` is the actual container of typed products for one data cell. It
maps `product_specification` keys to heap-allocated, type-erased `product_base`
objects. Algorithms read products through const handles; the framework manages
lifetime.

**Narration:**
Think of `data_cell_index` as an address and `product_store` as the mailbox at that
address. The address is immutable and cheap to copy (it's just a pointer chain with
a precomputed hash). The mailbox holds all the typed products that algorithms have
deposited for that data cell. Separating identity from storage lets the framework
route indices through the graph before any products exist, and only allocate storage
when an algorithm actually produces output.

---

## Slide 4: Identifiers and Suffixes

### The `identifier` type

```cpp
// Lightweight string with precomputed uint64_t hash
identifier layer_name = "event"_id;
identifier suffix     = "sum"_id;
```

`identifier` (`phlex/model/identifier.hpp`) is the universal name type in Phlex.
It wraps a shared string and a precomputed 64-bit hash, making comparisons O(1).
User-defined literals `"name"_id` and `"name"_idq` construct identifiers and query
variants respectively.

Identifiers are used for:
- **Layer names** — which level of the hierarchy a cell belongs to
- **Algorithm names** — who produced a product (stored as `algorithm_name{plugin, alg}`)
- **Suffixes** — which of an algorithm's multiple outputs is meant

### The `product_specification` — three-part key

```
product_specification {
    algorithm_name qualifier   // plugin name + algorithm name
    identifier     suffix      // disambiguates multiple outputs
    type_id        type        // C++ type of the product
}
```

A product stored in a `product_store` is uniquely keyed by this triple. The *layer*
is implicit: it comes from the `data_cell_index` held by the store.

### Why suffixes matter

An algorithm may produce multiple outputs of the same type. Suffixes let consumers
ask for the right one without ambiguity:

```
fold_add → suffix "sum"    (total across events)
fold_add → suffix "count"  (number of events)
```

A downstream algorithm queries with `.suffix = "sum"` and gets exactly that product.

**Narration:**
Identifiers are the naming glue of the entire system. Every layer, every algorithm,
and every output slot has an identifier. The suffix is the output-slot label: if an
algorithm emits two integers, they must have different suffixes so consumers can
distinguish them. Without suffixes, a consumer asking for "an int from fold_add"
would be ambiguous. The three-part `product_specification` makes every stored
product globally unique within its data cell.

---

## Slide 5: Product Queries — How Algorithms Declare What They Need

Before an algorithm can run, it must declare its inputs as **product queries**.

```cpp
// Declare a query: "I need the int produced by algorithm 'input'
//                  at the 'event' layer with suffix 'number'"
product_query q{
    .creator = "input",
    .layer   = "event",
    .suffix  = "number",
};
```

### `product_query` fields

| Field     | Type         | Meaning                                              |
|-----------|--------------|------------------------------------------------------|
| `creator` | identifier   | Name of the producing algorithm                      |
| `layer`   | identifier   | Layer at which the product lives                     |
| `suffix`  | identifier   | Output slot on the producer (optional)               |
| `stage`   | enum         | Pre/post processing stage filter (optional)          |

### Matching

`product_query::match(product_specification)` returns true when the specification
satisfies all non-empty fields of the query. The framework calls `match()` during
graph construction to wire producer output ports to consumer input ports.

### Handles — type-safe product access

```cpp
// Inside an algorithm body
auto h = store.get_handle<int>(query);  // returns handle<int const>
int val = *h;                           // dereference to get the value
identifier suf = h.suffix();            // introspect metadata
identifier lyr = h.layer();
data_cell_index const& idx = h.index();
```

`handle<T>` (`phlex/model/handle.hpp`) wraps a const reference to a product plus
its full metadata. Algorithms never receive raw pointers; they always receive handles.

**Narration:**
Product queries are the contract an algorithm presents to the framework: "before you
give me a data cell to process, make sure these products exist." The framework uses
these queries at graph-construction time to find the right producer nodes and draw
edges to this algorithm. At runtime, the algorithm uses `get_handle<T>` to retrieve
the actual value through a type-safe, metadata-rich wrapper. The handle carries the
full provenance — who made it, at which layer, with which suffix — so algorithms can
introspect their inputs if needed.

---

## Slide 6: Algorithms as Consumers — Getting Data

Algorithms that read data inherit from `products_consumer` and declare their queries
in the constructor. The framework then builds the graph edges automatically.

### Algorithm categories (consumer side)

| Type          | Description                                              |
|---------------|----------------------------------------------------------|
| **Observer**  | Reads products, produces nothing (side effects only)     |
| **Predicate** | Reads products, returns bool (used for filtering)        |
| **Transform** | Reads products from one cell, emits new products         |
| **Fold**      | Accumulates products across many cells → one output cell |

### Typical consumer body

```cpp
// Observer example
declared_observer(
    "my_observer",
    product_queries{
        product_query{.creator = "input", .layer = "event", .suffix = "number"},
    },
    [](auto const& store) {
        auto h = store.get_handle<int>(my_query);
        std::cout << "event value: " << *h << "\n";
    }
);
```

### Fold — consuming across layers

A fold reads products from child-layer cells and accumulates them into a
parent-layer cell:

```cpp
// Fold: for every run, sum all events' "number" products → "sum" at run level
declared_fold(
    "fold_add",
    /* partition layer */ "run",
    /* input query     */ product_query{.creator = "input", .layer = "event"},
    /* init            */ []{ return 0; },
    /* accumulate      */ [](int& acc, auto const& store) { acc += *store.get_handle<int>(q); },
    /* emit suffix     */ "sum"
);
```

The fold node receives a **flush message** when all children of a partition cell have
been processed; it then emits its accumulated result into the partition-level store.

**Narration:**
Getting data is always done through a query and a handle. The query is declared
statically so the framework can wire the graph before execution starts. At runtime,
`get_handle<T>` does a type-safe lookup in the product store. Folds are the most
powerful consumer pattern: they span layer boundaries, reading many child cells and
writing one aggregated result into the parent cell. The flush mechanism tells a fold
when all of its inputs have arrived.

---

## Slide 7: Algorithms as Producers — Putting Data

### Provider: the entry point

A **provider** is the only algorithm that creates products from raw data-cell indices
rather than from upstream products. It is the leaf at which external data enters the
hierarchy.

```cpp
declared_provider(
    "input",
    /* layer */ "event",
    /* function returning product */ [](data_cell_index const& idx) {
        return idx.number();   // produce an int equal to the cell number
    },
    /* suffix */ "number"
);
```

The provider receives `index_message` (a `data_cell_index_ptr` + message ID) from
the `index_router` and emits a `message` containing a new `product_store` with the
produced product already inserted.

### Transform: derive new products from existing ones

```cpp
declared_transform(
    "double_it",
    product_queries{product_query{.creator = "input", .suffix = "number"}},
    [](auto const& store) {
        auto h = store.get_handle<int>(q);
        return *h * 2;
    },
    /* suffix */ "doubled"
);
```

A transform reads from upstream stores and returns a new value. The framework wraps
that value in a new `product_store` that inherits the parent cell's index and chains
it to the input store.

### Unfold: split one cell into many

```cpp
declared_unfold(
    "splitter",
    "spill",                 // child layer to create
    [](data_cell_index const& parent) {
        return std::vector<unsigned>{0, 1, 2}; // cell numbers to emit
    }
);
```

An unfold emits new `data_cell_index_ptr` values back into the `index_router`,
effectively expanding the hierarchy downward at runtime.

**Narration:**
Putting data is the mirror of getting it. Providers inject external data at a chosen
layer; transforms derive new products from existing ones; unfolds split one cell into
many child cells, extending the hierarchy on the fly. All three patterns produce
typed values that the framework wraps in a `product_store` keyed by
`product_specification`. Every product is immutable once placed in a store — there
is no overwriting.

---

## Slide 8: The Driver — Feeding the Hierarchy

The **driver** is the top-level function responsible for emitting the sequence of
data cells that the workflow will process. It is user-supplied and decoupled from
algorithm logic.

### `driver_bundle`

```cpp
driver_bundle {
    fixed_hierarchy          hierarchy;  // legal layer schema
    detail::next_index_t     driver;     // callable that emits cells
}
```

### Building a driver with `driver_proxy`

```cpp
driver_proxy proxy{};
auto bundle = proxy.driver(
    fixed_hierarchy{{{"run"}, {"run", "event"}}},
    [](framework_driver& fw) {
        // fw.make_child returns a data_cell_cursor for the job root
        auto job = fw.make_child("job", 0);    // implicit job root
        for (unsigned r = 0; r < 3; ++r) {
            auto run = job.yield_child("run", r);
            for (unsigned e = 0; e < 10; ++e) {
                run.yield_child("event", e);  // emits event cell to framework
            }
        }
    }
);
```

### Execution sequence

1. The framework creates a TBB `input_node<data_cell_index_ptr>` seeded by the driver.
2. The driver's callable is invoked once; it yields indices via `data_cell_cursor`.
3. Each yielded index is pushed through the TBB flow graph as an `index_message`.
4. The `index_router` dispatches indices to matching provider input ports.
5. Providers consume indices and emit product-bearing messages downstream.
6. When all children of a partition cell have been processed, the `flusher_t` node
   broadcasts a `flush_message` to fold nodes.

### Concurrency

Algorithms declare a `concurrency` policy (`serial`, `unlimited`, or an explicit
count). The TBB node constructors receive this value directly, controlling how many
threads can execute the algorithm simultaneously.

**Narration:**
The driver is the clock of the whole system. It decides how many runs, events, and
other cells exist, and in what order they are emitted. Because it uses `yield_child`
through the validated `data_cell_cursor`, the hierarchy schema is enforced at
emission time. The driver itself runs in a single TBB `input_node`; parallelism
comes from downstream TBB nodes that can process different data cells concurrently.

---

## Slide 9: Assembling the Data Flow Graph

The **data flow graph (DFG)** is a directed acyclic graph (DAG) built at startup,
before any data cells are emitted. It connects algorithm nodes via typed message
channels.

### Node types and their TBB roles

| Node type           | TBB primitive                  | Input          | Output         |
|---------------------|-------------------------------|----------------|----------------|
| Driver input        | `input_node`                  | —              | `data_cell_index_ptr` |
| `index_router`      | `function_node`               | index msg      | routes to providers |
| Provider            | `function_node`               | `index_message`| `message`      |
| Transform/Observer  | `function_node`               | `message`      | `message` / — |
| Predicate           | `function_node`               | `message`      | bool filter    |
| Fold                | `multifunction_node`          | `message` + flush | `message`  |
| Unfold              | `multifunction_node`          | `message`      | `data_cell_index_ptr` |
| Join                | `join_node`                   | N messages     | tuple          |

### Edge creation — `edge_maker`

```
For each consumer algorithm C:
  For each product_query Q in C's declared inputs:
    Find all producer nodes whose output matches Q
    Call make_edge(producer.output_port, C.input_port)
```

The `edge_maker` (`phlex/core/edge_maker.hpp`) iterates declared algorithms, resolves
each `product_query` against the catalog of known outputs (matched by `qualifier`,
`suffix`, and layer), and calls TBB's `make_edge()`. If no match is found, the
framework reports a configuration error at startup — not at runtime.

### Multi-layer joins

When a fold or transform needs products from *different* layers simultaneously, a
`multilayer_join_node` collects one message per layer into a tuple before invoking
the algorithm. The `index_router` dispatches indices to per-layer repeater nodes
that feed the join's slots.

### Graph topology example

```
Driver ──► index_router ──► provider("input","event") ──► join
                │                                           │
                └──► provider("input","run")  ──────────► fold_add ──► observer
```

**Narration:**
Graph assembly is entirely static: by the time the first data cell is emitted,
every edge is already in place. The `edge_maker` walks the declared algorithm catalog
and resolves queries to outputs at startup, failing fast on mismatches. The resulting
TBB graph is a compile-time-known topology that TBB's scheduler can run with full
parallelism across independent branches. Joins and folds handle the multi-layer case
where data must be combined across hierarchy levels before processing.

---

## Slide 10: End-to-End Execution — Putting It All Together

### Startup sequence

```
1. User registers algorithms in node_catalog
      (providers, transforms, folds, observers, predicates, unfolds)

2. framework_graph constructor:
      a. Validates fixed_hierarchy
      b. Instantiates TBB nodes for each registered algorithm
      c. edge_maker wires product_query → output port connections
      d. Connects driver input_node → hierarchy_node → index_router

3. framework_graph::run():
      a. Driver callable executes; yields data_cell_index values
      b. Indices flow to index_router
      c. Providers create product_stores and emit messages
      d. Downstream nodes process messages concurrently (TBB)
      e. Flusher broadcasts flush_messages when partition cells complete
      f. Folds emit aggregated products on flush

4. framework_graph::finalize():
      a. Graph stops
      b. Statistics gathered from node_catalog
```

### Data lifecycle for one event

```
Driver yields event:5 (data_cell_index)
    │
    ▼
index_router matches "event" layer → routes to provider("input")
    │
    ▼
provider creates product_store{index=event:5, "number"→42}
emits message{store, msg_id}
    │
    ▼
transform("double_it") receives message
reads handle<int> "number"=42, produces "doubled"=84
emits new message{store chained to parent, "doubled"→84}
    │
    ▼
fold("fold_add") accumulates 84 into run:0 accumulator
    │  (repeated for all events in run:0)
    ▼
flush_message arrives → fold emits message{store{run:0, "sum"→total}}
    │
    ▼
observer reads handle<int> at run level, prints result
```

### Summary of key design choices

| Concern              | Mechanism                                              |
|----------------------|--------------------------------------------------------|
| Hierarchy schema     | `fixed_hierarchy` validated at setup                  |
| Data-cell identity   | `data_cell_index` — immutable, hashable pointer chain |
| Per-cell storage     | `product_store` — typed map keyed by `product_specification` |
| Product naming       | `identifier` (layer, suffix) + `algorithm_name`       |
| Consumer declaration | `product_query` matched at graph-build time           |
| Type-safe access     | `handle<T>` — const ref + full provenance metadata    |
| Driver interface     | `data_cell_cursor::yield_child` with schema validation|
| Execution engine     | TBB flow graph — fully static DAG, parallel by default|
| Cross-layer data     | `multilayer_join_node` + flush messages for folds     |

**Narration:**
The architecture is designed so that every configuration error — a misnamed query,
an illegal hierarchy path, a type mismatch — surfaces at startup rather than mid-run.
At runtime the TBB graph executes the fixed topology with maximum parallelism:
independent data cells are processed concurrently, and only fold nodes impose ordering
by waiting for flush signals. The result is a framework that scales from a single
event to billions while keeping algorithm code simple: an algorithm just declares what
it needs, and the framework delivers it.
