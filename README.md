# Hexveil: Icosahedral Gnomonic Aperture 4 Hexagons

Hexveil is a high-performance Erlang implementation of a hierarchical discrete global
grid system (DGGS). It uses an **Aperture 4** hierarchy mapped onto the 20 faces of
an **icosahedron** using a **gnomonic projection**.

## What is Hexveil?

Hexveil divides the Earth's surface into a hierarchy of hexagonal cells. Unlike
traditional Lat/Lon coordinates, which vary in physical distance depending on latitude,
Hexveil provides a mathematically stable way to index and search spatial data.

### Key Characteristics:
*   **Aperture 4:** Each parent cell is divided into 4 smaller child cells in the next
    resolution. This provides a smooth, consistent scaling factor of 2.0x in edge length
    per level.
*   **Icosahedral Projection:** By using 20 triangular faces to represent the sphere,
    Hexveil minimizes the "map distortion" found in equirectangular projections (like
    standard Web Mercator).
*   **Gnomonic Mapping:** Central projection from the Earth's center to the face planes
    ensures that great circles are represented as straight lines, making navigation and
    neighbor-finding computationally efficient.
*   **Base-4 Encoding:** Cell IDs are represented as `Face-Digits` (e.g., `0-213123...`),
    where the face is base-20 (0-9, a-j) and the digits represent the hierarchical path.

---

## Visualizing the Grid

Hexveil provides a visualization tool (`hexveil_viz.escript`) that generates an interactive
Leaflet map to inspect the grid.

### 1. The Global Structure (Faces)
The Earth is first divided into 20 icosahedral faces. Each face acts as its own local
coordinate system, significantly reducing distortion at the poles.

![Icosahedral Face Mapping](docs/faces.svg)
*(Diagram showing the 20 icosahedral faces mapped to the globe)*

### 2. Hierarchical Scaling (Aperture 4)
As you increase the resolution, each hexagon precisely covers the center of its parent, with three other children surrounding it.

![Aperture 4 Hierarchy](docs/hierarchy.svg)
*(Diagram showing L17 cells nested within L16 and L15 parents)*

---

## Resolution Table

| Level | Approx. Diameter | Typical Use Case |
| :--- | :--- | :--- |
| **24** | ~2.5 m | High-precision / Human-scale tracking |
| **18** | ~160 m | Privacy-preserving proximity (Level 1) |
| **17** | ~320 m | Neighborhood-scale indexing |
| **9** | ~80 km | Regional / Meteorological data |
| **1** | ~20,000 km | Global / Continental scale |

---

## Usage

### Encoding a Coordinate
```erlang
% Encode Amsterdam (Lat: 52.3676, Lon: 4.9041) at Level 17
Code = hexveil:encode({52.3676, 4.9041}, 17).
% Result: <<"0-21312323330031321">>
```

### Finding Neighbors
```erlang
% Get the 6 immediate neighbors of a cell
Neighbors = hexveil:neighbors(Code).
```

### Generating the Visualization
Run the provided escript to generate `hexveil_viz.html`:
```bash
./hexveil_viz.escript 52.3676 4.9041 15
```
This will create a map showing the target cell and its surrounding neighborhood across
three resolution levels.

---

## Spatial Queries with Prefix Matching

Because codes are hierarchical, **truncating a code to N digits gives its parent cell at
resolution N**. Two codes that share a prefix are guaranteed to be in the same coarser cell.
This lets you replace expensive distance calculations with simple string prefix operations,
which databases can execute with a standard **btree index** (`LIKE 'prefix%'`).

### Shared-Prefix = Spatial Proximity

Looking at the hierarchical examples from the code:

| Location        | L24 (2.5m)                    | L17 (320m)            | L9 (80km)     |
| :---            | :---                          | :---                  | :---          |
| Vondelpark Ent. | `0-213123233300313032331123` | `0-21312323330031321` | `0-213123322` |
| Leidseplein     | `0-213123233300130310001202` | `0-21312323330013031` | `0-213123322` |
| Dam Square      | `0-213123233300100131120221` | `0-21312323330010102` | `0-213123322` |
| Dom Utrecht     | `0-213123321210212311201233` | `0-21312332121021320` | `0-213123323` |

At L9 (~80 km), the three Amsterdam locations share `0-213123322` while Dom Utrecht
(~40 km away) is `0-213123323`. A prefix search on `0-213123322%` would include all
Amsterdam items and exclude Utrecht — with zero distance calculations.

### Simple Proximity Search

To find all items within ~1000 m of a viewer, truncate the viewer's code to a resolution
whose cell diameter covers 1000 m (L15 ≈ 1280 m), then do a prefix match:

```sql
-- $1 = viewer's code truncated to L15 (e.g. '0-213123233300313')
SELECT * FROM items
WHERE code LIKE $1 || '%';
```

This is a btree range scan — O(log n) to find the start, then a sequential read of
only the matching rows.

### Visibility-Radius Filtering (Dual-Disk Pattern)

The original question: user A wants to see 1000 m around their location, but user B
(800 m away) wants to be visible only within 500 m. How is B excluded without
calculating the distance to every user?

**At write time**, store each item with a `visibility_code` — the item's code truncated
to the resolution matching its visibility radius:

```erlang
%% User B at {Lat, Lon}, visible within 500 m → use L16 (~640 m)
Code = hexveil:encode({Lat, Lon}, 24),       %% full precision code
VisibilityCode = hexveil:parent(              %% truncate to L16
    hexveil:encode({Lat, Lon}, 16)),
%% Store both: code and visibility_code
```

```sql
-- items table
--   code            text   -- full-resolution code (L24)
--   visibility_code text   -- code truncated to visibility radius resolution
CREATE INDEX idx_items_code ON items (code);
```

**At query time**, the viewer uses two prefix checks:

```sql
-- $search_prefix = viewer's code truncated to search radius (L15 for ~1000 m)
-- $viewer_code   = viewer's full-resolution code (L24)

SELECT * FROM items
WHERE code LIKE $search_prefix || '%'              -- item is in viewer's search area
  AND $viewer_code LIKE visibility_code || '%';    -- viewer is inside item's visibility cell
```

**Why user B is excluded:** B's `visibility_code` is at L16 (~640 m). User A is 800 m
away, so A's full code does **not** share B's L16 prefix — the second `LIKE` check fails.
No per-row distance calculation needed.

### Using `disk/2` for Exact Results

When you need exact circular coverage (e.g. the item is near a cell boundary and a
single prefix would miss it), use `triveil:disk/2` which returns all cell codes within
a given diameter:

```erlang
%% Get all cells within 1000 m of a location
Codes = triveil:disk(Code, 1000).
```

Then store or query using array containment (with a **GIN index** for performance):

```sql
-- Exact disk-based query
-- $1 = triveil:disk(viewer_code, 1000)   (viewer's search area)
-- $2 = viewer_code                        (viewer's own code)

SELECT * FROM items
WHERE code = ANY($1)                    -- item is in viewer's disk
  AND $2 = ANY(visibility_codes);       -- viewer is in item's visibility disk
```

The prefix approach is faster (btree), while the disk approach is more precise (exact
circle). Choose based on whether approximate cell-boundary results are acceptable.

---

## Privacy Applications

Hexveil is designed with privacy in mind. Because it is hierarchical, you can easily
"coarsen" a user's location by simply stripping digits from the end of their Cell ID.

To prevent global tracking, we recommend **Salted HMAC Hashing**:
1. Take a user's Cell ID (e.g., `0-213123...`).
2. Add a secret server-side pepper and the User's ID.
3. Store the hash: `HMAC_SHA256(Secret, UserID + CellID)`.

This ensures that even if your database is compromised, the physical locations cannot
be recovered without the secret key.

---

## License
Apache 2.0
