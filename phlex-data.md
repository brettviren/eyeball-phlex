# Phlex Data Management and DFP Connectivity

## 1. Hierarchy of Families

### Data Layers

Phlex defines a user-configurable **data-layer hierarchy** — an ordered set of named aggregation levels, e.g.:

```
Job → Run → Spill → APA
```

Each level is a **data layer**, and a particular instance at that level is a **data cell** (e.g., "APA number 3 in spill 7 of run 2"). The identity of a cell is captured by `data_cell_index` (phlex/model/data_cell_index.hpp), which encodes the full path from root to cell:

```cpp
class data_cell_index {
  data_cell_index_ptr make_child(std::string layer_name, std::size_t number) const;
  data_cell_index_ptr parent(identifier const& layer_name) const;
  std::string layer_path() const;   // e.g. "job/run/spill/apa"
  std::size_t depth() const;
  identifier const& layer_name() const;
};
```

### Product Stores and Handles

Every data cell has a **product store** (phlex/model/product_store.hpp) that holds all data products created for that cell:

```cpp
class product_store {
  data_cell_index_ptr id_;     // which cell owns these products
  products products_{};        // typed collection
  algorithm_name source_;      // which algorithm created them

  template <typename T>
  handle<T> get_handle(product_specification const&) const;

  template <typename T>
  void add_product(product_specification const&, T&&);
};
```

Downstream algorithms access products through **handles** (phlex/model/handle.hpp), which carry both the data pointer and provenance metadata:

```cpp
template <typename T>
class handle {
  const_pointer product_;
  data_cell_index const* id_;
  experimental::identifier creator_plugin_;
  experimental::identifier creator_algorithm_;
  experimental::identifier suffix_;

  algorithm_name_view creator() const;
  std::string_view suffix() const;
  std::string_view layer() const;         // which data layer
  auto const& data_cell_index() const;
};
```

### Product Specification

A product is identified by a triple (phlex/model/product_specification.hpp):

| Field | Meaning |
|-------|---------|
| `qualifier` | `{plugin, algorithm}` — creator algorithm name |
| `suffix` | user-supplied label (e.g., `"GoodHits"`) |
| `type_id` | C++ type |

### Family Concepts

A **data-product family** is the set of same-type products that exist across all cells of a given layer. For example, the family of `Waveforms` products is one member per APA cell.

At registration time, an algorithm declares its families explicitly:

```cpp
// Single-layer family: one Waveforms per APA cell
m.transform("hit_finder", find_hits, concurrency::unlimited)
  .input_family(
    product_query{.creator = "calibrate_wires", .suffix = "Waveforms", .layer = "APA"}
  )
  .output_product_suffixes("GoodHits");

// Cross-layer: per-APA tracks + single Job-level geometry
m.transform("vertex_maker", make_vertices, concurrency::unlimited)
  .input_family(
    product_query{.suffix = "GoodTracks", .layer = "APA"},
    product_query{.suffix = "Geometry",   .layer = "Job"}
  )
  .output_product_suffixes("Vertices");
```

In the second example the framework automatically repeats the `Job`-level `Geometry` object for every APA cell — the algorithm never sees this asymmetry.

The `data_layer_hierarchy` class (phlex/model/data_layer_hierarchy.hpp) tracks the runtime hierarchy: layer names, parent hashes, and cell counts via TBB concurrent data structures.

---

## 2. DFP Node/Edge Connectivity

### Graph Infrastructure

Phlex implements the DFP graph on top of **TBB Flow Graph** (Intel oneAPI). The top-level container is `framework_graph` (phlex/core/framework_graph.hpp):

```cpp
class framework_graph {
  tbb::flow::graph graph_{};
  node_catalog nodes_{};
  std::map<std::string, filter> filters_{};
  data_layer_hierarchy hierarchy_{};
  tbb::flow::input_node<data_cell_index_ptr> src_;
  index_router index_router_;
};
```

Node types include: source, provider, transform, fold, unfold, observe, and output nodes.

### Messages — What Flows on Edges

Every edge carries `message` objects (phlex/core/message.hpp):

```cpp
struct message {
  product_store_const_ptr store;  // products for one data cell
  std::size_t id;                 // used for join matching
};
```

For nodes with multiple inputs, messages arrive as tuples:

```cpp
template <std::size_t N>
using message_tuple = sized_tuple<message, N>;
```

The `message_matcher` extracts `id` so TBB can group messages that belong to the same logical data unit before firing an algorithm.

### Edge Creation

`edge_maker` (phlex/core/edge_maker.hpp) wires the graph at startup:

1. Each node declares what products it **requires** (input queries) and what it **creates** (output suffixes).
2. For every input query, the edge maker finds the producer node that creates the matching product.
3. `tbb::flow::make_edge(*producer->output_port, *receiver_port)` is called to connect them.
4. Filter nodes (for predicates) are inserted on edges where needed.
5. **Repeater nodes** are inserted when producer and consumer live at different data layers.

### Cross-Layer Join: `multilayer_join_node`

When an algorithm consumes inputs from *different* layers (e.g., APA-level tracks + Job-level geometry), Phlex inserts a `multilayer_join_node` (phlex/core/multilayer_join_node.hpp):

```cpp
template <std::size_t NInputs>
class multilayer_join_node {
  std::vector<std::unique_ptr<detail::repeater_node>> repeaters_;
  tbb::flow::join_node<args_t, tbb::flow::tag_matching> join_;
  std::vector<identifier> const layers_;
};
```

- Same-layer inputs: connected directly to the inner `join_node` (tag-matched by message ID).
- Cross-layer inputs: a `repeater_node` is inserted on that edge.

### Repeater Node

`repeater_node` (phlex/core/detail/repeater_node.hpp) bridges the impedance mismatch between a coarse-grained layer (e.g., `Job`) and a fine-grained one (e.g., `APA`):

```cpp
class repeater_node {
  struct cached_product {
    std::shared_ptr<message> data_msg;
    tbb::concurrent_queue<std::size_t> msg_ids;  // child cell IDs to replay for
    std::atomic<int> counter;
    std::atomic_flag flush_received;
  };
  tbb::concurrent_hash_map<std::size_t, cached_product> cached_products_;
};
```

Operation:
1. A parent-layer message (e.g., `Geometry` at `Job` scope) arrives and is cached.
2. For each child-layer message ID that arrives (one per APA cell), the repeater emits a copy of the cached parent message stamped with that child's `id`.
3. The inner `join_node` can now pair parent and child messages by matching `id`.
4. When all children are processed, the cache entry is flushed.

### Index Router

An `index_router` sits at the front of the graph and routes raw `data_cell_index_ptr` tokens to the appropriate provider/repeater nodes, coordinating which child cells need to replay which parent data and signalling `indexed_end_token` flush events when cells are complete.

---

## Data-Flow Execution Summary

```
Driver
  └─► index_router ──► provider nodes (fetch data from files)
                            │
                            ▼ message{store, id}
                       [edges / filter nodes]
                            │
                    ┌───────┴───────────┐
             same-layer             cross-layer
             join_node           repeater_node
                    └───────┬───────────┘
                            ▼ message_tuple<N>
                    computational node
                    (algorithm runs here)
                            │
                            ▼ message with new products
                       output / preserve nodes
```

Key points:
- All inter-node communication is via `message` (a product store + an integer ID).
- TBB tag-matching synchronises multi-input nodes within a layer.
- `repeater_node` handles the one-to-many relationship between coarse and fine data layers.
- The graph is built once at startup by `edge_maker`; thereafter TBB drives execution.

---

## Key Source Files

| Purpose | File |
|---------|------|
| Cell identity / hierarchy path | `phlex/model/data_cell_index.hpp` |
| Per-cell product container | `phlex/model/product_store.hpp` |
| Safe product access + provenance | `phlex/model/handle.hpp` |
| Runtime hierarchy tracking | `phlex/model/data_layer_hierarchy.hpp` |
| Product identity triple | `phlex/model/product_specification.hpp` |
| Top-level TBB graph | `phlex/core/framework_graph.hpp` |
| Edge message type | `phlex/core/message.hpp` |
| Graph wiring at startup | `phlex/core/edge_maker.hpp` |
| Cross-layer joining | `phlex/core/multilayer_join_node.hpp` |
| Parent-layer data repetition | `phlex/core/detail/repeater_node.hpp` |

## Key Design Doc Files (phlex-design/)

| Topic | File |
|-------|------|
| Data hierarchy concepts | `doc/ch_conceptual_design/data_organization.rst` |
| DFP fundamentals | `doc/ch_preliminaries/data_flow.rst` |
| Algorithm family registration | `doc/ch_conceptual_design/registration.rst` |
| Graph construction | `doc/ch_subsystem_design/task_management.rst` |
